#!/usr/bin/env node
// Live graph of claude tmux sessions, served to a browser over SSE.
//
//   node web-server.js [port]        default 7878
//
// Nodes are LIVE tmux sessions only. An orch task whose session has exited
// leaves the graph — that is the point: the picture must shrink when work ends,
// so a queue entry alone never keeps a node alive.
//
// Binds 127.0.0.1 deliberately. The payload carries session titles and working
// directory paths (client names, ticket ids, repo layout); those should not be
// reachable from the LAN. Do not "helpfully" switch this to 0.0.0.0.
'use strict'

const http = require('http')
const fs = require('fs')
const path = require('path')
const { execFile } = require('child_process')

const PORT = Number(process.argv[2] || process.env.PORT || 7878)
const POLL_MS = Number(process.env.POLL_MS || 2000)
const DIR = __dirname
const PAGE = path.join(DIR, 'web', 'index.html')
const PICKER = path.join(DIR, 'picker.sh')
const QUEUE = path.join(process.env.HOME, '.claude', 'orch', 'queue')

const run = (cmd, args) =>
  new Promise((resolve) =>
    execFile(cmd, args, { timeout: 10000, maxBuffer: 4 << 20 }, (err, stdout) =>
      resolve(err && !stdout ? '' : String(stdout))
    )
  )

const ANSI = /\x1b\[[0-9;]*m/g

// picker.sh --list emits: rank \t session \t icon \t age \t paddedTitle \t path
// We depend on that layout, so parse tolerantly — a format change should degrade
// to state:"unknown", never throw and kill the poll loop.
// ---- last thing the user typed, read from the session transcript -------------
//
// A transcript is ~/.claude/projects/<slug>/<sessionId>.jsonl. Two record shapes
// count as typed, and scripts/last-prompt.py applies the same two:
//
//   * a prompt — promptSource "typed" | "queued" | "suggestion_accepted" | "sdk",
//     string content, not isSidechain (that marks a subagent turn). "sdk" is the
//     launch prompt of a headless session (orch ralph loops, cron jobs) and is the
//     only thing those are ever asked; "system" stays out, those are
//     <task-notification> blocks rather than anything a person wrote.
//   * a `!` shell command — promptSource null and the content wrapped in
//     <bash-input>. Reported with a leading "! ".
//   * a prompt with an attached image — content is a list holding an `image`
//     block. See fromBlocks below.
//
// The far more numerous tool-result entries are also type "user" and also carry
// list content, told apart by their `tool_result` block; system-reminders,
// slash-command expansions and task notifications are strings that fail every
// test. In a 17-session sample those were 1440 of 1633 user records, which is
// what this filter is really for.
//
// Transcripts reach tens of megabytes, so only the tail is read, and only when
// the file's mtime has moved. The path lookup is cached too — finding it means
// stat-ing one candidate per project directory.
const PROMPT_SRC = new Set(['typed', 'queued', 'suggestion_accepted', 'sdk'])
const BANG_OPEN = '<bash-input>'
const BANG_CLOSE = '</bash-input>'
// Escalating windows. 256KB covers a session you have typed in recently, but a
// long autonomous stretch buries the prompt under tool traffic — one measured at
// 286KB back, just past a fixed 256KB window, which is exactly the silent miss
// this avoids. The successful size is remembered per session so a busy transcript
// does not re-escalate from scratch on every poll. 4MB is the giving-up point.
const TAIL_STEPS = [256 * 1024, 1024 * 1024, 4 * 1024 * 1024]
// Long enough to hold a whole multi-line request (the ones with a bullet list and a
// pasted URL run several hundred chars); the panel scrolls rather than truncating.
const PROMPT_MAX = 1200
const promptCache = new Map() // sessionId -> {file, mtimeMs, text, win}

function findTranscript(sid) {
  const base = path.join(process.env.HOME || '', '.claude', 'projects')
  let dirs = []
  try { dirs = fs.readdirSync(base) } catch { return null }
  for (const d of dirs) {
    const p = path.join(base, d, `${sid}.jsonl`)
    try { if (fs.statSync(p).isFile()) return p } catch { /* next */ }
  }
  return null
}

// What the user typed in a list-content record, or '' if it wasn't them. Only an
// image attachment puts their own words in a list; a tool_result block means
// machinery, and a bare text list is a slash-command expansion or a system-
// reminder — so an image block is what makes the record a prompt. The text
// blocks already carry the [Image #N] placeholder inline, so joining them
// reproduces what the TUI showed. An image dropped with nothing typed leaves no
// text block at all.
function fromBlocks(content) {
  const kinds = new Set()
  const texts = []
  let images = 0
  for (const b of content) {
    if (!b || typeof b !== 'object') continue
    kinds.add(b.type)
    if (b.type === 'text') {
      if (typeof b.text === 'string' && b.text.trim()) texts.push(b.text.trim().replace(/\s+/g, ' '))
    } else if (b.type === 'image') images++
  }
  if (images === 0 || kinds.has('tool_result')) return ''
  if (texts.length) return texts.join(' ').slice(0, PROMPT_MAX)
  return images === 1 ? '[image]' : `[image x${images}]`
}

// True if this record post-dates the pane's own last turn. An unparsable stamp is
// never rejected — the cutoff filters a known second writer, it is not a validity
// check, so a bad timestamp should leave the old behaviour rather than blank the row.
// What the user picked in an AskUserQuestion box, or ''. The answer arrives as a
// tool_result so it looks like machinery, but it is the user speaking — and a
// session driven by question boxes has no typed prompt for as long as that lasts,
// which left the row advertising something hours stale. Each question's short
// header is prefixed so a bare list of labels does not float without its subject.
function fromAnswers(o) {
  const tur = o.toolUseResult
  if (!tur || typeof tur !== 'object') return ''
  const answers = tur.answers
  if (!answers || typeof answers !== 'object') return ''
  const headers = new Map()
  for (const q of Array.isArray(tur.questions) ? tur.questions : []) {
    if (q && q.question) headers.set(q.question, q.header || '')
  }
  const parts = []
  for (const [question, answer] of Object.entries(answers)) {
    const head = headers.get(question) || ''
    parts.push(String(head ? `${head}: ${answer}` : answer).replace(/\s+/g, ' '))
  }
  return parts.join(' · ').slice(0, PROMPT_MAX)
}

// A prompt typed while Claude was busy, or ''. It is never re-emitted as a `user`
// record — it exists only as this attachment plus a pair of queue-operation
// entries — so the other filters walk straight past a turn the user really typed.
// commandMode separates it from the harness queueing its own work: across 115 of
// these, all 107 "task-notification" were machine text and all 8 "prompt" human.
function fromQueued(o) {
  const a = o.attachment
  if (!a || a.type !== 'queued_command' || a.commandMode !== 'prompt') return ''
  if (typeof a.prompt !== 'string' || !a.prompt.trim()) return ''
  return a.prompt.trim().replace(/\s+/g, ' ').slice(0, PROMPT_MAX)
}

function tooNew(o, cutoff) {
  if (!cutoff || typeof o.timestamp !== 'string') return false
  const t = Date.parse(o.timestamp)
  return Number.isFinite(t) && t / 1000 > cutoff
}

function scanTail(file, size, bytes, cutoff = 0) {
  const start = Math.max(0, size - bytes)
  let buf
  try {
    const fd = fs.openSync(file, 'r')
    buf = Buffer.alloc(size - start)
    fs.readSync(fd, buf, 0, buf.length, start)
    fs.closeSync(fd)
  } catch { return null }

  const lines = buf.toString('utf8').split('\n')
  for (let i = lines.length - 1; i >= 0; i--) {
    const l = lines[i]
    // The first line of a tail is usually a partial record; it fails the '{' check
    // or the parse, which is the intent.
    if (!l || l[0] !== '{') continue
    let o
    try { o = JSON.parse(l) } catch { continue }
    if (o.type === 'attachment') {
      const queued = fromQueued(o)
      if (!queued || tooNew(o, cutoff)) continue
      return queued
    }
    if (o.type !== 'user' || o.isSidechain) continue
    const t = o.message && o.message.content
    let found = ''
    if (Array.isArray(t)) {
      // An image attachment lands here whatever the promptSource is — the older
      // records carry none at all. An AskUserQuestion answer is a tool_result, so
      // it has to be recognised before fromBlocks rejects the list as machinery.
      found = fromAnswers(o) || fromBlocks(t)
    } else if (typeof t !== 'string' || !t.trim()) {
      continue
    } else if (PROMPT_SRC.has(o.promptSource)) {
      found = t.trim().replace(/\s+/g, ' ').slice(0, PROMPT_MAX)
    } else {
      // A `!` command has no promptSource, so the wrapper is the only marker.
      // The tags hold just the command — its output is a separate record — so
      // stripping them leaves exactly what was typed.
      const s = t.trim()
      if (!s.startsWith(BANG_OPEN) || !s.endsWith(BANG_CLOSE)) continue
      const cmd = s.slice(BANG_OPEN.length, -BANG_CLOSE.length).trim()
      if (cmd) found = ('! ' + cmd.replace(/\s+/g, ' ')).slice(0, PROMPT_MAX)
    }
    if (!found) continue
    // Only a real candidate is worth parsing a date for; the tail is
    // overwhelmingly tool results, which never reach this line.
    if (tooNew(o, cutoff)) continue
    return found
  }
  return null
}

// Epoch second past which a prompt cannot belong to this pane, or 0 for no limit.
// A transcript belongs to the conversation, so `claude --resume` on it from a
// second window appends turns to the same file under the same sessionId and the
// row starts advertising a prompt this pane never saw. Only an idle pane can be
// judged this way — its own turn has ended — and only from the picker's age
// column, which is whole minutes since @claude_state_at; the extra minute covers
// that rounding plus the gap between the record clock and this one.
function promptCutoff(row) {
  if (row.state !== 'idle') return 0
  const m = /^(\d+)m$/.exec((row.age || '').trim())
  if (!m) return 0
  return Math.floor(Date.now() / 1000) - Number(m[1]) * 60 + 60
}

function lastPrompt(row) {
  const sid = row.sid
  if (!sid) return null
  let c = promptCache.get(sid)
  if (!c) {
    c = { file: findTranscript(sid), mtimeMs: 0, text: null, win: 0, key: null }
    promptCache.set(sid, c)
  }
  if (!c.file) return null
  let st
  try { st = fs.statSync(c.file) } catch { return c.text }
  // Keyed on state+age, not on the cutoff itself: the cutoff is derived from
  // Date.now() and so drifts every poll, which would miss the cache on every
  // pass. state+age only moves once a minute, and it is what actually changes
  // the answer — a row going idle changes it without touching the file's mtime.
  const key = row.state + '/' + row.age
  if (st.mtimeMs === c.mtimeMs && key === c.key) return c.text
  c.mtimeMs = st.mtimeMs
  c.key = key
  const cutoff = promptCutoff(row)

  for (const w of TAIL_STEPS) {
    if (w < c.win) continue // start where this session needed to look last time
    const text = scanTail(c.file, st.size, w, cutoff)
    if (text) { c.text = text; c.win = w; return text }
    if (w >= st.size) break // whole file already scanned; nothing to find
  }
  return c.text
}

// ---- fork lineage ------------------------------------------------------------
//
// `claude --fork-session` copies the parent's records into the child's transcript
// verbatim, uuids and all, and stamps the first copied record with
// `logicalParentUuid` pointing back into the parent. Two signals fall out of that,
// and which one is available depends on whether the parent had been compacted:
//
//   A. shared head uuids — a fork of an uncompacted parent starts with the same
//      records the parent starts with, so their heads share uuids. Two unrelated
//      sessions share none, so a single hit is enough.
//   B. logicalParentUuid — a fork of a compacted parent starts at the compact
//      boundary instead, so the heads no longer line up, but the boundary record
//      names the uuid it continues from.
//
// B also marks ordinary in-session compaction, so it only counts when the uuid
// turns up in a *different* transcript. Both facts are fixed when the fork is
// created and never change, so a resolved answer is cached for the process's life.
//
// Only same-directory transcripts are considered: a fork inherits its parent's
// working directory (fork-new.sh passes -c "$path"), so a cross-directory match
// would be a uuid collision, not lineage.
// Escalating head windows. A transcript does not open with conversation: it opens
// with metadata (custom-title, agent-name, mode, permission-mode) followed by a run
// of file-history-snapshot records that carry whole file contents. None of those
// have a uuid, and they are large — measured, one fork's first uuid-bearing record
// sat at 102,848 bytes while another's sat at 52,062. A fixed 64KB window resolved
// the second and silently missed the first, which is the failure this replaces.
// Stops at the first window that yields a uuid, so the common case still reads 64KB.
const HEAD_STEPS = [64 * 1024, 512 * 1024, 4 * 1024 * 1024]
const SCAN_CHUNK = 4 * 1024 * 1024 // deep-scan window; see fileHasUuid
const forkCache = new Map() // sid -> origin sid | null (null = checked, not a fork)
const headCache = new Map() // sid -> {uuids, logicalParent, file, dir, birth}

function readHead(file, bytes) {
  let buf, n
  try {
    const fd = fs.openSync(file, 'r')
    buf = Buffer.alloc(bytes)
    n = fs.readSync(fd, buf, 0, bytes, 0)
    fs.closeSync(fd)
  } catch {
    return null
  }
  const lines = buf.subarray(0, n).toString('utf8').split('\n')
  // A short file's last line is complete; a truncated read's is not.
  if (n === bytes) lines.pop()

  const uuids = new Set()
  let logicalParent = null
  let startedAt = 0
  for (const l of lines) {
    if (!l || l[0] !== '{') continue
    let o
    try { o = JSON.parse(l) } catch { continue }
    if (o.uuid) uuids.add(o.uuid)
    if (!logicalParent && o.parentUuid === null && typeof o.logicalParentUuid === 'string') {
      logicalParent = o.logicalParentUuid
    }
    // Earliest timestamp carried by the conversation itself — see headOf.
    if (!startedAt && o.timestamp) {
      const t = Date.parse(o.timestamp)
      if (t) startedAt = t
    }
  }
  return { uuids, logicalParent, startedAt }
}

function headOf(sid) {
  const hit = headCache.get(sid)
  if (hit) return hit
  const file = findTranscript(sid)
  if (!file) return null // transcript not written yet — retry on the next poll
  let size = 0
  try { size = fs.statSync(file).size } catch { /* treat as unknown */ }
  let parsed = null
  for (const w of HEAD_STEPS) {
    parsed = readHead(file, w)
    if (parsed && parsed.uuids.size) break
    if (size && w >= size) break // whole file already read; there is nothing more
  }
  if (!parsed || !parsed.uuids.size) return null // still being written; don't cache
  // Which of two sessions is the fork comes down to which STARTED later, so the
  // ordering signal must not move. The file's birthtimeMs does move: resuming a
  // session rewrites its transcript, and a resume reset one session's birthtime to
  // four hours AFTER the fork it was the origin of — inverting the arrow, so the
  // 17-day-old parent was drawn as a fork of its own child. The first timestamp
  // INSIDE the transcript is fixed when the conversation starts and survives
  // resume, copy and rsync. birthtimeMs stays only as a fallback for a head with
  // no timestamped record yet.
  let birth = parsed.startedAt
  if (!birth) { try { birth = fs.statSync(file).birthtimeMs } catch { birth = 0 } }
  const h = { ...parsed, file, dir: path.dirname(file), birth }
  headCache.set(sid, h)
  return h
}

// Substring search over a file of any size, in bounded memory.
//
// Replaces a readFileSync(...).includes() guarded by a 64MB cap. The cap was doing
// the opposite of protecting: a long-lived parent transcript measured 75MB, so the
// scan was skipped and the fork it was the origin of never got its edge — a silent
// miss, indistinguishable from "not a fork". Chunking means no cap is needed.
//
// Consecutive chunks overlap by uuid.length-1 so a uuid straddling a boundary is
// still found; without it the match would be split across two reads and lost.
function fileHasUuid(file, uuid) {
  const need = Buffer.from(uuid)
  const overlap = need.length - 1
  const buf = Buffer.alloc(SCAN_CHUNK)
  let fd
  try {
    fd = fs.openSync(file, 'r')
    let pos = 0
    for (;;) {
      const n = fs.readSync(fd, buf, 0, SCAN_CHUNK, pos)
      if (n <= 0) return false
      if (buf.subarray(0, n).includes(need)) return true
      if (n < SCAN_CHUNK) return false
      pos += n - overlap
    }
  } catch {
    return false
  } finally {
    if (fd !== undefined) try { fs.closeSync(fd) } catch { /* already gone */ }
  }
}

// Which live session's transcript contains this uuid? Heads first, since that is
// free; only then scan whole files, which is why the answer gets cached.
function ownerOf(uuid, self, heads) {
  // A fork cannot predate its origin, so only sessions that STARTED EARLIER are
  // candidates. Without this the arrow can point either way — and did: resuming a
  // session put a compaction-boundary record (which carries logicalParentUuid) at
  // the head of its transcript, and its own fork holds verbatim COPIES of its
  // records, so the uuid was found there and the parent was declared a fork of its
  // child. Both directions then resolved at once, drawing a two-node cycle.
  const older = (h) => h !== self && h.dir === self.dir && h.birth && h.birth < self.birth
  for (const [sid, h] of heads) {
    if (older(h) && h.uuids.has(uuid)) return sid
  }
  for (const [sid, h] of heads) {
    if (older(h) && fileHasUuid(h.file, uuid)) return sid
  }
  return null
}

function linkForks(nodes) {
  const heads = new Map()
  for (const n of nodes) {
    if (!n.sid) continue
    const h = headOf(n.sid)
    if (h) heads.set(n.sid, h)
  }

  for (const n of nodes) {
    if (!n.sid) continue
    if (forkCache.has(n.sid)) {
      n.forkOf = forkCache.get(n.sid)
      continue
    }
    const h = heads.get(n.sid)
    if (!h) continue

    let origin = null
    for (const [sid, other] of heads) {
      if (sid === n.sid || other.dir !== h.dir) continue
      let shared = false
      for (const u of h.uuids) {
        if (other.uuids.has(u)) { shared = true; break }
      }
      // Whichever transcript was created second is the fork. On equal birth times
      // the direction is unknowable, so no edge — better absent than backwards.
      if (shared && h.birth > other.birth) { origin = sid; break }
    }
    if (!origin && h.logicalParent) origin = ownerOf(h.logicalParent, h, heads)

    forkCache.set(n.sid, origin)
    n.forkOf = origin
  }
}

function parsePicker(out) {
  const rows = []
  for (const line of out.split('\n')) {
    if (!line) continue
    const f = line.split('\t')
    if (f.length < 6) continue
    const icon = f[2].replace(ANSI, '').trim() // "● working"
    const state = (icon.split(/\s+/).pop() || '').toLowerCase()
    rows.push({
      id: f[1],
      state: ['working', 'idle', 'waiting', 'bg'].includes(state) ? state : 'unknown',
      age: f[3].trim(),
      label: f[4].trim(),
      path: f[5].trim(),
      sid: (f[6] || '').trim(),
    })
  }
  return rows
}

async function attachedMap() {
  const out = await run('tmux', ['list-sessions', '-F', '#{session_name}\t#{session_attached}'])
  const m = new Map()
  for (const line of out.split('\n')) {
    if (!line) continue
    const [name, att] = line.split('\t')
    m.set(name, att === '1')
  }
  return m
}

// id -> {status, step, target}. A task file names the tmux session it drives;
// that field is the only place the orch -> session parent edge exists.
function readQueue() {
  const bySession = new Map()
  let files = []
  try {
    files = fs.readdirSync(QUEUE).filter((f) => f.startsWith('task-') && f.endsWith('.json'))
  } catch {
    return bySession
  }
  for (const f of files) {
    try {
      const t = JSON.parse(fs.readFileSync(path.join(QUEUE, f), 'utf8'))
      if (!t.session) continue
      bySession.set(t.session, {
        id: t.id,
        status: t.status || '?',
        step: `${(t.cursor || 0) + 1}/${(t.steps || []).length || 1}`,
        target: t.target || '',
        // tmux session that ran `orch add`. Absent on tasks queued before this
        // field existed, and may name a session that has since exited — the
        // client falls back to the orch bucket in both cases.
        parent: t.parent || '',
      })
    } catch {
      // A half-written task file is normal while orch is dispatching. Skip it.
    }
  }
  return bySession
}

async function snapshot() {
  const [pickerOut, attached] = await Promise.all([run(PICKER, ['--list']), attachedMap()])
  const tasks = readQueue()
  const rows = parsePicker(pickerOut)

  const nodes = rows.map((r) => ({
    ...r,
    attached: attached.get(r.id) === true,
    kind: tasks.has(r.id) ? 'task' : 'free',
    task: tasks.get(r.id) || null,
    prompt: lastPrompt(r),
  }))

  linkForks(nodes)
  // linkForks works in Claude session ids; the graph is keyed by tmux session name.
  const bySid = new Map(nodes.filter((n) => n.sid).map((n) => [n.sid, n.id]))
  for (const n of nodes) {
    n.forkOf = (n.forkOf && bySid.get(n.forkOf)) || null
    n.forkLabel = n.forkOf ? (nodes.find((p) => p.id === n.forkOf) || {}).label || '' : ''
  }

  const edges = []
  if (nodes.some((n) => n.kind === 'task')) {
    nodes.push({
      id: 'orch',
      label: 'orch',
      state: 'dispatcher',
      age: '',
      path: '',
      kind: 'dispatcher',
      attached: attached.get('orch') === true,
      alive: attached.has('orch'),
      task: null,
    })
    for (const n of nodes) if (n.kind === 'task') edges.push({ source: 'orch', target: n.id })
  }

  return { t: Date.now(), nodes, edges }
}

const clients = new Set()
let last = ''

async function tick() {
  let snap
  try {
    snap = await snapshot()
  } catch (e) {
    console.error('poll failed:', e.message)
    return
  }
  const json = JSON.stringify(snap)
  if (json === last) return // nothing moved; don't wake the browser
  last = json
  for (const res of clients) res.write(`data: ${json}\n\n`)
}

const handler = async (req, res) => {
  if (req.url === '/events') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
    })
    clients.add(res)
    // Seed the new client immediately; `last` is only set after a diff, so a
    // client connecting mid-quiet-period would otherwise stare at an empty page.
    res.write(`data: ${JSON.stringify(await snapshot())}\n\n`)
    req.on('close', () => clients.delete(res))
    return
  }
  fs.readFile(PAGE, (err, buf) => {
    if (err) {
      res.writeHead(500, { 'Content-Type': 'text/plain' })
      res.end(`cannot read ${PAGE}: ${err.message}`)
      return
    }
    // no-store, because the page is the source file and it gets edited constantly.
    // Served without any validator (no ETag, no Last-Modified) a browser falls back
    // to heuristic caching and will happily re-run yesterday's JS on a plain reload —
    // which reads as "the fix did not work" rather than "you are looking at old code".
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
    })
    res.end(buf)
  })
}

// Guarded so `require()`ing this file for a test does not bind a port or start
// polling; only running it as a program does.
if (require.main === module) {
  // Both loopback stacks, listed explicitly rather than binding 0.0.0.0.
  // Chrome resolves `localhost` to ::1 first on macOS, so an IPv4-only listener
  // shows a connection-refused error page even though curl -4 succeeds.
  for (const host of ['127.0.0.1', '::1']) {
    const s = http.createServer(handler)
    s.on('error', (e) => console.error(`listen ${host}: ${e.code}`))
    s.listen(PORT, host)
  }

  console.log(`claude session graph → http://localhost:${PORT}  (poll ${POLL_MS}ms)`)
  setInterval(tick, POLL_MS)
}

module.exports = { linkForks, headOf, readHead, findTranscript }
