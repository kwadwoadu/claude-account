# Sourced by demo.tape. Builds a throwaway sandbox so the demo never touches a
# real login or the network. Everything lives under $DEMO.
DEMO="$(mktemp -d)"
export CLAUDE_ACCOUNTS_DIR="$DEMO/accounts"
export CLAUDE_CREDENTIALS="$DEMO/claude/credentials.json"
export CLAUDE_JSON="$DEMO/claude.json"
export USAGE_FETCH_CMD="$PWD/demo/fake-usage"
export PATH="$PWD/bin:$PATH"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
mkdir -p "$DEMO/claude"

# Stands in for "/login inside Claude Code": writes a fake login for <name>.
fake_login() {
  printf '{"claudeAiOauth":{"accessToken":"demo-%s","refreshToken":"r","subscriptionType":"max"}}' "$1" > "$CLAUDE_CREDENTIALS"
  printf '{"oauthAccount":{"emailAddress":"%s@example.com"},"organizationRateLimitTier":"default_claude_max_20x"}' "$1" > "$CLAUDE_JSON"
  printf '\e[1A\e[2K\r'   # erase the hidden command line from the screen
}
export PS1='\[\e[1;35m\]$ \[\e[0m\]'
