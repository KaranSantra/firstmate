#!/usr/bin/env bash
# Live guard for the fleet work browser and its sealed compartments.
#
# This is a harness-dependent check in the sense firstmate-coding-guidelines
# means: the verdict comes from Chrome's own behaviour, not from firstmate's
# code, so a stub could only confirm the assumption written into the stub. It
# drives a real, throwaway Chrome and spends no model tokens, so it runs by
# default wherever its tools are installed.
#
# It never touches the captain's personal Chrome: it launches its own browser,
# on its own port, with its own profile directory, and stops it again.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_WORK_BROWSER_LIVE_E2E node curl

CHROME_APP="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME_APP" ]; then
  echo "# skip: Google Chrome is not installed at $CHROME_APP"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-work-browser)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/config"

# A port of this guard's own, never 9222 (the captain's Chrome) and never the
# 9333 default, so a developer running this cannot disturb a real work browser.
PORT=9412
printf '%s\n' "$PORT" > "$HOME_DIR/config/work-browser-port"
WB() { FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-work-browser.sh" "$@"; }

cleanup() { WB stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Drive the browser's own protocol directly to establish ground truth, rather
# than asking firstmate's code whether firstmate's code worked.
cdp() { node -e "$1" "http://127.0.0.1:$PORT" "${2:-}"; }

SEED='
const [base] = process.argv.slice(1);
const ver = await (await fetch(base + "/json/version")).json();
const ws = new WebSocket(ver.webSocketDebuggerUrl);
let i = 0; const p = new Map();
await new Promise(r => ws.onopen = r);
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && p.has(m.id)) { p.get(m.id)(m); p.delete(m.id); } };
const s = (m, q = {}) => new Promise((res, rej) => { const n = ++i; p.set(n, x => x.error ? rej(new Error(x.error.message)) : res(x.result)); ws.send(JSON.stringify({ id: n, method: m, params: q })); });
await s("Storage.setCookies", { cookies: [
  { name: "keep", value: "KEEP", domain: "kept.example", path: "/" },
  { name: "drop", value: "DROP", domain: "dropped.example", path: "/" }]});
console.log("seeded"); ws.close();'

READ_CTX='
const [base, ctx] = process.argv.slice(1);
const ver = await (await fetch(base + "/json/version")).json();
const ws = new WebSocket(ver.webSocketDebuggerUrl);
let i = 0; const p = new Map();
await new Promise(r => ws.onopen = r);
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && p.has(m.id)) { p.get(m.id)(m); p.delete(m.id); } };
const s = (m, q = {}) => new Promise((res, rej) => { const n = ++i; p.set(n, x => x.error ? rej(new Error(x.error.message)) : res(x.result)); ws.send(JSON.stringify({ id: n, method: m, params: q })); });
const c = await s("Storage.getCookies", ctx ? { browserContextId: ctx } : {});
console.log(c.cookies.map(x => x.domain.replace(/^\./, "")).sort().join(","));
ws.close();'

COUNT_CTX='
const [base] = process.argv.slice(1);
const ver = await (await fetch(base + "/json/version")).json();
const ws = new WebSocket(ver.webSocketDebuggerUrl);
let i = 0; const p = new Map();
await new Promise(r => ws.onopen = r);
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && p.has(m.id)) { p.get(m.id)(m); p.delete(m.id); } };
const s = (m, q = {}) => new Promise((res, rej) => { const n = ++i; p.set(n, x => x.error ? rej(new Error(x.error.message)) : res(x.result)); ws.send(JSON.stringify({ id: n, method: m, params: q })); });
const t = await s("Target.getTargets", {});
console.log(new Set(t.targetInfos.filter(x => x.type === "page").map(x => x.browserContextId)).size);
ws.close();'

test_work_browser_starts_and_reports_status() {
  WB start >/dev/null 2>&1 || fail "the work browser did not start on port $PORT"
  WB status >/dev/null 2>&1 || fail "the work browser reported no status after starting"
  pass "fm-work-browser.sh: starts headless and reports status"
}

# The whole point of the design: a worker gets the captain's real session for
# its own sites and is genuinely signed out of everything else.
test_compartment_receives_only_allowlisted_sites() {
  local out ctx shared sealed
  cdp "$SEED" >/dev/null || fail "could not seed the shared jar"
  out=$(WB compartment-open live-task-a1 kept.example 2>/dev/null) \
    || fail "compartment-open failed"
  ctx=$(printf '%s\n' "$out" | sed -n 's/^context=//p')
  [ -n "$ctx" ] || fail "compartment-open returned no context: $out"
  assert_contains "$out" "cookies=1" "the compartment was handed the wrong number of cookies: $out"

  shared=$(cdp "$READ_CTX")
  sealed=$(cdp "$READ_CTX" "$ctx")
  case "$shared" in
    *kept.example*) ;;
    *) fail "the shared jar lost its seeded cookies: '$shared'" ;;
  esac
  case "$shared" in
    *dropped.example*) ;;
    *) fail "the shared jar lost the site that must NOT be handed over: '$shared'" ;;
  esac
  [ "$sealed" = "kept.example" ] \
    || fail "the compartment saw '$sealed'; it must hold only the allowlisted site"
  WB compartment-close "$ctx" >/dev/null 2>&1 || true
  pass "fm-work-browser.sh: a compartment holds only the allowlisted sites"
}

# A later sign-in in the shared browser must not reach an already-sealed worker,
# or the blast radius would grow after the fact.
test_compartment_cannot_see_later_shared_cookies() {
  local out ctx sealed
  out=$(WB compartment-open live-task-a2 kept.example 2>/dev/null) || fail "compartment-open failed"
  ctx=$(printf '%s\n' "$out" | sed -n 's/^context=//p')
  cdp '
const [base] = process.argv.slice(1);
const ver = await (await fetch(base + "/json/version")).json();
const ws = new WebSocket(ver.webSocketDebuggerUrl);
let i = 0; const p = new Map();
await new Promise(r => ws.onopen = r);
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && p.has(m.id)) { p.get(m.id)(m); p.delete(m.id); } };
const s = (m, q = {}) => new Promise((res, rej) => { const n = ++i; p.set(n, x => x.error ? rej(new Error(x.error.message)) : res(x.result)); ws.send(JSON.stringify({ id: n, method: m, params: q })); });
await s("Storage.setCookies", { cookies: [{ name: "later", value: "LATER", domain: "later.example", path: "/" }] });
ws.close();' >/dev/null || fail "could not add a later cookie to the shared jar"
  sealed=$(cdp "$READ_CTX" "$ctx")
  case "$sealed" in
    *later.example*) fail "a cookie added to the shared jar after sealing leaked into the compartment: '$sealed'" ;;
  esac
  WB compartment-close "$ctx" >/dev/null 2>&1 || true
  pass "fm-work-browser.sh: a sealed compartment cannot see later shared-jar logins"
}

# Cleanup is the single most expensive thing to get wrong, so closing must both
# work and be safe to repeat from an interrupted teardown.
test_compartment_close_is_idempotent() {
  local out ctx first second
  out=$(WB compartment-open live-task-a3 kept.example 2>/dev/null) || fail "compartment-open failed"
  ctx=$(printf '%s\n' "$out" | sed -n 's/^context=//p')
  first=$(WB compartment-close "$ctx" 2>&1) || fail "the first close failed: $first"
  second=$(WB compartment-close "$ctx" 2>&1) || fail "a repeated close failed instead of being a no-op: $second"
  assert_contains "$second" "closed" "a repeated close did not report success: $second"
  pass "fm-work-browser.sh: closing a compartment is idempotent, so an interrupted teardown can retry"
}

# Pointing the fleet at 9222 would put every worker back inside the browser the
# captain is using, which is the one thing this design exists to prevent.
test_captains_own_chrome_port_is_refused() {
  local out status
  printf '9222\n' > "$HOME_DIR/config/work-browser-port"
  status=0
  out=$(WB url 2>&1) || status=$?
  printf '%s\n' "$PORT" > "$HOME_DIR/config/work-browser-port"
  [ "$status" -ne 0 ] || fail "port 9222 was accepted as the work browser port: $out"
  assert_contains "$out" "captain's own Chrome" "the refusal did not say why 9222 is refused: $out"
  pass "fm-work-browser.sh: refuses the captain's own Chrome port"
}

# Cleanup is the single most expensive thing to get wrong: a compartment left
# behind holds that task's session with nothing left to name it. This drives the
# exact sequence bin/fm-teardown.sh runs - read browser_context= from the task
# record, then close it - against a real compartment and a real record.
test_teardown_sequence_disposes_a_recorded_compartment() {
  local out ctx meta recorded before after
  out=$(WB compartment-open live-task-a4 kept.example 2>/dev/null) || fail "compartment-open failed"
  ctx=$(printf '%s\n' "$out" | sed -n 's/^context=//p')
  meta="$TMP_ROOT/live-task-a4.meta"
  {
    printf 'harness=claude\nkind=ship\n'
    printf 'browser=work\nbrowser_port=11000\nbrowser_context=%s\n' "$ctx"
  } > "$meta"

  before=$(cdp "$COUNT_CTX")
  # The same read teardown performs, from a real record rather than a variable.
  recorded=$(sed -n 's/^browser_context=//p' "$meta")
  [ "$recorded" = "$ctx" ] || fail "the task record did not carry the compartment id"
  WB compartment-close "$recorded" >/dev/null 2>&1 || fail "the teardown sequence could not close the compartment"
  after=$(cdp "$COUNT_CTX")

  [ "$after" -lt "$before" ] \
    || fail "the compartment survived the teardown sequence (contexts before=$before after=$after)"
  pass "fm-work-browser.sh: the teardown sequence disposes a compartment recorded in the task record"
}

# `stop` must not report success while the browser is still answering: an
# unverified stop is how a ~680MB browser leaks unnoticed.
test_stop_confirms_the_browser_is_really_gone() {
  WB start >/dev/null 2>&1 || fail "the work browser did not start for the stop check"
  WB stop >/dev/null 2>&1 || fail "stop reported failure"
  if curl -s --max-time 3 "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1; then
    fail "stop returned success while the work browser was still answering on port $PORT"
  fi
  # Repeatable, so an interrupted cleanup can run it again.
  WB stop >/dev/null 2>&1 || fail "a repeated stop failed instead of being a no-op"
  WB start >/dev/null 2>&1 || fail "the work browser could not be restarted after a verified stop"
  pass "fm-work-browser.sh: stop confirms the browser is really gone before reporting success"
}

test_work_browser_starts_and_reports_status
test_stop_confirms_the_browser_is_really_gone
test_compartment_receives_only_allowlisted_sites
test_compartment_cannot_see_later_shared_cookies
test_compartment_close_is_idempotent
test_teardown_sequence_disposes_a_recorded_compartment
test_captains_own_chrome_port_is_refused
printf '%s\n' "# all fm-work-browser live tests passed"
