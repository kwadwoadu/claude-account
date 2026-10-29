# claude-account

[![CI](https://github.com/kwadwoadu/claude-account/actions/workflows/ci.yml/badge.svg)](https://github.com/kwadwoadu/claude-account/actions/workflows/ci.yml)

**Pick another Claude Code account from inside Claude Code.** Type `/accounts` to see the 5-hour and weekly room of every saved login. A toast tells you when the live account passes 90 percent of a window. One press switches the login, and running sessions follow.

![The /accounts pane in Claude Code: two saved logins with their 5-hour and weekly room, the best pick marked, and one press switching to it](assets/demo.gif)

Claude Code keeps one login per machine. When a subscription hits its 5-hour or weekly limit, you have to `/login` again, go through the browser, and come back. This repo is a Claude Code mod (the `account-picker` plugin) with a small CLI inside it (`claude-account`). The CLI saves each login once and swaps them in place. The mod shows them in Claude Code and switches with one press.

## Install

At the prompt of a Claude Code session in a terminal:

```
/plugin install account-picker --marketplace kwadwoadu/claude-account
```

Answer `y` to add the marketplace, then press Enter for the user scope. The mod runs in that session at once, and in every session after.

From a shell:

```bash
claude plugin install account-picker --marketplace kwadwoadu/claude-account
```

In the desktop app, where `/plugin` does not run: click + next to the prompt box, then Plugins, Add marketplace with `kwadwoadu/claude-account`, then Add plugin.

### Save each login

The mod switches between logins you saved once. Saving runs in a terminal, so put the CLI on your PATH from a clone:

```bash
git clone https://github.com/kwadwoadu/claude-account.git
cd claude-account
./install.sh            # installs to ~/.local/bin (PREFIX=/usr/local to change)
```

The mod uses its own copy of the CLI, so the versions always match. `install.sh` is only for the terminal. Then save each account:

```bash
# 1. In Claude Code, /login with your first account, then:
claude-account save work

# 2. /login with the second account, then:
claude-account save personal
```

Use any names you like, and as many as you have. After any later manual `/login`, run `claude-account save <Name>` again so the slot matches the new login.

Linux only, with `bash`, `python3` and `curl`.

## Use

- **`/accounts`** opens a pane with every saved login: how much of the 5-hour and weekly window is left, when each resets, and which one is live now.
- **Best pick.** The pane marks the account with the most weekly room, then the most 5-hour room, and puts the focus on its Switch button. Press Enter to switch. An account with 5 percent or less left, no reading, or a recent cap mark is never the best pick.
- **The toast.** When the live account passes 90 percent of its 5-hour or weekly window, a toast says so and points to `/accounts`. Each window alerts once on the machine, however many sessions run.
- **Switch.** The pane runs `claude-account switch <Name>`, then shows what it said. One switch runs at a time. Running sessions pick up the new login before their next request, with no restart.

Conversations are not tied to the login. They stay in `~/.claude/projects/`, so switching leaves every conversation in place.

## The CLI

```bash
claude-account usage            # how much is left on each, read without switching
claude-account switch work      # make work the live login
claude-account next             # rotate to the next slot
claude-account status           # slots, emails, the active one, cached usage
claude-account whoami           # which login is really live, and any API key override
```

| Command | What it does |
|---|---|
| `status` / `list` | Active slot, saved slots with their emails, cached usage, cap and unusable marks |
| `status --json` | The same facts for programs: percents used, epoch times, `null` where there is no value |
| `whoami` / `who` | Which slot and account is live; warns on drift, a blank token, or an `ANTHROPIC_*` override |
| `save <Name>` | Store the live login as a slot, and mark it active |
| `switch <Name>` / `use` | Make that slot the live login |
| `switch <Name> --from <Live>` | For scripts: switch only while `<Live>` is still live and nothing is pinned, else exit 3 |
| `next` / `swap` | Switch to the next slot in alphabetical order |
| `usage [--slot <Name>] [--quiet]` | Read the 5-hour and weekly limits per slot; refreshes the cache `status` reads |
| `pin` / `unpin` | Write or remove `~/.claude-accounts/pinned`, a hold flag for your own auto-rotation scripts |
| `history [N]` | The last N switches, pins and unpins, with the time (UTC) and who asked |

Marks: any script may touch an empty file at `~/.claude-accounts/capped/<Name>` or `unusable/<Name>`. `status` shows it, and `status --json` gives `held_until`: 30 minutes after a cap mark, 6 hours after an unusable mark. The mod never suggests a held slot.

Environment: `CLAUDE_ACCOUNTS_DIR` and `CLAUDE_CREDENTIALS` move the slot folder and the live login. `CLAUDE_ACCOUNT_LOCK_WAIT` sets how many seconds a switch waits for another one (default 30). `CLAUDE_ACCOUNT_CALLER` names the caller in `history`. `CLAUDE_ACCOUNT_BIN` makes the mod run another copy of the CLI.

Tab completion for bash or zsh: add `source ~/.local/share/claude-account/completion.sh` to your shell config.

## How it works

```
 /login in Claude Code --> ~/.claude/.credentials.json   (the live login)
                                   |  claude-account save work
                                   v
                        ~/.claude-accounts/work.json     (a saved slot)
                                   |
   /accounts pane (the mod) -------+--> claude-account status --json
   press "Switch to work" ---------+--> claude-account switch work
                                   v
            live login replaced --> running sessions reload it
```

Claude Code on Linux keeps its OAuth login in one file, `~/.claude/.credentials.json`, and refreshes the token in that file by itself. claude-account keeps copies of that file in `~/.claude-accounts/<Name>.json` and swaps which copy is live:

1. **Lock.** One switch or save runs at a time, across every session and shell (`flock`).
2. **Copy back.** The live token may have been refreshed since the last save, so it is copied back into the active slot first. A blank token is never copied back. When the live login belongs to another slot, or to an account no slot knows, the slot's own copy is kept in the backups first.
3. **Back up.** The live file goes to `~/.claude-accounts/backups/` (the last 10 are kept).
4. **Swap.** The chosen slot is written over the live file in one atomic step (temp file, then rename), mode 600.

Claude Code checks the date of the login file before each token use and reloads it when it changed, so running sessions follow the switch.

`usage` calls `https://api.anthropic.com/api/oauth/usage`, the endpoint Claude Code itself uses, with each slot's access token. Saved slots often carry an expired access token, because only a running session refreshes one. In that case the slot shows "no reading". claude-account never refreshes a token itself, because a refresh rotates the refresh token and would log out any other machine that uses the same copy.

The mod reads `claude-account status --json` for the pane and runs `claude-account switch` on a press. It runs the copy in this plugin's own `bin/` folder through `bash`. For the toast, it reads the live slot's name from `~/.claude-accounts/active` and claims each window once with an atomic `mkdir` under `~/.claude/state/account-picker-alerted/`.

## Security

- Slots are real OAuth tokens. `~/.claude-accounts` is mode 700 and every slot is mode 600. Never commit, sync or share that folder.
- The access token reaches `curl` on stdin, never as an argument, so it does not show in the process list.
- Slot names are limited to letters, digits, `-` and `_`, so a name can never point outside the folder.
- Nothing is sent anywhere except the Anthropic usage endpoint, and only by `usage`. The mod sends nothing itself.

See [SECURITY.md](SECURITY.md) to report a problem.

## Limitations

- **Linux only for now.** On macOS, Claude Code keeps its login in the Keychain, not in a file. On another system, `/accounts` says so in one line and offers no switch.
- **Mods are early access in Claude Code.** Function-hook plugins first came in Claude Code 2.1.287. This mod is tested on 2.1.312. The plugin API may change between releases.
- `usage` relies on an endpoint Claude Code uses internally. It is not a public API and may change.
- One login per slot. Two machines that share one slot's file will log each other out on refresh; log in separately on each machine.
- Running sessions follow a switch on Claude Code 2.x. An older version needs a restart (`claude --resume` keeps the conversation).

## Tests

```bash
bash tests/claude-account.test.sh   # the CLI, sandboxed: temp dir, fake logins, no network
claude plugin validate --strict .   # the plugin manifest, the marketplace file and the hooks module
claude plugin test .                # the mod, against Claude Code's own test kit
```

The demo GIF is made with [VHS](https://github.com/charmbracelet/vhs) from `demo/mod-demo.tape`, in a real Claude Code session with fake logins and a stub usage endpoint (`vhs demo/mod-demo.tape`).

MIT licensed. Built by Kwadwo Adu.
