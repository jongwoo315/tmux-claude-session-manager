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
// ---- last typed prompt, read from the session transcript ---------------------
//
// A transcript is ~/.claude/projects/<slug>/<sessionId>.jsonl. Real prompts carry
// promptSource "typed" | "queued" | "suggestion_accepted"; the far more numerous
// tool-result entries have promptSource null and list (not string) content, and
// subagent turns are isSidechain. Filtering on those three things is what
// separates "what the user actually said" from the rest of the conversation.
//
// Transcripts reach tens of megabytes, so only the tail is read, and only when
// the file's mtime has moved. The path lookup is cached too — finding it means
// stat-ing one candidate per project directory.
const PROMPT_SRC = new Set(['typed', 'queued', 'suggestion_accepted'])
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

function scanTail(file, size, bytes) {
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
    if (o.type !== 'user' || o.isSidechain) continue
    if (!PROMPT_SRC.has(o.promptSource)) continue
    const t = o.message && o.message.content
    if (typeof t !== 'string' || !t.trim()) continue
    return t.trim().replace(/\s+/g, ' ').slice(0, PROMPT_MAX)
  }
  return null
}

function lastPrompt(sid) {
  if (!sid) return null
  let c = promptCache.get(sid)
  if (!c) {
    c = { file: findTranscript(sid), mtimeMs: 0, text: null, win: 0 }
    promptCache.set(sid, c)
  }
  if (!c.file) return null
  let st
  try { st = fs.statSync(c.file) } catch { return c.text }
  if (st.mtimeMs === c.mtimeMs) return c.text
  c.mtimeMs = st.mtimeMs

  for (const w of TAIL_STEPS) {
    if (w < c.win) continue // start where this session needed to look last time
    const text = scanTail(c.file, st.size, w)
    if (text) { c.text = text; c.win = w; return text }
    if (w >= st.size) break // whole file already scanned; nothing to find
  }
  return c.text
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
      state: ['working', 'idle', 'waiting'].includes(state) ? state : 'unknown',
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
    prompt: lastPrompt(r.sid),
  }))

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
