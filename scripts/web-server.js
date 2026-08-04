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
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
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
