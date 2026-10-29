# Contributing

Thanks for helping make claude-account better.

## Ground rules
- `bash tests/claude-account.test.sh` must pass before and after your change. It runs
  in a temp folder and never touches a real login or the network.
- For the mod, `claude plugin validate --strict .` and `claude plugin test .` must
  pass too. Neither needs a login.
- A fix comes with a test that fails without it.
- Keep it dependency-light: `bash`, `python3` and `curl` only.
- One focused change per PR; explain the *why* in the description.

## Re-rendering the demo
`assets/demo.gif` is made with [VHS](https://github.com/charmbracelet/vhs) from
`demo/mod-demo.tape`. It runs a real Claude Code session with this repo loaded as a
plugin, in a throwaway home with fake logins and a stub usage endpoint
(`demo/mod-setup.sh`). It needs vhs, ttyd, a Chromium and Claude Code on PATH:

```bash
vhs demo/mod-demo.tape
```

## Questions
Open an [issue](https://github.com/kwadwoadu/claude-account/issues) for bugs and ideas.
