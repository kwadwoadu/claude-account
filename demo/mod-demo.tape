# The account-picker mod in a real Claude Code session -> assets/demo.gif.
# Offline and repeatable: two fake logins, a stub usage endpoint, a throwaway
# home (see demo/mod-setup.sh). Claude Code runs with this repo loaded as a
# plugin. Needs vhs, ttyd, a Chromium and Claude Code on PATH.
# Render from the repo root:  vhs demo/mod-demo.tape

Output assets/demo.gif

Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 880
Set Padding 20
Set TypingSpeed 60ms
Set Theme "Dracula"

Hide
Type "source demo/mod-setup.sh && clear"
Enter
Type `claude --plugin-dir "$REPO"`
Enter
Sleep 8s
Show

Sleep 1s
Type "/accounts"
Sleep 800ms
Enter
Sleep 4s

# The best pick has the focus: Enter switches to it.
Enter
Sleep 5s

Escape
Sleep 2s
