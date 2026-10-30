import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, SessionRateLimit } from 'claude-code'

import type { Board, Slot } from '../types'

const PANE = 'account-picker'
const TITLE = 'Claude accounts'
// Toast once a window of the live account is this full. The pane opens only on /accounts.
const ALERT_AT_PERCENT_USED = 90
// claude-account waits this long for another switch to finish, and the run gets
// SWITCH_TIMEOUT_MS in all. The wait must end well first, so a busy lock gives
// its own message and the run is never stopped halfway through a switch.
const LOCK_WAIT_S = 20
const SWITCH_TIMEOUT_MS = 60_000

// claude-account swaps the login file Claude Code keeps on Linux. On macOS the
// login lives in the Keychain, and other systems are untested, so off Linux the
// pane says so and offers no switch.
const LINUX_ONLY = 'The switch works on Linux only for now.'

const EMPTY: Board = { slots: [], isLoading: false, isUnsupported: false, note: '', readAt: 0 }
// Change the tag when Slot or Board change shape: it declines older values.
const board = atom({ plugin: 'account-picker', key: 'board' } as const, EMPTY, {
  shape: 'board-4',
})
// A weekly window resets within 7 days, so an older claim folder is spent.
const CLAIM_KEEP_DAYS = 8

const left = (used: number | null) => (used === null ? null : 100 - used)

// claude-account works the hold out from the cap and unusable marks.
const isHeld = (s: Slot, now: number) => s.held_until !== null && s.held_until > now

type Read = Slot & { week_used: number; five_hour_used: number }
const hasRoom = (s: Slot): s is Read =>
  (left(s.week_used) ?? 0) > 5 && (left(s.five_hour_used) ?? 0) > 5

// The slot to suggest: one with no hold on it, most weekly room first, then
// most 5-hour room. Weekly room lasts longer, so it ranks first.
export const best = (slots: Slot[], now: number): string | null =>
  slots
    .filter(s => !s.active && !isHeld(s, now))
    .filter(hasRoom)
    .sort((a, b) => a.week_used - b.week_used || a.five_hour_used - b.five_hour_used)[0]
    ?.name ?? null

const ago = (seconds: number) =>
  seconds < 7200 ? `${Math.round(seconds / 60)}m ago` : `${Math.round(seconds / 3600)}h ago`

// Reset times show in the machine's own time zone.
const clock = (epoch: number) =>
  new Date(epoch * 1000).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })

const day = (epoch: number) => new Date(epoch * 1000).toLocaleDateString('en-GB', { weekday: 'short' })

const home = async ($: EngineInterface) => (await $.env.get('HOME')) ?? null

// The copy of claude-account that ships in this plugin, so the CLI and the mod
// always match; CLAUDE_ACCOUNT_BIN names another one. It runs through bash, so
// a copy that lost its exec bit on install still runs.
const tool = async ($: EngineInterface, args: string[]) => [
  'bash',
  (await $.env.get('CLAUDE_ACCOUNT_BIN')) || `${$.plugin.root}/bin/claude-account`,
  ...args,
]

// uname runs once per load: the answer cannot change while the mod runs.
let linux: Promise<boolean> | null = null
const isLinux = ($: EngineInterface) =>
  (linux ??= $.process
    .run(['uname', '-s'], { timeoutMs: 5_000 })
    .then(ran => ran.exitCode === 0 && ran.stdout.trim() === 'Linux', () => false))

const isNumOrNull = (v: unknown) => v === null || typeof v === 'number'
const isSlot = (v: unknown): v is Slot => {
  if (typeof v !== 'object' || v === null) return false
  const s = v as Record<string, unknown>
  return (
    typeof s.name === 'string' &&
    typeof s.active === 'boolean' &&
    typeof s.pinned === 'boolean' &&
    ['capped_at', 'unusable_at', 'held_until', 'five_hour_used', 'five_hour_resets_at', 'week_used', 'week_resets_at']
      .every(k => isNumOrNull(s[k]))
  )
}

// The slots of a `status --json` answer, or null when it is missing or another
// shape (an older claude-account, a failed run): a bad value never reaches the board.
export const parseSlots = (text: string): Slot[] | null => {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return null
  }
  if (typeof raw !== 'object' || raw === null) return null
  const r = raw as Record<string, unknown>

  return Array.isArray(r.slots) && r.slots.every(isSlot) ? r.slots : null
}

// Each read takes a number. Only the newest read writes the board, so an older
// answer never overwrites a newer one, and every caller keeps its own note.
let reads = 0

// `slot` limits the network read to the one account that changed.
const readBoard = async ($: EngineInterface, note: string, slot?: string) => {
  const mine = ++reads
  if (!(await isLinux($))) {
    await update($, board, () => ({ ...EMPTY, isUnsupported: true, note: LINUX_ONLY }))
    return
  }
  await update($, board, b => ({ ...b, isLoading: true, note: note || 'Reading every account...' }))
  // `usage --quiet` refreshes the cache that `status --json` reads from.
  await $.process
    .run(await tool($, ['usage', ...(slot ? ['--slot', slot] : []), '--quiet']), { timeoutMs: 90_000 })
    .catch(() => undefined)
  const ran = await $.process.run(await tool($, ['status', '--json']), { timeoutMs: 30_000 }).catch(() => null)
  const slots = (ran && parseSlots(ran.stdout)) ?? []
  const readAt = Math.round((await $.clock.now()) / 1000)
  if (mine !== reads) return

  await update($, board, () => ({
    slots,
    isLoading: false,
    isUnsupported: false,
    note: slots.length === 0 ? 'Could not read the accounts (claude-account status --json failed).' : note,
    readAt,
  }))
}

// Every caller is a button or command that does not wait, so a failed read must
// not reject: it clears the loading state and says so instead.
const refresh = ($: EngineInterface, note = '', slot?: string) =>
  readBoard($, note, slot).catch(() =>
    update($, board, b => ({ ...b, isLoading: false, note: 'Could not read the accounts.' })).catch(() => undefined),
  )

// One switch at a time: two `claude-account switch` runs at once each copy the
// live login back to its slot and overwrite it, so one slot can end up holding
// the other account's login. Set before the first await, so a second press sees it.
let switching: string | null = null

const switchTo = async ($: EngineInterface, name: string) => {
  if (switching !== null) {
    $.ui.toast(`A switch to ${switching} is still running.`)
    return
  }
  switching = name
  try {
    await update($, board, b => ({ ...b, isLoading: true, note: `Switching to ${name}...` }))
    const ran = await $.process
      .run(await tool($, ['switch', name]), {
        timeoutMs: SWITCH_TIMEOUT_MS,
        env: { CLAUDE_ACCOUNT_LOCK_WAIT: String(LOCK_WAIT_S), CLAUDE_ACCOUNT_CALLER: 'account-picker' },
      })
      .catch(() => null)
    const isOk = ran?.exitCode === 0
    // On success one short line, so the pane does not scroll; a failure keeps
    // claude-account's own words.
    const said = (text: string) => text.trim().split('\n').join(' ')
    const note =
      ran === null
        ? `Switch to ${name} did not finish in ${SWITCH_TIMEOUT_MS / 1000} s. Check with: claude-account status`
        : isOk
          ? `Live login is now ${name}. Running sessions follow on their next request.`
          : `Switch to ${name} failed: ${said(ran.stderr) || `exit code ${ran.exitCode}`}`

    // A toast is narrow: the outcome alone there, the pane keeps the full line.
    $.ui.toast(isOk ? `Live login is now ${name}.` : note)
    await refresh($, note, isOk ? name : undefined)
  } finally {
    switching = null
  }
}

const show = async ($: EngineInterface) => {
  await $.ui.open({ id: PANE, title: TITLE, focus: true, closeOnEscape: true })
  await refresh($)
}

const isOver = (l: SessionRateLimit) =>
  (l.kind === 'five_hour' || l.kind === 'seven_day') && l.percentUsed >= ALERT_AT_PERCENT_USED

// One key per live slot, window and reset time: another account with the same
// reset time still alerts after a switch. With no reset time the key is fixed,
// and the claim holds for one window length instead (see `claim`).
const alertKey = (who: string, l: SessionRateLimit) => `${who}:${l.kind}@${l.resetsAt ?? 'none'}`

const windowMinutes = (l: SessionRateLimit) => (l.kind === 'five_hour' ? 5 * 60 : 7 * 24 * 60)

// Each window alerts once on the machine, whatever the number of sessions: the
// session whose mkdir makes the window's folder toasts. mkdir is atomic, so two
// sessions never both win, and the folders outlive any one session.
// `holdMinutes` (no reset time only): the key gets numbered folders, `key#1`,
// `key#2`, and a session makes the next number once the highest is older than
// that. A session that read an old list tries a number another session already
// made, and its mkdir fails. The age cleanup skips numbered folders: the winner
// removes the lower numbers after it made the next one, so a list always shows
// the highest number and no session starts again at #1.
// With no HOME there is no shared folder to claim in, so nothing alerts.
const claim = async ($: EngineInterface, key: string, holdMinutes?: number) => {
  const h = await home($)
  if (h === null) return false
  const dir = `${h}/.claude/state/account-picker-alerted`
  const base = key.replace(/[^A-Za-z0-9._:@-]/g, '_')
  const mkdir = async (name: string) =>
    (await $.process.run(['mkdir', `${dir}/${name}`], { timeoutMs: 5_000 }).catch(() => null))?.exitCode === 0
  await $.process.run(['mkdir', '-p', dir], { timeoutMs: 5_000 }).catch(() => undefined)
  void $.process
    .run(
      ['find', dir, '-mindepth', '1', '-maxdepth', '1', '-not', '-name', '*#*', '-mtime', `+${CLAIM_KEEP_DAYS}`, '-exec', 'rmdir', '{}', '+'],
      { timeoutMs: 5_000 },
    )
    .catch(() => undefined)
  if (holdMinutes === undefined) return mkdir(base)

  // $.fs, not `find -printf`: macOS find has no -printf.
  const listed = await $.fs.list(dir).catch(() => null)
  if (listed === null) return false
  const numbers = listed
    .filter(entry => entry.name.startsWith(`${base}#`))
    .map(entry => Number(entry.name.slice(base.length + 1)))
  const number = Math.max(0, ...numbers)
  // A listing gives a folder no time, so stat the highest. A stat that fails
  // means a winner already made the next number and removed this one.
  const madeMs = number > 0 ? await $.fs.stat(`${dir}/${base}#${number}`).then(st => st.mtimeMs, () => null) : 0
  if (madeMs === null) return false
  if (number > 0 && (await $.clock.now()) - madeMs <= holdMinutes * 60_000) return false
  if (!(await mkdir(`${base}#${number + 1}`))) return false

  for (const n of numbers) {
    await $.process.run(['rmdir', `${dir}/${base}#${n}`], { timeoutMs: 5_000 }).catch(() => undefined)
  }

  return true
}

// The live slot's name, from claude-account's one-line active file; '?' when it
// cannot say. A file read, not a process: this runs on every turn past the line.
// It knows claude-account's folder, file name and name rule (valid_name there),
// so a change to those in bin/claude-account has to land here too.
const liveSlot = async ($: EngineInterface) => {
  const h = await home($)
  const dir = (await $.env.get('CLAUDE_ACCOUNTS_DIR')) ?? (h === null ? null : `${h}/.claude-accounts`)
  const name = dir === null ? '' : (await $.fs.read(`${dir}/active`).catch(() => '')).trim()

  const isReserved = ['active', 'capped', 'backups', 'unknown', 'unusable'].includes(name)

  return /^[A-Za-z0-9_-]+$/.test(name) && !isReserved ? name : '?'
}

const usageLine = (s: Slot) => {
  if (s.five_hour_used === null || s.week_used === null) {
    return '  No reading: the saved login is old. Switch to it to read it.'
  }
  const fiveReset = s.five_hour_resets_at ? ` (resets ${clock(s.five_hour_resets_at)})` : ''
  const weekReset = s.week_resets_at ? ` (resets ${day(s.week_resets_at)} ${clock(s.week_resets_at)})` : ''

  return `  5-hour: ${left(s.five_hour_used)}% left${fiveReset}   Weekly: ${left(s.week_used)}% left${weekReset}`
}

const markLine = (s: Slot, now: number) => {
  if (s.unusable_at !== null) return `  Marked unusable ${ago(now - s.unusable_at)}`
  if (s.capped_at !== null) return `  Hit a limit ${ago(now - s.capped_at)}`
  return null
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'accounts',
      description: 'Show every Claude account with its 5-hour and weekly room, and switch',
    })

    return next(e)
  })

  on('command.run', { command: 'accounts' }, async $ => {
    void show($)

    return { text: 'Account picker opened.' }
  })

  on('session.measure', async ($, e, next) => {
    // Off Linux, /accounts has no switch to offer, so the toast would point nowhere.
    if (!e.rateLimits.some(isOver) || !(await isLinux($))) return next(e)

    // The weekly window still alerts after the 5-hour one did: toast the first
    // window past the line that this call claims for the live slot.
    const who = await liveSlot($)
    let low: SessionRateLimit | undefined
    for (const l of e.rateLimits.filter(isOver)) {
      if (await claim($, alertKey(who, l), l.resetsAt ? undefined : windowMinutes(l))) {
        low = l
        break
      }
    }
    if (!low) return next(e)

    const window = low.kind === 'five_hour' ? '5-hour' : 'weekly'
    $.ui.toast(`This account has used ${low.percentUsed}% of its ${window} limit. Type /accounts to pick another.`)

    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const b = await read($, board)
    const pick = best(b.slots, b.readAt)

    if (b.isUnsupported) {
      return (
        <Box flexDirection="column">
          <Text>{b.note}</Text>
          <Box marginTop={1}>
            <Button key="close" role="dismiss" dimColor onPress={() => void $.ui.close({ id: PANE })}>
              Close
            </Button>
          </Box>
        </Box>
      )
    }

    return (
      <Box flexDirection="column">
        {b.note !== '' && <Text dimColor>{b.note}</Text>}
        {b.slots.length === 0 && !b.isLoading && <Text dimColor>No accounts read yet.</Text>}
        {b.slots.map(s => {
          const mark = markLine(s, b.readAt)

          return (
            <Box key={s.name} flexDirection="column" marginTop={1}>
              <Text bold={s.active}>
                {s.name}
                {s.active ? '  (live now)' : ''}
                {s.pinned ? '  (pinned)' : ''}
                {s.name === pick ? '  best pick' : ''}
              </Text>
              <Text dimColor={s.five_hour_used === null}>{usageLine(s)}</Text>
              {mark !== null && <Text dimColor>{mark}</Text>}
              {!s.active && !b.isLoading && (
                <Button
                  key={`use-${s.name}`}
                  variant={s.name === pick ? 'primary' : undefined}
                  autoFocus={s.name === pick || undefined}
                  onPress={() => void switchTo($, s.name)}
                >
                  Switch to {s.name}
                </Button>
              )}
            </Box>
          )
        })}
        <Box marginTop={1}>
          {!b.isLoading && (
            <Button key="refresh" dimColor onPress={() => void refresh($)}>
              Refresh
            </Button>
          )}
          <Text> </Text>
          <Button key="close" role="dismiss" dimColor onPress={() => void $.ui.close({ id: PANE })}>
            Close
          </Button>
        </Box>
      </Box>
    )
  })
}
