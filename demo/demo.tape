# claude-account demo -> assets/demo.gif. Offline and deterministic: fake logins,
# a stub usage endpoint, everything in a temp dir (see demo/setup.sh).
# Render from the repo root:  vhs demo/demo.tape

Output assets/demo.gif

Set Shell "bash"
Set FontSize 18
Set Width 1440
Set Height 700
Set Padding 24
Set TypingSpeed 35ms
Set Theme "Dracula"

Hide
Type "source demo/setup.sh && clear"
Enter
Show

Type "# Two Claude subscriptions on one machine. Log in to the first, save it:"
Enter
Sleep 800ms
Hide
Type "fake_login work"
Enter
Show
Type "# (after /login as work@example.com inside Claude Code)"
Enter
Type "claude-account save work"
Enter
Sleep 1500ms

Type "# Log in to the second one, save it too:"
Enter
Hide
Type "fake_login personal"
Enter
Show
Type "claude-account save personal"
Enter
Sleep 1500ms

Type "# How much is left on each, read without switching:"
Enter
Type "claude-account usage"
Enter
Sleep 3000ms

Type "# work hits its limit? Switch. Running sessions follow, no restart:"
Enter
Type "claude-account switch personal"
Enter
Sleep 2000ms

Type "# Or just rotate to the next one:"
Enter
Type "claude-account next"
Enter
Sleep 2000ms

Type "claude-account status"
Enter
Sleep 4000ms
