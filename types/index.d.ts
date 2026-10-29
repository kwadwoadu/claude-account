// One slot as `claude-account status --json` prints it: percents USED, times
// as epoch seconds, null where there is no value. held_until is when the hold
// on the slot ends (a recent cap or unusable mark), null when there is none.
export type Slot = {
  name: string
  active: boolean
  pinned: boolean
  capped_at: number | null
  unusable_at: number | null
  held_until: number | null
  five_hour_used: number | null
  five_hour_resets_at: number | null
  week_used: number | null
  week_resets_at: number | null
}

export type Board = {
  slots: Slot[]
  isLoading: boolean
  // True off Linux: the pane shows `note` alone and offers no switch.
  isUnsupported: boolean
  note: string
  // Epoch seconds of the last read, for the "capped 3h ago" ages.
  readAt: number
}

declare module 'claude-code' {
  interface PluginState {
    'account-picker': {
      board: Shaped<Board>
    }
  }
}
