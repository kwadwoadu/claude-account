#!/usr/bin/env bash
# Failure-path tests for claude-account. Every case is built to exercise a way the
# tool could destroy or leak a Claude login. All fixtures live in a throwaway dir;
# the real ~/.claude-accounts, the live login and ~/.claude.json are never read or
# touched.
#
#   1-6   a stray .json is never a slot: not listed, not rotated into, not
#         switched to, not saved; the live login survives all of it
#   7-10  whoami: drift from the active pointer, a blank token, an API key override
#   11-13 save keeps the account email; status and switch name it
#   14-18 slot names are checked as paths, a blank live token is never copied
#         back, switch backs up the live login, whoami names no slot it cannot
#         prove, the token never reaches curl as an argument
#   then  usage and its cache, status --json, history, drift, --from, the lock,
#         and a copy that lost its exec bit
#
# Why slot validation matters: a stray .json in ~/.claude-accounts (a backup, an
# editor file) used to count as a slot. `next` could rotate into it and copy it
# over the live login, which logs the machine out. A rotation script that runs on
# its own would do that with no one watching. A credentials file is now
# recognised by its claudeAiOauth key, and save/switch refuse anything else.
set -uo pipefail

BIN="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/claude-account}"
[ -x "$BIN" ] || { echo "no executable claude-account at $BIN" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)" || { echo "FATAL: mktemp -d failed; refusing to run with an empty temp path" >&2; kill -s TERM $$; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "$TMP/slots"

# A minimally-shaped credentials file: what matters is the claudeAiOauth key.
CRED='{"claudeAiOauth":{"accessToken":"fake","refreshToken":"fake","scopes":[],"subscriptionType":"max"}}'
printf '%s' "$CRED" > "$TMP/slots/Alpha.json"
printf '%s' "$CRED" > "$TMP/slots/Beta.json"
printf '%s' "$CRED" > "$TMP/live.json"
printf '%s' '{"note":"stray backup"}' > "$TMP/slots/zz-stray.json"
echo Alpha > "$TMP/slots/active"

export CLAUDE_ACCOUNTS_DIR="$TMP/slots" CLAUDE_CREDENTIALS="$TMP/live.json"
unset CLAUDE_ACCOUNT_CALLER CLAUDE_ACCOUNT_LOCK_WAIT
# Sandboxed too: whoami and save read the account email from this file, and the
# real one would print the tester's own email into test and CI logs.
export CLAUDE_JSON="$TMP/claude.json"
printf '%s' '{"oauthAccount":{"emailAddress":"tester@example.com"}}' > "$CLAUDE_JSON"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL USAGE_FETCH_CMD
# Start a process that holds lock file $1 for $2 seconds, and wait until it really
# holds it: a fixed sleep lets a slow runner reach the code under test first.
hold_lock() {
  flock "$1" sleep "$2" &
  holder=$!
  for _ in $(seq 50); do flock -n "$1" true 2>/dev/null || return 0; sleep 0.1; done
  echo "  (the lock holder never took $1)"
}
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
who="$("$BIN" whoami 2>&1)"   # capture, then match: grep -q on a pipe races with SIGPIPE
if grep -q "accessToken is EMPTY" <<<"$who"; then
  ok "whoami flags a blanked token from a failed refresh"
else
  bad "whoami did not flag an empty accessToken"
fi

# 10 ------------------------------------------------------------------------
# The override check: an API key in the environment silently outranks the
# subscription login, so whoami must say so.
printf '%s' "$TOKB" > "$TMP/live.json"
who="$(ANTHROPIC_API_KEY=sk-fake "$BIN" whoami 2>&1)"
if grep -q "OVERRIDE the login above: ANTHROPIC_API_KEY" <<<"$who"; then
  ok "whoami warns when an API key in the environment outranks the login"
else
  bad "whoami ignored ANTHROPIC_API_KEY - the account it reports is not the one billed"
fi
who="$(env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL "$BIN" whoami 2>&1)"
if grep -q "no ANTHROPIC_\* override" <<<"$who"; then
  ok "whoami confirms a clean environment when no override is set"
else
  bad "whoami did not confirm a clean environment"
fi

# 11 / 12 / 13 --------------------------------------------------------------
# save keeps the account email of the last /login next to the slot, and status
# and switch name it. A switch says running sessions follow, and takes no
# option it does not know.
printf '%s' "$TOKA" > "$TMP/live.json"
printf '%s' '{"oauthAccount":{"emailAddress":"alpha@example.com"}}' > "$CLAUDE_JSON"
out=$("$BIN" save Alpha 2>&1)
case "$out" in *"(alpha@example.com) as slot Alpha"*) ok "save names the account it saved" ;; *) bad "save named no account: $out" ;; esac
printf '%s' "$TOKB" > "$TMP/live.json"
printf '%s' '{"oauthAccount":{"emailAddress":"beta@example.com"}}' > "$CLAUDE_JSON"
"$BIN" save Beta >/dev/null 2>&1
case "$("$BIN" status 2>&1)" in
  *"slot Alpha <alpha@example.com>"*"slot Beta <beta@example.com>"*) ok "status shows each slot's account email" ;;
  *) bad "status did not show the slot emails: $("$BIN" status 2>&1)" ;;
esac
out=$("$BIN" switch Alpha 2>&1)
case "$out" in
  *"switched to slot Alpha (alpha@example.com)"*"running sessions move to Alpha before their next request"*)
    ok "switch names the account and says running sessions follow" ;;
  *) bad "switch message is wrong: $out" ;;
esac
if "$BIN" switch Beta --bogus >/dev/null 2>&1; then
  bad "switch accepted an option it does not know"
else
  ok "switch refuses an unknown option"
fi
printf '%s' '{"oauthAccount":{"emailAddress":"tester@example.com"}}' > "$CLAUDE_JSON"
rm -f "$TMP/slots/Alpha.email" "$TMP/slots/Beta.email"

# 14 ------------------------------------------------------------------------
# A slot name is a path part, so switch must refuse anything that leaves $DIR,
# and the active file is checked the same way.
printf '%s' "$CRED" > "$TMP/outside.json"
if "$BIN" switch ../outside >/dev/null 2>&1; then
  bad "switch accepted ../outside - later syncs would write tokens outside the slots dir"
else
  ok "switch refuses a slot name with a path in it"
fi
if "$BIN" save backups >/dev/null 2>&1; then
  bad "save accepted the name 'backups' - it is the backup folder"
else
  ok "save refuses the reserved name 'backups'"
fi
echo "../outside" > "$TMP/slots/active"
case "$("$BIN" status 2>&1)" in
  *"active slot: unknown"*) ok "a path in the active file is treated as unknown" ;;
  *) bad "the active file was trusted as a path" ;;
esac

# 15 ------------------------------------------------------------------------
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

# 16 ------------------------------------------------------------------------
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
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do "$BIN" switch Beta >/dev/null 2>&1; "$BIN" switch Alpha >/dev/null 2>&1; done
# An accounts folder that already exists with mode 755 (made by hand, or copied in)
# holds plaintext logins: any run must tighten it to 700.
mkdir -p "$TMP/perm" && chmod 755 "$TMP/perm" && printf '%s' "$CRED" > "$TMP/perm/Zed.json" && chmod 644 "$TMP/perm/Zed.json"
CLAUDE_ACCOUNTS_DIR="$TMP/perm" "$BIN" status >/dev/null 2>&1
pmode=$(stat -c %a "$TMP/perm" 2>/dev/null || stat -f %Lp "$TMP/perm")
if [ "$pmode" = 700 ]; then
  ok "an existing accounts folder with mode 755 is tightened to 700"
else
  bad "an existing accounts folder stayed mode $pmode"
fi
nbak=$(find "$TMP/slots/backups" -name 'live-*.json' | wc -l)
if [ "$nbak" -eq 10 ]; then
  ok "only the last 10 backups are kept"
else
  bad "expected 10 backups, found $nbak"
fi

# 17 ------------------------------------------------------------------------
# whoami names a slot only when its saved token matches the live one. Claude Code's
# profile file (CLAUDE_JSON) names the account of the LAST /login and does not
# change on a switch, so its email is shown on its own line, labelled, and is never
# tied to a slot. When no slot matches, no slot is guessed: a refreshed token and a
# new /login look the same on disk.
printf '%s' '{"oauthAccount":{"emailAddress":"b@example.com"}}' > "$CLAUDE_JSON"
printf '%s' "$TOKA" > "$TMP/slots/Alpha.json"
printf '%s' "$TOKB" > "$TMP/slots/Beta.json"
printf '%s' "$TOKA" > "$TMP/live.json"; echo Alpha > "$TMP/slots/active"
who="$("$BIN" whoami 2>&1)"
case "$who" in
  *"slot    : Alpha"*"account : b@example.com (from the last /login)"*)
    ok "whoami names the matched slot and labels the profile email as the last /login" ;;
  *) bad "whoami matched-slot output is wrong: $who" ;;
esac
printf '%s' '{"claudeAiOauth":{"accessToken":"tokA2","refreshToken":"r2"}}' > "$TMP/live.json"
who="$("$BIN" whoami 2>&1)"
case "$who" in
  *"slot    : (no slot matches; token refreshed or a new /login, run save)"*) ok "whoami guesses no slot when none matches" ;;
  *) bad "whoami did not say that no slot matches: $who" ;;
esac
case "$who" in
  *"slot    : Alpha"*|*"slot    : Beta"*) bad "whoami guessed a slot for a token no slot holds: $who" ;;
  *) ok "whoami does not fall back to the active slot on a mismatch" ;;
esac
case "$who" in
  *"keeps the token it STARTED with"*) bad "whoami still says running sessions keep their old token" ;;
  *) ok "whoami note matches switch: running sessions reload the login" ;;
esac
# No profile file: say so, name no account.
mv "$CLAUDE_JSON" "$CLAUDE_JSON.off"
case "$("$BIN" whoami 2>&1)" in
  *"account : (unknown;"*) ok "whoami reports an unknown account when the profile file is missing" ;;
  *) bad "whoami invented an account without a profile file" ;;
esac
mv "$CLAUDE_JSON.off" "$CLAUDE_JSON"

# 18 ------------------------------------------------------------------------
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
cmode=$(stat -c %a "$TMP/slots/usage.cache" 2>/dev/null || stat -f %Lp "$TMP/slots/usage.cache")
if [ "$cmode" = 600 ]; then
  ok "the usage cache is mode 600"
else
  bad "the usage cache is mode $cmode"
fi

# ---------------------------------------------------------------------------
# usage: how much of each subscription is left
#
# No network. USAGE_FETCH_CMD replaces the HTTP call, so these cases test the
# parse, the cache, the TTL and the rendering, which is everything that can be
# wrong on the read path. utilization is a percent USED; the display shows left.
# ---------------------------------------------------------------------------
# Never `"$BIN" status | grep -q`: grep -q exits on the first match, status dies on
# SIGPIPE, and the pipeline returns 141 while the text was right there. That cost a
# false FAIL while this block was being written. Capture, then match.
FETCH="$TMP/fetch.sh"
cat > "$FETCH" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
# The token arrives on stdin. Answers like the endpoint: 92% of the 5h window
# used, 33% weekly.
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

# The cache is read, changed and replaced under one lock: while another run holds
# it, usage waits and then writes nothing, rather than drop that run's line.
if command -v flock >/dev/null 2>&1; then
  rm -f "$TMP/slots/usage.cache"
  hold_lock "$TMP/slots/usage.lock" 3
  out="$(CLAUDE_ACCOUNT_LOCK_WAIT=1 "$BIN" usage --slot Alpha --quiet 2>&1 >/dev/null)"
  if ! grep -qs '^Alpha|' "$TMP/slots/usage.cache" && grep -q 'usage cache is locked by another run' <<<"$out"; then
    ok "usage writes no cache line while another run holds the lock, and says why"
  else
    bad "usage wrote the cache while another run held its lock, or gave no lock message (got: $out)"
  fi
  wait "$holder"
  "$BIN" usage --slot Alpha --quiet >/dev/null 2>&1
  if grep -qs '^Alpha|' "$TMP/slots/usage.cache"; then ok "usage writes the cache once the lock is free"; else bad "usage wrote nothing with the lock free"; fi
fi

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

# status --json carries the same facts raw, for the account-picker mod: percents
# USED and epochs, null with no fresh reading, and valid JSON with every slot.
printf 'Alpha|92|1791290400|33|1791392399|%s\n' "$(date +%s)" > "$TMP/slots/usage.cache"
touch "$TMP/slots/capped/Beta" 2>/dev/null || { mkdir -p "$TMP/slots/capped"; touch "$TMP/slots/capped/Beta"; }
js="$("$BIN" status --json 2>&1)"
if python3 -c '
import json,sys
d=json.loads(sys.argv[1]); s={x["name"]:x for x in d["slots"]}
assert d["active"]=="Alpha", d
assert set(s)=={"Alpha","Beta"}, s
a,b=s["Alpha"],s["Beta"]
assert a["active"] is True and b["active"] is False
assert (a["five_hour_used"],a["five_hour_resets_at"],a["week_used"],a["week_resets_at"])==(92,1791290400,33,1791392399), a
assert b["five_hour_used"] is None and isinstance(b["capped_at"],int) and a["capped_at"] is None, b
' "$js" 2>/dev/null; then
  ok "status --json gives raw used percents, epochs and cap times"
else
  bad "status --json is wrong or not JSON (got: $js)"
fi
rm -f "$TMP/slots/capped/Beta"
# A credential file whose name `switch` refuses (here a quote) is left out, so the JSON stays valid.
printf '%s' "$CRED" > "$TMP/slots/Bad\"Name.json"
js="$("$BIN" status --json 2>&1)"
if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert [x["name"] for x in d["slots"]] == ["Alpha", "Beta"], d' "$js" 2>/dev/null; then
  ok "status --json leaves out a slot name switch would refuse and stays valid JSON"
else
  bad "status --json broke on a slot name with a quote (got: $js)"
fi
rm -f "$TMP/slots/Bad\"Name.json"
# The JSON must hold the stale-cache rule too: a 2h-old reading is null, not a number.
printf 'Alpha|92|1791290400|33|1791392399|%s\n' "$(( $(date +%s) - 7200 ))" > "$TMP/slots/usage.cache"
js="$("$BIN" status --json 2>&1)"
case "$js" in
  *'"five_hour_used":92'*) bad "status --json showed a reading older than the TTL" ;;
  *'"five_hour_used":null'*) ok "status --json ignores a reading older than the TTL" ;;
  *) bad "status --json printed no usage field (got: $js)" ;;
esac

# pinned, unusable_at and held_until: a pin names its slot; a fresh cap holds a slot
# for CAP_TTL, a fresh unusable mark for UNUSABLE_TTL, an old cap holds nothing.
# No pin and no live slot print null, never "unknown".
mkdir -p "$TMP/slots/capped" "$TMP/slots/unusable"
echo Alpha > "$TMP/slots/pinned"
touch "$TMP/slots/unusable/Beta"; touch -d '2 hours ago' "$TMP/slots/capped/Alpha"
js="$("$BIN" status --json 2>&1)"
if python3 -c '
import json,sys,time
d=json.loads(sys.argv[1]); s={x["name"]:x for x in d["slots"]}; now=time.time()
assert d["pinned"]=="Alpha" and s["Alpha"]["pinned"] is True and s["Beta"]["pinned"] is False, d
assert isinstance(s["Beta"]["unusable_at"],int), s
assert abs(s["Beta"]["held_until"]-(s["Beta"]["unusable_at"]+21600))<=1, s
assert isinstance(s["Alpha"]["capped_at"],int) and s["Alpha"]["held_until"] is None, s
' "$js" 2>/dev/null; then
  ok "status --json gives the pin, the unusable time and when each hold ends"
else
  bad "status --json pin or hold fields are wrong (got: $js)"
fi
touch "$TMP/slots/capped/Alpha"
js="$("$BIN" status --json 2>&1)"
if python3 -c 'import json,sys,time; d=json.loads(sys.argv[1]); a=[x for x in d["slots"] if x["name"]=="Alpha"][0]; assert abs(a["held_until"]-(a["capped_at"]+1800))<=1, a' "$js" 2>/dev/null; then
  ok "status --json holds a freshly capped slot for CAP_TTL"
else
  bad "status --json did not hold a fresh cap (got: $js)"
fi
rm -f "$TMP/slots/pinned" "$TMP/slots/capped/Alpha" "$TMP/slots/unusable/Beta"
rm -f "$TMP/slots/active"
js="$("$BIN" status --json 2>&1)"
if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["active"] is None and d["pinned"] is None, d' "$js" 2>/dev/null; then
  ok "status --json prints null with no live slot and no pin"
else
  bad "status --json named a live slot or pin that does not exist (got: $js)"
fi
echo Alpha > "$TMP/slots/active"
# "unknown" is what active() prints for no slot, so it can never be a slot's name.
if out="$("$BIN" save unknown 2>&1)"; then bad "save accepted the reserved name unknown"
else ok "save refuses the reserved name unknown ($out)"; fi

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

# every switch, pin and unpin leaves one line naming who asked, and history reads it
rm -f "$TMP/slots/switch.log" "$TMP/slots/pinned"; echo Alpha > "$TMP/slots/active"
CLAUDE_ACCOUNT_CALLER=account-picker "$BIN" switch Beta >/dev/null 2>&1
"$BIN" pin >/dev/null 2>&1
"$BIN" switch Alpha >/dev/null 2>&1
"$BIN" unpin >/dev/null 2>&1
hist="$("$BIN" history 2>&1)"
want=$'switch Alpha -> Beta by=account-picker\npin Beta by=bash\nswitch Beta -> Alpha (pin moved) by=bash\nunpin Alpha by=bash'
got="$(cut -d' ' -f2- <<<"$hist")"
if [ "$got" = "$want" ]; then ok "history shows each switch, pin and unpin with its caller"
else bad "history is wrong (got: $got)"; fi
if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z ' <<<"$hist"; then ok "history lines start with a UTC time"
else bad "history lines carry no UTC time (got: $hist)"; fi
check_n="$("$BIN" history 1 2>&1)"
if [ "$(cut -d' ' -f2- <<<"$check_n")" = "unpin Alpha by=bash" ]; then ok "history N prints the last N lines"
else bad "history 1 printed: $check_n"; fi
CLAUDE_ACCOUNT_CALLER=$'-zsh\nfake' "$BIN" switch Beta >/dev/null 2>&1
if [ "$("$BIN" history 1 | cut -d' ' -f2-)" = "switch Alpha -> Beta by=zsh_fake" ]; then ok "a caller name is kept to one plain word"
else bad "caller name not cleaned: $("$BIN" history 1)"; fi
"$BIN" switch Alpha >/dev/null 2>&1
if "$BIN" history x >/dev/null 2>&1; then bad "history accepted a count that is not a number"
else ok "history refuses a count that is not a number"; fi
# the log stays bounded: over 1000 lines it keeps the newest 500
for i in $(seq 1001); do echo "old $i"; done > "$TMP/slots/switch.log"
"$BIN" switch Beta >/dev/null 2>&1
lines=$(wc -l < "$TMP/slots/switch.log")
if [ "$lines" -eq 500 ]; then ok "the switch log is cut to its newest 500 lines"
else bad "the switch log has $lines lines, not 500"; fi
"$BIN" switch Alpha >/dev/null 2>&1; rm -f "$TMP/slots/switch.log"

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


# ---------------------------------------------------------------------------
# Drift: a manual /login put another account's login live while `active` still
# names Alpha. switch copies the live login back into Alpha, so Alpha's own
# login must be kept in the backups first: neither login may be lost.
# ---------------------------------------------------------------------------
rm -rf "$TMP/slots/backups"
printf '%s' '{"claudeAiOauth":{"accessToken":"alpha-own","refreshToken":"alpha-own","scopes":[]}}' > "$TMP/slots/Alpha.json"
printf '%s' '{"claudeAiOauth":{"accessToken":"other-account","refreshToken":"other-account","scopes":[]}}' > "$TMP/live.json"
echo Alpha > "$TMP/slots/active"
"$BIN" switch Beta >/dev/null 2>&1
if grep -qs '"alpha-own"' "$TMP"/slots/backups/slots/Alpha/*.json && grep -qs '"other-account"' "$TMP/slots/Alpha.json"; then
  ok "a drifted live login is copied back, and the slot's own login is kept in the backups"
else
  bad "switch after a drift lost the slot's own login (backups: $(ls "$TMP/slots/backups" 2>&1))"
fi

# --from: a script's compare-and-switch. It switches only while the slot it
# read is still live and nothing is pinned; else exit 3 and nothing changes.
cp "$TMP/slots/Alpha.json" "$TMP/live.json"; echo Alpha > "$TMP/slots/active"
out="$("$BIN" switch Beta --from Gamma 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && [ "$(cat "$TMP/slots/active")" = Alpha ] && grep -q 'now Alpha, not Gamma' <<<"$out"; then
  ok "switch --from refuses when another slot went live meanwhile"
else
  bad "switch --from ignored a newer switch (rc=$rc, out: $out)"
fi
echo Alpha > "$TMP/slots/pinned"
out="$("$BIN" switch Beta --from Alpha 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && [ "$(cat "$TMP/slots/active")" = Alpha ]; then ok "switch --from refuses while a slot is pinned"; else bad "switch --from ignored a pin (rc=$rc, out: $out)"; fi
rm -f "$TMP/slots/pinned"
if "$BIN" switch Beta --from Alpha >/dev/null 2>&1 && [ "$(cat "$TMP/slots/active")" = Beta ]; then ok "switch --from switches when the read still holds"; else bad "switch --from refused a valid switch"; fi
"$BIN" switch Alpha >/dev/null 2>&1

# No drift: the live login is the active slot's own file, so there is nothing to
# keep and no slot backup is written.
rm -rf "$TMP/slots/backups"
cp "$TMP/slots/Beta.json" "$TMP/live.json"; echo Beta > "$TMP/slots/active"
"$BIN" switch Alpha >/dev/null 2>&1
if [ -z "$(find "$TMP/slots/backups/slots" -type f 2>/dev/null)" ]; then
  ok "a switch with no drift writes no slot backup"
else
  bad "a switch with no drift backed up the slot ($(find "$TMP/slots/backups/slots" -type f))"
fi
echo Alpha > "$TMP/slots/active"

# Known drift: the live login is exactly Beta's saved login while active says
# Alpha. Switching to Beta must not copy Beta's login into Alpha: each slot keeps
# its own account.
printf '%s' '{"claudeAiOauth":{"accessToken":"alpha-own","refreshToken":"a","scopes":[]}}' > "$TMP/slots/Alpha.json"
printf '%s' '{"claudeAiOauth":{"accessToken":"beta-own","refreshToken":"b","scopes":[]}}' > "$TMP/slots/Beta.json"
cp "$TMP/slots/Beta.json" "$TMP/live.json"
echo Alpha > "$TMP/slots/active"
out="$("$BIN" switch Beta 2>&1)"
if grep -qs '"alpha-own"' "$TMP/slots/Alpha.json" && grep -qs '"beta-own"' "$TMP/slots/Beta.json" && grep -q "live login is slot Beta's" <<<"$out"; then
  ok "a live login that is another slot's is never copied into the active slot"
else
  bad "known drift overwrote a slot (Alpha: $(cat "$TMP/slots/Alpha.json"); out: $out)"
fi

# Pruning one slot's backups never touches another slot, whatever the names: A
# keeps its newest 10, and A-1 and A-20200101-000000 (a name that looks like a
# backup of A) keep theirs.
rm -rf "$TMP/slots/backups"
for s in A A-1 A-20200101-000000; do printf '%s' "$CRED" > "$TMP/slots/$s.json"; mkdir -p "$TMP/slots/backups/slots/$s"; done
printf '%s' "$CRED" > "$TMP/slots/backups/slots/A-1/20200101-000000-1.json"
printf '%s' "$CRED" > "$TMP/slots/backups/slots/A-20200101-000000/20200101-000000-1.json"
for i in 01 02 03 04 05 06 07 08 09 10 11; do printf '%s' "$CRED" > "$TMP/slots/backups/slots/A/202001${i}-000000-1.json"; done
printf '%s' '{"claudeAiOauth":{"accessToken":"drifted","refreshToken":"drifted","scopes":[]}}' > "$TMP/live.json"
echo A > "$TMP/slots/active"
"$BIN" switch A-1 >/dev/null 2>&1
na=$(find "$TMP/slots/backups/slots/A" -name '*.json' | wc -l)
if [ -f "$TMP/slots/backups/slots/A-1/20200101-000000-1.json" ] && [ -f "$TMP/slots/backups/slots/A-20200101-000000/20200101-000000-1.json" ] && [ "$na" -eq 10 ]; then
  ok "pruning slot A's backups keeps every other slot's backups (A has $na)"
else
  bad "pruning slot A touched another slot, or kept the wrong count (A has $na; $(find "$TMP/slots/backups" -type f))"
fi
rm -f "$TMP/slots/A.json" "$TMP/slots/A-1.json" "$TMP/slots/A-20200101-000000.json"; echo Alpha > "$TMP/slots/active"

# ---------------------------------------------------------------------------
# Lock: while another process holds the switch lock, switch waits, then gives
# up without touching the live login or the slots.
# ---------------------------------------------------------------------------
if command -v flock >/dev/null 2>&1; then
  echo Beta > "$TMP/slots/active"
  cp "$TMP/live.json" "$TMP/live-before.json"
  hold_lock "$TMP/slots/switch.lock" 4
  out="$(CLAUDE_ACCOUNT_LOCK_WAIT=1 "$BIN" switch Alpha 2>&1)"; rc=$?
  # save takes the same lock: it must not move the active pointer either
  sout="$(CLAUDE_ACCOUNT_LOCK_WAIT=1 "$BIN" save Alpha 2>&1)"; src=$?
  wait "$holder"
  if [ "$src" -ne 0 ] && [ "$(cat "$TMP/slots/active")" = Beta ] && grep -q 'still running; nothing changed' <<<"$sout"; then
    ok "save gives up while another switch holds the lock, and changes nothing"
  else
    bad "save ran while the lock was held (rc=$src, out: $sout)"
  fi
  if [ "$rc" -ne 0 ] && cmp -s "$TMP/live.json" "$TMP/live-before.json" && [ "$(cat "$TMP/slots/active")" = Beta ] && grep -q 'still running; nothing changed' <<<"$out"; then
    ok "switch gives up while another switch holds the lock, and changes nothing"
  else
    bad "switch ran while the lock was held (rc=$rc, out: $out)"
  fi
  if out="$("$BIN" switch Alpha 2>&1)"; then ok "switch runs once the lock is free"; else bad "switch failed with the lock free (got: $out)"; fi
  if flock -n "$TMP/slots/switch.lock" true; then ok "a finished switch leaves the lock free"; else bad "the switch lock is still held after the switch ended"; fi
else
  ok "no flock on this machine; the lock case is skipped"
fi

# ---------------------------------------------------------------------------
# The account-picker mod runs its bundled copy as `bash <path>`, so an install
# that dropped the exec bit still works, `next` included (it calls itself again).
# ---------------------------------------------------------------------------
NOX="$TMP/noexec/claude-account"
mkdir -p "$TMP/noexec" && cp "$BIN" "$NOX" && chmod 644 "$NOX"
echo Alpha > "$TMP/slots/active"
js="$(bash "$NOX" status --json 2>&1)"
if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["active"]=="Alpha", d' "$js" 2>/dev/null; then
  ok "a copy with no exec bit runs status --json through bash"
else
  bad "a copy with no exec bit failed status --json (got: $js)"
fi
out="$(bash "$NOX" next 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$TMP/slots/active")" = Beta ]; then
  ok "a copy with no exec bit runs next through bash"
else
  bad "next failed from a copy with no exec bit (rc=$rc, out: $out)"
fi

echo
echo "== $FAIL failed, $PASS passed =="
[ "$FAIL" -eq 0 ]
