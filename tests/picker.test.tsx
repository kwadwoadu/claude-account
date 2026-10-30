import type { CommandRunInput, SessionMeasureInput, SessionRateLimit } from 'claude-code'
import { expect, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

import { best, parseSlots } from '../hooks/register'
import type { Slot } from '../types'

// The test runner has timers; the hooks environment's types leave them out.
declare const setTimeout: (fn: () => void, ms: number) => unknown

const wait = async (ms: number) => {
  await new Promise<void>(resolve => setTimeout(resolve, ms))
}
const settle = () => wait(50)

const NOW = 1_793_000_000
const HOUR = 3_600_000
const CLAIMS = '/home/test/.claude/state/account-picker-alerted'

const slot = (name: string, over: Partial<Slot> = {}): Slot => ({
  name,
  active: false,
  pinned: false,
  capped_at: null,
  unusable_at: null,
  held_until: null,
  five_hour_used: null,
  five_hour_resets_at: null,
  week_used: null,
  week_resets_at: null,
  ...over,
})

// 2026-10-28 19:10 UTC. The pane shows it in the machine's own time zone.
const RESET = 1_793_214_600
const RESET_CLOCK = new Date(RESET * 1000).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })

const STATUS = JSON.stringify({
  active: 'work',
  pinned: 'work',
  slots: [
    slot('old', { capped_at: NOW - 280_000, unusable_at: NOW - 190_000 }),
    slot('spare', { five_hour_used: 100, week_used: 98 }),
    slot('personal', { five_hour_used: 20, five_hour_resets_at: RESET, week_used: 60 }),
    slot('work', { active: true, pinned: true, five_hour_used: 96, week_used: 43 }),
  ],
})

const PANE = {
  plugin: 'account-picker',
  component: 'Pane',
  requestId: 'account-picker',
  props: {
    title: 'Claude accounts',
    isFocused: true,
    bodyColumns: 60,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
} as const

const FIVE: SessionRateLimit = { kind: 'five_hour', percentUsed: 96, resetsAt: '2026-10-28T20:10:00Z' }
const WEEK: SessionRateLimit = { kind: 'seven_day', percentUsed: 92, resetsAt: '2026-11-02T07:00:00Z' }
// A window the response gave no reset time for.
const bare = (kind: string): SessionRateLimit => ({ kind, percentUsed: 95 })
const measureAt = (rateLimits: SessionRateLimit[]): SessionMeasureInput => ({
  context: { window: 200000 },
  rateLimits,
  changed: ['rateLimits'],
})
const ACCOUNTS: CommandRunInput = {
  command: 'accounts',
  args: '',
  origin: { kind: 'composer' },
  presentation: { isFullscreen: false, columns: 80 },
}

type Ran = { exitCode: number; stdout: string; stderr: string }
const done = (r: Ran) => ({ value: { ...r, isStdoutTruncated: false, isStderrTruncated: false } })

// uname, as the operating system answers it.
const unameRun = (argv: readonly string[], os: string) =>
  argv[0] === 'uname' ? done({ exitCode: 0, stdout: `${os}\n`, stderr: '' }) : null

// The claim folders and when each was made, kept in a map the test owns:
// `mkdir` of a folder already made fails, as on disk, and the age cleanup and
// `rmdir` remove. `fs.list` and `fs.stat` read the same folders. Sessions on one
// machine share the map.
const claimRun = (argv: readonly string[], made: Map<string, number>, now: number) => {
  const [cmd, a1] = argv
  const ran = (exitCode: number) => done({ exitCode, stdout: '', stderr: '' })
  if (cmd === 'find' && argv.includes('-mtime')) {
    // The age cleanup, as on disk: older than its days, numbered folders kept
    // only when the command says `-not -name '*#*'`.
    const days = Number(argv[argv.indexOf('-mtime') + 1]!.slice(1))
    const keepsNumbered = argv.includes('-not')
    for (const [path, ms] of [...made]) {
      if (!(keepsNumbered && path.includes('#')) && now - ms > days * 86_400_000) made.delete(path)
    }
    return ran(0)
  }
  if (cmd === 'rmdir') {
    made.delete(a1!)
    return ran(0)
  }
  if (cmd === 'mkdir' && a1 === '-p') return ran(0)
  if (cmd !== 'mkdir') return null
  if (made.has(a1!)) return ran(1)
  made.set(a1!, now)
  return ran(0)
}

type On = Parameters<TestBody>[1]
type Stubs = {
  // claude-account runs only, its arguments after the script path; uname and
  // claim folder commands are kept out.
  runs: string[][]
  // What each claude-account run started: the shell and the script path.
  starts: string[][]
  toasts: string[]
  envs: ({ readonly [k: string]: string } | undefined)[]
  opened: number
  // What the live slot file holds.
  live: string
  made: Map<string, number>
  nowMs: number
}

// The engine every test shares. claude-account answers STATUS for status,
// `switchResult()` for a switch (after `switchMs`), and ok for the rest.
// `listing` hands a session an old list of claim folder names.
const stubs = (
  on: On,
  opts: {
    switchMs?: number
    switchResult?: () => Ran | 'timeout'
    made?: Map<string, number>
    listing?: () => string[]
    clockFails?: boolean
    os?: string
    env?: Record<string, string>
  } = {},
): Stubs => {
  const s: Stubs = {
    runs: [],
    starts: [],
    toasts: [],
    envs: [],
    opened: 0,
    live: 'work',
    made: opts.made ?? new Map(),
    nowMs: NOW * 1000,
  }
  on('process.run', async (_, e) => {
    const other = unameRun(e.argv, opts.os ?? 'Linux') ?? claimRun(e.argv, s.made, s.nowMs)
    if (other) return other
    s.starts.push(e.argv.slice(0, 2))
    s.runs.push(e.argv.slice(2))
    s.envs.push(e.init?.env)
    let out: Ran = { exitCode: 0, stdout: 'ok\n', stderr: '' }
    if (e.argv[2] === 'status') out = { ...out, stdout: STATUS }
    if (e.argv[2] === 'switch') {
      if (opts.switchMs) await wait(opts.switchMs)
      const r = opts.switchResult?.()
      if (r === 'timeout') throw new Error('timed out')
      if (r) out = r
    }
    return done(out)
  })
  on('fs.read', (_, e) => {
    if (e.path !== '/home/test/.claude-accounts/active') throw new Error(`unexpected read ${e.path}`)
    return { value: `${s.live}\n` }
  })
  on('fs.list', (_, e) => {
    const dir = (e as { path: string }).path
    const names = opts.listing
      ? opts.listing()
      : [...s.made.keys()].filter(path => path.startsWith(`${dir}/`)).map(path => path.slice(dir.length + 1))
    return { value: names.map(name => ({ name, kind: 'dir', size: 0, mtimeMs: 0, isLink: false })) }
  })
  on('fs.stat', (_, e) => {
    const ms = s.made.get((e as { path: string }).path)
    return ms === undefined ? { deny: 'missing' } : { value: { kind: 'dir', size: 0, mtimeMs: ms, isLink: false } }
  })
  on('ui.open', () => {
    s.opened += 1
    return { value: { isPlaced: true } }
  })
  on('clock.now', () => {
    if (opts.clockFails) throw new Error('clock gone')
    return { value: s.nowMs }
  })
  on('env.get', (_, e) => ({ value: ({ HOME: '/home/test', ...opts.env } as Record<string, string>)[e.name] }))
  on('ui.toast', (_, e) => {
    s.toasts.push(String(e.text))
    return { value: undefined }
  })
  on('session.measure', (_, e) => ({ changed: e.changed }))

  return s
}

test('more weekly room wins over more 5-hour room', async () => {
  const slots = [
    slot('A', { five_hour_used: 10, week_used: 70 }),
    slot('B', { five_hour_used: 80, week_used: 30 }),
  ]

  expect(best(slots, NOW)).toBe('B')
})

test('never suggests the live account, a nearly empty one, or one with no reading', async () => {
  const slots = [
    slot('Live', { active: true, five_hour_used: 0, week_used: 0 }),
    slot('Empty', { five_hour_used: 97, week_used: 10 }),
    slot('Unread'),
  ]

  expect(best(slots, NOW)).toBe(null)
})

test('follows the hold claude-account reports', async () => {
  const room = { five_hour_used: 10, week_used: 10 }

  expect(best([slot('A', { ...room, held_until: NOW + 600 })], NOW)).toBe(null)
  expect(best([slot('A', { ...room, held_until: NOW - 1 })], NOW)).toBe('A')
  expect(best([slot('A', { ...room, capped_at: NOW - 60 })], NOW)).toBe('A')
})

test('a status answer of another shape is refused, not cast', async () => {
  expect(parseSlots(STATUS)?.length).toBe(4)
  expect(parseSlots('{"active":"A"}')).toBe(null)
  expect(parseSlots('{"slots":{}}')).toBe(null)
  expect(parseSlots('{"slots":[{"name":"A"}]}')).toBe(null)
  expect(parseSlots('not json')).toBe(null)
  expect(parseSlots('null')).toBe(null)
})

test('a low live window toasts once and never opens the picker, and a press switches', async ($, on) => {
  const s = stubs(on)

  await $.session.measure(measureAt([FIVE]))
  await $.session.measure(measureAt([FIVE]))
  await settle()
  expect(s.toasts.length).toBe(1)
  expect(s.opened).toBe(0)

  await $.command.run(ACCOUNTS)
  await settle()
  expect(s.opened).toBe(1)
  expect(s.runs).toContainEqual(['status', '--json'])

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /best pick/ }))?.text).toContain('personal')
  expect((await ui.find({ type: 'Text', text: /5-hour: 80% left/ }))?.text).toContain(`resets ${RESET_CLOCK}`)
  expect((await ui.find({ type: 'Text', text: /Marked unusable/ }))?.text).toContain('53h ago')

  s.runs.length = 0
  s.envs.length = 0
  await ui.press({ key: 'use-personal' })
  await settle()
  expect(s.runs[0]).toEqual(['switch', 'personal'])
  // claude-account gives up on a busy lock well before the run is stopped.
  expect(s.envs[0]).toEqual({ CLAUDE_ACCOUNT_LOCK_WAIT: '20', CLAUDE_ACCOUNT_CALLER: 'account-picker' })
  // After a switch only the account that changed is read again.
  expect(s.runs[1]).toEqual(['usage', '--slot', 'personal', '--quiet'])
  // The toast is narrow, so it says only the outcome.
  expect(s.toasts.at(-1)).toBe('Live login is now personal.')
  // The pane's note is one line, so the pane does not scroll after a switch.
  expect((await ui.find({ type: 'Text', text: /Live login is now/ }))?.text).toBe('Live login is now personal. Running sessions follow on their next request.')
  await ui.unmount()
})

test('runs the claude-account this plugin ships, through bash', async ($, on) => {
  const s = stubs(on)
  await $.command.run(ACCOUNTS)
  await settle()

  expect(s.starts.length > 0).toBe(true)
  for (const [shell, path] of s.starts) {
    expect(shell).toBe('bash')
    expect(path).toMatch(/^\/.*\/bin\/claude-account$/)
  }
})

test('CLAUDE_ACCOUNT_BIN names another claude-account', async ($, on) => {
  const s = stubs(on, { env: { CLAUDE_ACCOUNT_BIN: '/opt/tools/claude-account' } })
  await $.command.run(ACCOUNTS)
  await settle()

  expect(s.starts).toContainEqual(['bash', '/opt/tools/claude-account'])
  expect(s.starts.every(([, path]) => path === '/opt/tools/claude-account')).toBe(true)
})

test('off Linux, the pane says so in one line, offers no switch and never runs claude-account', async ($, on) => {
  const s = stubs(on, { os: 'Darwin' })

  await $.session.measure(measureAt([FIVE]))
  await $.command.run(ACCOUNTS)
  await settle()
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const line = await ui.find({ type: 'Text', text: /Linux only/ })
  const button = await ui.find({ key: 'use-personal' })
  const refresh = await ui.find({ key: 'refresh' })
  await ui.unmount()

  expect(line?.text).toBe('The switch works on Linux only for now.')
  expect(button).toBe(undefined)
  expect(refresh).toBe(undefined)
  expect(s.runs).toEqual([])
  expect(s.toasts).toEqual([])
})

test('past the line, a turn reads the live slot file and never runs claude-account', async ($, on) => {
  const s = stubs(on)

  await $.session.measure(measureAt([FIVE]))
  await $.session.measure(measureAt([FIVE, WEEK]))
  await settle()

  expect(s.runs).toEqual([])
})

test('two fast presses run one switch, never two at once', async ($, on) => {
  const s = stubs(on, { switchMs: 30 })
  await $.command.run(ACCOUNTS)
  await settle()

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const first = ui.press({ key: 'use-personal' })
  // The second press hits a real button: the first switch is still running.
  const second = await ui.press({ key: 'use-spare' })
  await first
  await settle()
  await ui.unmount()

  expect(second).not.toBe(undefined)
  expect(s.toasts).toContainEqual('A switch to personal is still running.')
  expect(s.runs.filter(a => a[0] === 'switch')).toEqual([['switch', 'personal']])
})

test('a failed or timed-out switch says what happened', async ($, on) => {
  let result: Ran | 'timeout' = {
    exitCode: 1,
    stdout: '',
    stderr: 'another claude-account switch or save is still running; nothing changed\n',
  }
  const s = stubs(on, { switchResult: () => result })
  await $.command.run(ACCOUNTS)
  await settle()
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })

  await ui.press({ key: 'use-personal' })
  await settle()
  result = 'timeout'
  await ui.press({ key: 'use-personal' })
  await settle()
  await ui.unmount()

  expect(s.toasts[0]).toBe('Switch to personal failed: another claude-account switch or save is still running; nothing changed')
  expect(s.toasts[1]).toContain('did not finish in 60 s')
})

test('a read that throws clears the loading state and says so', async ($, on) => {
  stubs(on, { clockFails: true })
  await $.command.run(ACCOUNTS)
  await settle()
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const note = await ui.find({ type: 'Text', text: /Could not read the accounts\.$/ })
  const loading = await ui.find({ type: 'Text', text: /Reading every account/ })
  await ui.unmount()

  expect(note).not.toBe(undefined)
  expect(loading).toBe(undefined)
})

test('the weekly window still alerts after the 5-hour window did', async ($, on) => {
  const s = stubs(on)

  await $.session.measure(measureAt([FIVE]))
  await $.session.measure(measureAt([FIVE, WEEK]))
  await $.session.measure(measureAt([FIVE, WEEK]))
  await settle()

  expect(s.toasts.length).toBe(2)
})

test('a new session does not alert again on a window that already alerted', async ($, on) => {
  const s = stubs(on, { made: new Map([[`${CLAIMS}/work:five_hour@2026-10-28T20:10:00Z`, NOW * 1000]]) })

  await $.session.measure(measureAt([FIVE]))
  await settle()

  expect(s.toasts.length).toBe(0)
})

test('with no reset time, a window alerts once for its whole length, then again', async ($, on) => {
  const s = stubs(on)

  await $.session.measure(measureAt([bare('five_hour')]))
  await $.session.measure(measureAt([bare('seven_day')]))
  // Past every day boundary and short of the 5-hour length: still one window.
  s.nowMs += 4.9 * HOUR
  await $.session.measure(measureAt([bare('five_hour')]))
  await settle()
  expect(s.toasts.length).toBe(2)

  // A day on: the weekly window is still the same one, the 5-hour one is spent.
  s.nowMs += 24 * HOUR
  await $.session.measure(measureAt([bare('seven_day')]))
  await $.session.measure(measureAt([bare('five_hour')]))
  await $.session.measure(measureAt([bare('five_hour')]))
  await settle()
  expect(s.toasts.length).toBe(3)
})

test('a session that read an old list cannot renew a window another session just renewed', async ($, on) => {
  const spent = `${CLAIMS}/work:five_hour@none#1`
  // Every listing shows only the spent folder, as session B read it before
  // session A made the next one.
  const s = stubs(on, { made: new Map([[spent, NOW * 1000 - 6 * HOUR]]), listing: () => ['work:five_hour@none#1'] })

  await $.session.measure(measureAt([bare('five_hour')]))
  await $.session.measure(measureAt([bare('five_hour')]))
  await settle()

  expect(s.toasts.length).toBe(1)
  expect(s.made.has(spent.replace('#1', '#2'))).toBe(true)
})

test('two sessions renewing a spent window at once toast one time between them', async ($, on) => {
  const s = stubs(on, { made: new Map([[`${CLAIMS}/work:five_hour@none#1`, NOW * 1000 - 6 * HOUR]]) })
  const at = measureAt([bare('five_hour')])

  await Promise.all([$.session.measure(at), $.session.measure(at), $.session.measure(at)])
  await settle()

  expect(s.toasts.length).toBe(1)
})

test('after nine idle days, the cleanup and a renewal never let two sessions toast', async ($, on) => {
  const s = stubs(on, {
    made: new Map([
      [`${CLAIMS}/work:five_hour@none#1`, NOW * 1000 - 9 * 86_400_000],
      [`${CLAIMS}/work:five_hour@2026-10-01T00:00:00Z`, NOW * 1000 - 9 * 86_400_000],
    ]),
  })
  const at = measureAt([bare('five_hour')])

  await Promise.all([$.session.measure(at), $.session.measure(at), $.session.measure(at)])
  await settle()

  expect(s.toasts.length).toBe(1)
  expect([...s.made.keys()]).toEqual([`${CLAIMS}/work:five_hour@none#2`])
})

test('two sessions measuring at once toast one time between them', async ($, on) => {
  const s = stubs(on)
  const at = measureAt([FIVE])

  await Promise.all([$.session.measure(at), $.session.measure(at), $.session.measure(at)])
  await settle()

  expect(s.toasts.length).toBe(1)
})

test('an older read that ends last never overwrites the newest one', async ($, on) => {
  let usage = 0
  let answer = 0
  on('process.run', async (_, e) => {
    const os = unameRun(e.argv, 'Linux')
    if (os) return os
    // The first read's network step is slow, so the second read ends first.
    if (e.argv[2] === 'usage' && ++usage === 1) await wait(100)
    // Each status answer counts up, so the older read gets the higher number.
    answer += e.argv[2] === 'status' ? 1 : 0
    const stdout = JSON.stringify({ active: 'X', pinned: null, slots: [slot('X', { active: true, five_hour_used: answer, week_used: 0 })] })
    return done({ exitCode: 0, stdout, stderr: '' })
  })
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => ({ value: NOW * 1000 }))
  on('env.get', (_, e) => ({ value: e.name === 'HOME' ? '/home/test' : undefined }))

  await $.command.run(ACCOUNTS)
  await $.command.run(ACCOUNTS)
  await wait(300)

  expect(answer).toBe(2)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  // The newer read got answer 1: 99% left. The older one (98%) is dropped.
  expect((await ui.find({ type: 'Text', text: /5-hour:/ }))?.text).toContain('99% left')
  await ui.unmount()
})

test('after a switch, the next account alerts on a window with the same reset time', async ($, on) => {
  const s = stubs(on)

  await $.session.measure(measureAt([FIVE]))
  await settle()
  s.live = 'personal'
  await $.session.measure(measureAt([FIVE]))
  await settle()

  expect(s.toasts.length).toBe(2)
})
