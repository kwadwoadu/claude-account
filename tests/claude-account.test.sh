#!/usr/bin/env bash
# Failure-path tests for claude-account. Every case is built to exercise a way the
# tool could destroy or leak a Claude login. All fixtures live in a throwaway dir;
# the real ~/.claude-accounts, the live login and ~/.claude.json are never read or
# touched.
#
# Why slot validation matters: a stray .json in ~/.claude-accounts (a backup, an
# editor file) used to count as a slot. `next` could rotate into it and copy it
# over the live login, which logs the machine out. A credentials file is now
# recognised by its claudeAiOauth key, and save/switch refuse anything else.
set -uo pipefail

BIN="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/claude-account}"
[ -x "$BIN" ] || { echo "no executable claude-account at $BIN" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/slots"

# A minimally-shaped credentials file: what matters is the claudeAiOauth key.
CRED='{"claudeAiOauth":{"accessToken":"fake","refreshToken":"fake","scopes":[],"subscriptionType":"max"}}'
printf '%s' "$CRED" > "$TMP/slots/Alpha.json"
printf '%s' "$CRED" > "$TMP/slots/Beta.json"
printf '%s' "$CRED" > "$TMP/live.json"
printf '%s' '{"note":"stray backup"}' > "$TMP/slots/zz-stray.json"
echo Alpha > "$TMP/slots/active"

export CLAUDE_ACCOUNTS_DIR="$TMP/slots" CLAUDE_CREDENTIALS="$TMP/live.json"
# Sandboxed too: whoami and save read the account email from this file, and the
# real one would print the tester's own email into test and CI logs.
export CLAUDE_JSON="$TMP/claude.json"
printf '%s' '{"oauthAccount":{"emailAddress":"tester@example.com"}}' > "$CLAUDE_JSON"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL USAGE_FETCH_CMD
listing="$("$BIN" status 2>/dev/null)"

# 1 / 2 ---------------------------------------------------------------------
if grep -q "slot Alpha" <<<"$listing" && grep -q "slot Beta" <<<"$listing"; then
  ok "real credential copies are listed as slots"
else
  bad "real slots missing from status"; echo "$listing"
fi
if grep -q "zz-stray" <<<"$listing"; then
  bad "a stray .json is listed as a slot - it can become a rotation target"
else
  ok "stray .json is not listed as a slot"
fi

# 3 -------------------------------------------------------------------------
# Rotate more times than there are real slots; must never land on the stray.
landed_on_stray=no
for _ in 1 2 3 4 5 6; do
  "$BIN" next >/dev/null 2>&1 || true
  [ "$(cat "$TMP/slots/active")" = "zz-stray" ] && landed_on_stray=yes
done
if [ "$landed_on_stray" = no ]; then
  ok "next never rotates into a stray file"
else
  bad "next rotated into a stray file - it would clobber the live login"
fi

# 4 -------------------------------------------------------------------------
if "$BIN" switch zz-stray >/dev/null 2>&1; then
  bad "switch to a stray file succeeded - live credentials would be destroyed"
else
  ok "switch to a stray file is refused"
fi

# 5 -------------------------------------------------------------------------
if grep -q claudeAiOauth "$TMP/live.json"; then
  ok "live credentials survived every rotation and switch attempt"
else
  bad "live credentials were clobbered: $(cat "$TMP/live.json")"
fi

# 6 -------------------------------------------------------------------------
printf '%s' '{"not":"a login"}' > "$TMP/live.json"
if "$BIN" save Gamma >/dev/null 2>&1; then
  bad "save accepted a live file with no claudeAiOauth - a bad slot enters rotation"
else
  ok "save refuses a live file that is not a Claude login"
fi

# 7 / 8 / 9 -----------------------------------------------------------------
# whoami exists to answer "did that /login actually change accounts?", so its
# two warnings are the whole point: a live login that no longer matches the
# active pointer (the next `switch` would overwrite that slot), and a blanked
# token from a failed refresh.
TOKA='{"claudeAiOauth":{"accessToken":"tokA","refreshToken":"r","scopes":[],"subscriptionType":"max"}}'
TOKB='{"claudeAiOauth":{"accessToken":"tokB","refreshToken":"r","scopes":[],"subscriptionType":"max"}}'
printf '%s' "$TOKA" > "$TMP/slots/Alpha.json"
printf '%s' "$TOKB" > "$TMP/slots/Beta.json"
printf '%s' "$TOKB" > "$TMP/live.json"
echo Alpha > "$TMP/slots/active"
who="$("$BIN" whoami 2>&1)"
if grep -q "slot    : Beta" <<<"$who"; then
  ok "whoami names the slot the live token really belongs to"
else
  bad "whoami misidentified the live slot"; echo "$who"
fi
if grep -q "WARNING: active says 'Alpha'" <<<"$who"; then
  ok "whoami warns when the live login has drifted from the active pointer"
else
  bad "whoami stayed silent on live/active drift - a switch would clobber a slot"; echo "$who"
fi

printf '%s' '{"claudeAiOauth":{"accessToken":"","refreshToken":"","scopes":[]}}' > "$TMP/live.json"
if "$BIN" whoami 2>&1 | grep -q "accessToken is EMPTY"; then
  ok "whoami flags a blanked token from a failed refresh"
else
  bad "whoami did not flag an empty accessToken"
fi

# 10 ------------------------------------------------------------------------
# The override check: an API key in the environment silently outranks the
# subscription login, so whoami must say so.
printf '%s' "$TOKB" > "$TMP/live.json"
if ANTHROPIC_API_KEY=sk-fake "$BIN" whoami 2>&1 | grep -q "OVERRIDE the login above: ANTHROPIC_API_KEY"; then
  ok "whoami warns when an API key in the environment outranks the login"
else
  bad "whoami ignored ANTHROPIC_API_KEY - the account it reports is not the one billed"
fi

# 11 ------------------------------------------------------------------------
# A slot name is a path part, so switch must refuse anything that leaves $DIR.
printf '%s' "$CRED" > "$TMP/outside.json"
if "$BIN" switch ../outside >/dev/null 2>&1; then
  bad "switch accepted ../outside - later syncs would write tokens outside the slots dir"
else
  ok "switch refuses a slot name with a path in it"
fi
echo "../outside" > "$TMP/slots/active"
case "$("$BIN" status 2>&1)" in
  *"active slot: unknown"*) ok "a path in the active file is treated as unknown" ;;
  *) bad "the active file was trusted as a path" ;;
esac

# 12 ------------------------------------------------------------------------
# A failed refresh blanks the live token. Copying that back would destroy the
# good saved copy of the active slot.
printf '%s' "$TOKA" > "$TMP/slots/Alpha.json"
printf '%s' "$TOKB" > "$TMP/slots/Beta.json"
echo Alpha > "$TMP/slots/active"
printf '%s' '{"claudeAiOauth":{"accessToken":"","refreshToken":""}}' > "$TMP/live.json"
"$BIN" switch Beta >/dev/null 2>&1
if grep -q tokA "$TMP/slots/Alpha.json"; then
  ok "a blank live token is not copied back over its slot"
else
  bad "switch saved a blank live token over slot Alpha: $(cat "$TMP/slots/Alpha.json")"
fi

# 13 ------------------------------------------------------------------------
# A live login that was never saved must survive a switch: it goes to backups/.
printf '%s' '{"claudeAiOauth":{"accessToken":"tokUNSAVED","refreshToken":"r"}}' > "$TMP/live.json"
rm -f "$TMP/slots/active"
"$BIN" switch Alpha >/dev/null 2>&1
if grep -lq tokUNSAVED "$TMP/slots/backups/"*.json 2>/dev/null; then
  ok "switch backs up an unsaved live login"
else
  bad "switch lost an unsaved live login"
fi
case "$("$BIN" status 2>&1)" in
  *"slot live-"*) bad "a backup is listed as a slot" ;;
  *) ok "backups are not listed as slots" ;;
esac
mode=$(stat -c %a "$TMP/live.json" 2>/dev/null || stat -f %Lp "$TMP/live.json")
if [ "$mode" = 600 ]; then
  ok "the live login is mode 600 after a switch"
else
  bad "the live login is mode $mode after a switch"
fi

# 14 ------------------------------------------------------------------------
# whoami must never tie the profile email to a slot. Claude Code's profile file names
# the account of the last /login and does not change on a switch, so after
# "save Alpha (a@), save Beta (b@), switch Alpha" the profile still says b@.
printf '%s' '{"oauthAccount":{"emailAddress":"a@example.com"}}' > "$CLAUDE_JSON"
printf '%s' "$TOKA" > "$TMP/live.json"; "$BIN" save Alpha >/dev/null
printf '%s' '{"oauthAccount":{"emailAddress":"b@example.com"}}' > "$CLAUDE_JSON"
printf '%s' "$TOKB" > "$TMP/live.json"; "$BIN" save Beta >/dev/null
"$BIN" switch Alpha >/dev/null
who="$("$BIN" whoami 2>&1)"
case "$who" in
  *"slot    : Alpha"*"b@example.com (from the last /login"*) ok "whoami names the live slot and labels the profile email" ;;
  *) bad "whoami tied an email to the slot or lost the slot after a switch: $who" ;;
esac
# A token refresh and a new /login look the same on disk, so a fingerprint that
# matches no slot must not be reported as the active slot.
printf '%s' '{"claudeAiOauth":{"accessToken":"tokA2","refreshToken":"r2"}}' > "$TMP/live.json"
who="$("$BIN" whoami 2>&1)"
case "$who" in
  *"slot    : Alpha"*) bad "whoami guessed the active slot for an unmatched token: $who" ;;
  *"no slot matches"*) ok "whoami does not guess a slot for an unmatched token" ;;
  *) bad "whoami gave no slot line for an unmatched token: $who" ;;
esac

# 15 ------------------------------------------------------------------------
# The access token must never be a process argument: every local user can read
# arguments in the process list. A fake curl records what it was given.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" > "$TMP/curl.argv"
cat > "$TMP/curl.stdin"
printf '{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}'
EOF
chmod +x "$TMP/bin/curl"
printf '%s' "$TOKA" > "$TMP/live.json"; echo Alpha > "$TMP/slots/active"
PATH="$TMP/bin:$PATH" "$BIN" usage --slot Alpha >/dev/null 2>&1
if grep -q tokA "$TMP/curl.argv" 2>/dev/null; then
  bad "the access token was passed to curl as an argument"
elif grep -q "Authorization: Bearer tokA" "$TMP/curl.stdin" 2>/dev/null; then
  ok "the access token reaches curl on stdin, not in its arguments"
else
  bad "curl never got the token (argv: $(cat "$TMP/curl.argv" 2>/dev/null))"
fi
out="$("$BIN" usage --slot 2>&1)"; rc=$?
if [ $rc -ne 0 ] && grep -q "usage: claude-account usage" <<<"$out"; then
  ok "usage --slot without a name prints usage"
else
  bad "usage --slot without a name ended silently (rc $rc)"
fi

# ---------------------------------------------------------------------------
# usage: how much of each subscription is left
#
# No network. USAGE_FETCH_CMD replaces the HTTP call, so these cases test the
# parse, the cache, the TTL and the rendering, which is everything that can be
# wrong on the read path. utilization is a percent USED; the display shows left.
# ---------------------------------------------------------------------------
# Never `"$BIN" status | grep -q`: grep -q exits on the first match, status dies on
# SIGPIPE, and the pipeline returns 141 while the text was right there. Capture,
# then match.
FETCH="$TMP/fetch.sh"
cat > "$FETCH" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
# The token arrives on stdin. Answers like the endpoint: 92% of the 5h window
# used, 33% of the weekly one.
case "${FAKE_BODY:-good}" in
  good) printf '{"five_hour":{"utilization":92.0,"resets_at":"2026-10-05T14:40:00+00:00"},"seven_day":{"utilization":33.0,"resets_at":"2026-10-07T06:59:59+00:00"}}' ;;
  html) printf '<html>401 Unauthorized</html>' ;;
  nulls) printf '{"five_hour":{"utilization":null},"seven_day":{"utilization":null}}' ;;
esac
STUB
chmod +x "$FETCH"
export USAGE_FETCH_CMD="$FETCH"

echo Alpha > "$TMP/slots/active"
rm -f "$TMP/slots/usage.cache"

out="$("$BIN" usage --slot Alpha 2>&1)"
case "$out" in
  *"5h 8% left"*) ok "usage turns 92% used into 8% left" ;;
  *) bad "usage did not report 8% left (got: $out)" ;;
esac
case "$out" in
  *"7d 67% left"*) ok "usage reports the weekly window too" ;;
  *) bad "usage did not report the weekly window (got: $out)" ;;
esac
if [ -f "$TMP/slots/usage.cache" ]; then
  ok "usage writes the cache"
else
  bad "usage wrote no cache"
fi

# status reads that cache and never calls the fetcher
st="$("$BIN" status 2>&1)"
case "$st" in
  *"5h 8% left"*) ok "status shows the cached reading" ;;
  *) bad "status did not show the cached reading (got: $st)" ;;
esac

# a reading older than the TTL must not appear: a stale number on the prompt is
# worse than no number, because it reads as current
python3 - "$TMP/slots/usage.cache" <<'AGE'
import sys,time
p=sys.argv[1]
rows=[r.split('|') for r in open(p).read().strip().split('\n') if r]
for r in rows: r[-1]=str(int(time.time())-7200)   # 2 hours ago
open(p,'w').write('\n'.join('|'.join(r) for r in rows)+'\n')
AGE
st="$("$BIN" status 2>&1)"
case "$st" in
  *"5h "*) bad "status showed a reading older than the TTL (got: $st)" ;;
  *) ok "status ignores a reading older than the TTL" ;;
esac

# an unparseable body leaves no cache line and says so
rm -f "$TMP/slots/usage.cache"
out="$(FAKE_BODY=html "$BIN" usage --slot Alpha 2>&1)"
case "$out" in
  *"no reading"*) ok "a non-JSON body reports no reading" ;;
  *) bad "a non-JSON body was not reported (got: $out)" ;;
esac
if [ -f "$TMP/slots/usage.cache" ]; then
  bad "a non-JSON body still wrote a cache line"
else
  ok "a non-JSON body writes no cache line"
fi

# the shape can be right with both numbers absent; that is still no reading
out="$(FAKE_BODY=nulls "$BIN" usage --slot Alpha 2>&1)"
case "$out" in
  *"no reading"*) ok "null utilizations report no reading" ;;
  *) bad "null utilizations were not reported (got: $out)" ;;
esac

# --quiet refreshes the cache and prints nothing
rm -f "$TMP/slots/usage.cache"
out="$("$BIN" usage --slot Alpha --quiet 2>&1)"
if [ -z "$out" ] && [ -f "$TMP/slots/usage.cache" ]; then
  ok "--quiet refreshes the cache silently"
else
  bad "--quiet printed output or wrote no cache (got: $out)"
fi
# a fetcher that cannot run must report, not end the command silently: this script
# runs under set -e, so an unguarded failing fetch printed nothing at all
export USAGE_FETCH_CMD="$TMP/does-not-exist"
out="$("$BIN" usage --slot Alpha 2>&1)"
case "$out" in
  *"no reading"*) ok "a broken fetcher still reports no reading" ;;
  *) bad "a broken fetcher printed nothing (got: $out)" ;;
esac
unset USAGE_FETCH_CMD

# ---------------------------------------------------------------------------
# mutation: take the TTL check out of cache_line and the stale-cache assertion
# above must go red. A stale percentage on the prompt reads as current, which is
# the whole reason that check exists, so it must be proven able to fail.
# ---------------------------------------------------------------------------
MUT="$TMP/claude-account-mutated"
# shellcheck disable=SC2016  # the pattern is literal script text
sed 's#^  (( $(date +%s) - fetched < USAGE_TTL )) || return 0$#  true#' "$BIN" > "$MUT"
chmod +x "$MUT"
if cmp -s "$BIN" "$MUT"; then
  bad "mutation did not change the script (the sed no longer matches)"
else
  printf 'Alpha|92|1791290400|33|1791392399|%s\n' "$(( $(date +%s) - 7200 ))" \
    > "$TMP/slots/usage.cache"
  st="$("$MUT" status 2>&1)"
  case "$st" in
    *"5h 8% left"*) ok "mutation caught: without the TTL check, a 2h-old reading shows" ;;
    *) bad "mutation NOT caught: the stale-cache assertion cannot fail" ;;
  esac
  rm -f "$TMP/slots/usage.cache"
fi

echo
echo "== $FAIL failed, $PASS passed =="
[ "$FAIL" -eq 0 ]
