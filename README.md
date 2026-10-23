# claude-account

[![CI](https://github.com/kwadwoadu/claude-account/actions/workflows/ci.yml/badge.svg)](https://github.com/kwadwoadu/claude-account/actions/workflows/ci.yml)

**Run several Claude Code subscriptions on one machine, and switch between them in one command.**

![claude-account saving two logins, reading how much each has left, and switching between them](assets/demo.gif)

Claude Code keeps one login per machine. When one subscription hits its 5-hour or weekly limit, you have to `/login` again, go through the browser, and come back. claude-account saves each login once, then swaps them in place. Running sessions pick up the new login before their next request, with no restart.

```
 /login in Claude Code ──▶ ~/.claude/.credentials.json  (the live login)
                                    │  claude-account save work
                                    ▼
                         ~/.claude-accounts/work.json   (a saved slot)
                                    │  claude-account switch work
                                    ▼
             live login replaced ──▶ running sessions reload it
```

## What it does

- **Save** each login as a named slot: `work`, `personal`, `team`, as many as you like.
- **Switch** to a slot, or rotate to the **next** one, in a second.
- **Read how much is left** on every subscription (5-hour and weekly windows) without switching into it.
- **Check who you are**: which slot is live, and whether an `ANTHROPIC_API_KEY` in your shell silently overrides the login.
- **Never lose a login**: the live token is copied back to its slot before a switch, a blank token from a failed refresh is never saved over a good slot, and the live login is backed up before it is replaced.

Conversations are not tied to the login. They stay in `~/.claude/projects/`, so switching accounts leaves every conversation in place.

## Install

Linux, with `bash`, `python3` and `curl`.

```bash
git clone https://github.com/kwadwoadu/claude-account.git
cd claude-account
./install.sh            # installs to ~/.local/bin (PREFIX=/usr/local to change)
```

Tab completion for bash or zsh: add `source ~/.local/share/claude-account/completion.sh` to your shell config.

## Usage

```bash
# 1. In Claude Code, /login with your first account, then:
claude-account save work

# 2. /login with the second account, then:
claude-account save personal

# 3. From now on:
claude-account usage            # how much is left on each, read without switching
claude-account switch work      # make work the live login
claude-account next             # rotate to the next slot
claude-account status           # slots, the active one, cached usage
claude-account whoami           # which login is really live, and any API key override
```

| Command | What it does |
|---|---|
| `status` / `list` | Active slot, saved slots, cached usage, cap marks |
| `whoami` / `who` | Which slot is live, and the email of the last `/login`; warns on drift, a blank token, or an `ANTHROPIC_*` override |
| `save <Name>` | Store the live login as a slot, and mark it active |
| `switch <Name>` / `use` | Make that slot the live login |
| `next` / `swap` | Switch to the next slot in alphabetical order |
| `usage [--slot <Name>] [--quiet]` | Read the 5-hour and weekly limits per slot; refreshes the cache `status` reads |
| `pin` / `unpin` | Write or remove `~/.claude-accounts/pinned`, a hold flag for your own auto-rotation scripts |

After any manual `/login`, run `claude-account save <Name>` so the slot matches the new login.

## How it works

Claude Code on Linux keeps its OAuth login in one file, `~/.claude/.credentials.json`, and refreshes the token in that file by itself. claude-account keeps copies of that file in `~/.claude-accounts/<Name>.json` and swaps which copy is live:

1. **Copy back.** The live token may have been refreshed since the last save, so it is copied back into the active slot first. A blank token is never copied back.
2. **Back up.** The live file goes to `~/.claude-accounts/backups/` (the last 10 are kept).
3. **Swap.** The chosen slot is written over the live file in one atomic step (temp file, then rename), mode 600.

Claude Code checks the date of the login file before each token use and reloads it when it changed, so running sessions follow the switch.

`usage` calls `https://api.anthropic.com/api/oauth/usage`, the endpoint Claude Code itself uses, with each slot's access token. Saved slots often carry an expired access token, because only a running session refreshes one. In that case the slot shows "no reading". claude-account never refreshes a token itself, because a refresh rotates the refresh token and would log out any other machine that uses the same copy.

## Security

- Slots are real OAuth tokens. `~/.claude-accounts` is mode 700 and every slot is mode 600. Never commit, sync or share that folder.
- The access token reaches `curl` on stdin, never as an argument, so it does not show in the process list.
- Slot names are limited to letters, digits, `-` and `_`, so a name can never point outside the folder.
- Nothing is sent anywhere except the Anthropic usage endpoint, and only by `usage`.

See [SECURITY.md](SECURITY.md) to report a problem.

## Limitations

- **Linux only for now.** On macOS, Claude Code keeps its login in the Keychain, not in a file.
- One login per slot. Two machines that share one slot's file will log each other out on refresh; log in separately on each machine.
- `usage` relies on an endpoint Claude Code uses internally. It is not a public API and may change.
- Running sessions follow a switch on recent Claude Code versions (2.x). An older version needs a restart (`claude --resume` keeps the conversation).

## Tests

```bash
bash tests/claude-account.test.sh   # sandboxed: temp dir, fake logins, no network
```

MIT licensed. Built by Kwadwo Adu.
