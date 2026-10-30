# shellcheck shell=bash
# Sourced by demo/mod-demo.tape from the repo root. Builds a throwaway home with
# two fake logins (work and personal), so the demo never touches a real login or
# the usage endpoint. Claude Code itself runs for real, with this plugin loaded
# from the repo folder. Everything lives under $DEMO.
REPO="$PWD"
DEMO="$(mktemp -d /tmp/claude-account-demo.XXXXXX)"
export HOME="$DEMO/home"
export USAGE_FETCH_CMD="$REPO/demo/fake-usage"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 TZ=UTC
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_ACCOUNTS_DIR \
  CLAUDE_CREDENTIALS CLAUDE_JSON CLAUDE_ACCOUNT_BIN CLAUDE_CODE_PLUGIN_DIRS CLAUDE_CONFIG_DIR
# A session that runs this inside Claude Code passes on its own CLAUDE_CODE_*
# markers, which show as warnings in the demo. Clear them all.
while read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(CLAUDE_CODE_|CLAUDECODE)')
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
mkdir -p "$HOME/.claude" "$HOME/project"

# Stands in for "/login inside Claude Code": a clearly fake login for <name>,
# valid until 2100, so Claude Code does not try to renew it.
fake_login() {
  printf '{"claudeAiOauth":{"accessToken":"demo-%s","refreshToken":"demo-%s-refresh","expiresAt":4102444800000,"scopes":["user:inference","user:profile"],"subscriptionType":"max"}}' \
    "$1" "$1" > "$HOME/.claude/.credentials.json"
  chmod 600 "$HOME/.claude/.credentials.json"
  # Onboarding done and the demo folder trusted, so Claude Code opens straight
  # on its prompt.
  printf '{"hasCompletedOnboarding":true,"lastReleaseNotesSeen":"9.9.9","hasSeenAutoModeEntryWarning":true,"hasResetAutoModeOptInForDefaultOffer":true,"seenNotifications":{"auto-mode-default":9},"tipsHistory":{"auto-mode-default":9},"theme":"dark","oauthAccount":{"emailAddress":"%s@example.com","organizationName":"Demo"},"projects":{"%s":{"hasTrustDialogAccepted":true,"hasCompletedProjectOnboarding":true}}}' \
    "$1" "$HOME/project" > "$HOME/.claude.json"
}
fake_login personal && bash "$REPO/bin/claude-account" save personal >/dev/null
fake_login work && bash "$REPO/bin/claude-account" save work >/dev/null

cd "$HOME/project" || return
export PS1='$ '
