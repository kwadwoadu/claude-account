# Security

claude-account runs entirely on your machine. There is no server and no telemetry.
It needs `bash`, `python3` and `curl`.

## What it touches
- It copies Claude Code's login file (`~/.claude/.credentials.json`) into
  `~/.claude-accounts/`. Those copies hold real OAuth tokens. The folder is mode
  700 and every copy is mode 600. Treat the folder like a password store: never
  commit it, sync it or share it.
- Before each switch, the live login is backed up to `~/.claude-accounts/backups/`
  (the last 10 are kept).
- `usage` sends each slot's access token to `https://api.anthropic.com/api/oauth/usage`,
  the same endpoint Claude Code calls. The token goes to `curl` on stdin, so it never
  shows in the process list. Nothing is sent anywhere else.
- It never refreshes a token itself. A refresh rotates the refresh token and logs
  out any other machine that uses the same copy.

## Reporting a vulnerability
Please report security issues privately via GitHub's
[Report a vulnerability](https://github.com/kwadwoadu/claude-account/security/advisories/new)
on the Security tab. Do not open a public issue for sensitive reports.
