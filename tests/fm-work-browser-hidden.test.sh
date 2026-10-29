#!/usr/bin/env bash
# Visibility guard for the fleet work browser.
#
# A worker page opened in a visible browser pops on screen. These cases drive
# bin/fm-work-browser.sh against a fake browser endpoint and a fake Chrome
# binary. They never launch the real work browser and never touch its profile.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-work-browser-hidden)
HOME_DIR="$TMP_ROOT/home"
FAKE="$TMP_ROOT/fake-browser.mjs"
REFUSE_CHROME="$TMP_ROOT/refuse-chrome"
RESTART_CHROME="$TMP_ROOT/restart-chrome"
CHROME_LOG="$TMP_ROOT/chrome-args"
TOKEN="fmwb$$-$RANDOM"
PIDS=()
mkdir -p "$HOME_DIR/data" "$HOME_DIR/config"

cat > "$FAKE" <<'EOF'
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';

const args = process.argv.slice(2);
function arg(name, fallback) {
  const i = args.indexOf(name);
  return i === -1 ? fallback : args[i + 1];
}
const port = Number(arg('--port', '0'));
const mode = arg('--mode', 'hidden');
const logPath = arg('--log', '');
const hangFirst = arg('--hang-first', '0') === '1';
const visibleAfter = Number(arg('--visible-after', '0'));
const raw = arg('--compartments', '');
let versionHits = 0;
const contexts = raw.split(',').map(s => s.trim()).filter(Boolean).map((spec, i) => {
  if (spec.startsWith('title:')) {
    const title = spec.slice('title:'.length);
    return { id: `CTX${i + 1}`, title, url: 'https://work.example/' };
  }
  return {
    id: `CTX${i + 1}`,
    title: '',
    url: `data:text/html,<title>fm-${spec}</title>fm-${spec}`,
  };
});
let seq = 1;

function log(line) {
  if (logPath) fs.appendFileSync(logPath, `${line}\n`);
}

function sendFrame(socket, text) {
  const payload = Buffer.from(text);
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, payload.length]);
  } else {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  }
  socket.write(Buffer.concat([header, payload]));
}

function consume(buf, socket) {
  while (buf.length >= 2) {
    const opcode = buf[0] & 0x0f;
    const masked = (buf[1] & 0x80) !== 0;
    let len = buf[1] & 0x7f;
    let offset = 2;
    if (len === 126) {
      if (buf.length < 4) return buf;
      len = buf.readUInt16BE(2);
      offset = 4;
    } else if (len === 127) {
      if (buf.length < 10) return buf;
      len = Number(buf.readBigUInt64BE(2));
      offset = 10;
    }
    const maskLen = masked ? 4 : 0;
    if (buf.length < offset + maskLen + len) return buf;
    let payload = buf.subarray(offset + maskLen, offset + maskLen + len);
    if (masked) {
      const mask = buf.subarray(offset, offset + 4);
      payload = Buffer.from(payload);
      for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
    }
    if (opcode === 0x8) socket.end();
    if (opcode === 0x9) sendFrame(socket, '');
    if (opcode === 0x1) onText(socket, payload.toString('utf8'));
    buf = buf.subarray(offset + maskLen + len);
  }
  return buf;
}

function onText(socket, text) {
  let msg;
  try { msg = JSON.parse(text); } catch { return; }
  if (!msg.id) return;
  let result;
  try {
    result = onMethod(msg.method, msg.params || {});
  } catch (e) {
    sendFrame(socket, JSON.stringify({ id: msg.id, error: { message: e.message } }));
    return;
  }
  sendFrame(socket, JSON.stringify({ id: msg.id, result }));
}

function onMethod(method, params) {
  log(`method ${method}`);
  if (method === 'Target.getBrowserContexts') {
    return { browserContextIds: contexts.map(c => c.id), defaultBrowserContextId: 'DEFAULT' };
  }
  if (method === 'Target.getTargets') {
    return {
      targetInfos: [
        { type: 'page', title: 'about:blank', url: 'about:blank', browserContextId: 'DEFAULT' },
        ...contexts.map(c => ({ type: 'page', title: c.title, url: c.url, browserContextId: c.id })),
      ],
    };
  }
  if (method === 'Target.createBrowserContext') return { browserContextId: `NEW${seq++}` };
  if (method === 'Storage.getCookies') return { cookies: [] };
  if (method === 'Storage.setCookies') return {};
  if (method === 'Target.createTarget') {
    log(`createTarget ${params.url || ''}`);
    return { targetId: `TGT${seq++}` };
  }
  if (method === 'Target.disposeBrowserContext') return {};
  throw new Error(`unhandled ${method}`);
}

const server = http.createServer((req, res) => {
  const path = (req.url || '').split('?')[0];
  log(`http ${path}`);
  if (path !== '/json/version') {
    res.statusCode = 404;
    res.end('missing');
    return;
  }
  versionHits += 1;
  if (hangFirst && versionHits === 1) {
    log('http hang /json/version');
    req.on('error', () => {});
    res.on('error', () => {});
    req.socket.on('error', () => {});
    return;
  }
  const hidden = visibleAfter > 0 ? versionHits <= visibleAfter : mode === 'hidden';
  const product = hidden ? 'HeadlessChrome/1.2.3' : 'Chrome/1.2.3';
  log(`version ${hidden ? 'hidden' : 'visible'}`);
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({
    Browser: 'Chrome/1.2.3',
    'User-Agent': `Mozilla/5.0 ${product}`,
    webSocketDebuggerUrl: `ws://127.0.0.1:${server.address().port}/devtools/browser/fake`,
  }));
});

server.on('clientError', () => {});

server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'] || '';
  const accept = crypto.createHash('sha1')
    .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
  );
  log('ws open');
  let buf = Buffer.alloc(0);
  socket.on('data', chunk => {
    buf = Buffer.concat([buf, chunk]);
    buf = consume(buf, socket);
  });
});

server.listen(port, '127.0.0.1', () => {
  process.stdout.write(`port=${server.address().port}\n`);
});
EOF

cat > "$REFUSE_CHROME" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$CHROME_LOG"
echo "refused a Chrome launch" >&2
exit 1
EOF
chmod +x "$REFUSE_CHROME"

cat > "$RESTART_CHROME" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$CHROME_LOG"
port=""
mode=visible
for a in "\$@"; do
  case "\$a" in
    --remote-debugging-port=*) port=\${a#--remote-debugging-port=} ;;
    --headless|--headless=new) mode=hidden ;;
  esac
done
[ -n "\$port" ] || exit 1
node "$FAKE" --port "\$port" --mode "\$mode" --log "$TMP_ROOT/restart-server.log" \\
  --remote-debugging-port="\$port" --fm-wb-test-token="$TOKEN" &
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if curl -sf --max-time 1 "http://127.0.0.1:\$port/json/version" >/dev/null; then
    exit 0
  fi
  sleep 0.1
done
exit 1
EOF
chmod +x "$RESTART_CHROME"

cleanup() {
  local pid
  if [ "${#PIDS[@]}" -gt 0 ]; then
    for pid in "${PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
  fi
  pkill -f "fm-wb-test-token=$TOKEN" 2>/dev/null || true
  fm_test_cleanup || true
}
trap cleanup EXIT

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{process.stdout.write(String(s.address().port));s.close()});'
}

# Start the fake endpoint and point this test's home at it. The port is never
# 9222 or 9333, and every call below passes it explicitly so a missed config
# file cannot fall through to the real work browser.
start_fake() {
  local mode=$1 compartments=${2:-} port log i
  port=$(free_port)
  case "$port" in
    ''|9222|9333) fail "refusing fake browser port '$port'" ;;
  esac
  log="$TMP_ROOT/server-$port.log"
  : > "$log"
  node "$FAKE" --port "$port" --mode "$mode" --log "$log" --compartments "$compartments" \
    --remote-debugging-port="$port" --fm-wb-test-token="$TOKEN" &
  PIDS+=("$!")
  FAKE_PORT=$port
  FAKE_LOG=$log
  printf '%s\n' "$port" > "$HOME_DIR/config/work-browser-port"
  i=0
  while [ "$i" -lt 20 ]; do
    if curl -sf --max-time 1 "http://127.0.0.1:$port/json/version" >/dev/null; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  fail "fake browser did not answer on port $port"
}

# Like start_fake, but does not read /json/version. A probe would consume the
# first version response, which these cases need compartment-open to see.
start_fake_quiet() {
  local mode=$1 port log i
  shift
  port=$(free_port)
  case "$port" in
    ''|9222|9333) fail "refusing fake browser port '$port'" ;;
  esac
  log="$TMP_ROOT/server-$port.log"
  : > "$log"
  node "$FAKE" --port "$port" --mode "$mode" --log "$log" --compartments "" \
    "$@" \
    --remote-debugging-port="$port" --fm-wb-test-token="$TOKEN" &
  PIDS+=("$!")
  FAKE_PORT=$port
  FAKE_LOG=$log
  printf '%s\n' "$port" > "$HOME_DIR/config/work-browser-port"
  i=0
  while [ "$i" -lt 50 ]; do
    if node -e 'const n=require("net"); const s=n.connect({port:Number(process.argv[1]),host:"127.0.0.1"},()=>{s.end();process.exit(0)}); s.on("error",()=>process.exit(1)); setTimeout(()=>process.exit(1),200);' "$port"; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  fail "fake browser did not listen on port $port"
}

WB() {
  [ -n "${FAKE_PORT:-}" ] || fail "refusing to call the work browser without a fake port"
  case "$FAKE_PORT" in
    9222|9333) fail "refusing to use real browser port $FAKE_PORT" ;;
  esac
  printf '%s\n' "$FAKE_PORT" > "$HOME_DIR/config/work-browser-port"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_WORK_BROWSER_PORT="$FAKE_PORT" \
    FM_WORK_BROWSER_CHROME="${CHROME_BIN_OVERRIDE:-$REFUSE_CHROME}" \
    "$ROOT/bin/fm-work-browser.sh" "$@"
}

chrome_was_launched() {
  [ -s "$CHROME_LOG" ]
}

reset_chrome_log() {
  : > "$CHROME_LOG"
}

test_status_reports_hidden_and_visible() {
  local out body
  start_fake hidden
  out=$(WB status 2>&1) || fail "status failed on a hidden browser: $out"
  assert_contains "$out" "(hidden)" "status did not report a HeadlessChrome browser as hidden: $out"
  assert_contains "$out" "pages=" "status dropped the page report: $out"
  # The Browser field stays "Chrome" on purpose: the marker lives in the
  # User-Agent, and a check of the Browser field alone would misread it.
  body=$(curl -sf --max-time 2 "http://127.0.0.1:$FAKE_PORT/json/version") \
    || fail "could not read the fake version payload"
  assert_contains "$body" "HeadlessChrome" "the fake did not serve the marker the check must read: $body"
  assert_contains "$body" "\"Browser\":\"Chrome/" \
    "the fake Browser field no longer matches current Chrome, so this no longer proves the marker is read from the whole body: $body"

  start_fake visible
  out=$(WB status 2>&1) || fail "status failed on a visible browser: $out"
  assert_contains "$out" "(visible)" "status did not report a headed browser as visible: $out"
  assert_not_contains "$out" "(hidden)" "a visible browser was reported hidden: $out"
  pass "fm-work-browser.sh: status reports hidden or visible from the HeadlessChrome marker"
}

test_compartment_open_refuses_while_visible_and_allows_hidden() {
  local out status
  start_fake visible
  reset_chrome_log
  status=0
  out=$(WB compartment-open worker-alpha example.com 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "compartment-open succeeded against a visible browser: $out"
  assert_contains "$out" "bin/fm-work-browser.sh hide" \
    "the refusal did not say how to hide the browser: $out"
  assert_not_contains "$(cat "$FAKE_LOG")" "createTarget" \
    "a visible browser still opened a worker page: $(cat "$FAKE_LOG")"
  chrome_was_launched && fail "refusing a visible compartment launched Chrome: $(cat "$CHROME_LOG")"

  start_fake hidden
  status=0
  out=$(WB compartment-open worker-alpha example.com 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "compartment-open refused a hidden browser: $out"
  assert_contains "$out" "context=" "a hidden browser did not open a compartment: $out"
  assert_contains "$(cat "$FAKE_LOG")" "createTarget" \
    "a hidden browser did not reach page creation: $(cat "$FAKE_LOG")"
  pass "fm-work-browser.sh: compartment-open refuses a visible browser and still opens a hidden one"
}

test_compartment_open_refuses_when_version_times_out_and_then_answers_visible() {
  local out status
  start_fake_quiet visible --hang-first 1
  status=0
  out=$(WB compartment-open worker-alpha example.com 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "compartment-open opened after a timed-out version read: $out"
  assert_contains "$out" "bin/fm-work-browser.sh hide" \
    "a timed-out version read did not name hide: $out"
  assert_contains "$(cat "$FAKE_LOG")" "http hang /json/version" \
    "the first version read was not the hung one: $(cat "$FAKE_LOG")"
  assert_not_contains "$(cat "$FAKE_LOG")" "version visible" \
    "compartment-open used the version read that recovered as visible: $(cat "$FAKE_LOG")"
  assert_not_contains "$(cat "$FAKE_LOG")" "createTarget" \
    "a timed-out version read still opened a worker page: $(cat "$FAKE_LOG")"
  pass "fm-work-browser.sh: compartment-open refuses when /json/version times out, even if it then answers visible"
}

test_compartment_open_refuses_when_its_own_version_read_is_visible() {
  local out status
  # The shell's read is hidden. The read the open uses to connect is the next one, and it is visible.
  start_fake_quiet hidden --visible-after 1
  status=0
  out=$(WB compartment-open worker-alpha example.com 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "compartment-open created a page after a visible version read: $out"
  assert_contains "$out" "bin/fm-work-browser.sh hide" \
    "a visible version read on open did not name hide: $out"
  assert_contains "$(cat "$FAKE_LOG")" "version visible" \
    "the open was not offered a visible browser: $(cat "$FAKE_LOG")"
  assert_contains "$(cat "$FAKE_LOG")" "ws open" \
    "the open did not connect on the visible read: $(cat "$FAKE_LOG")"
  assert_not_contains "$(cat "$FAKE_LOG")" "createTarget" \
    "a visible version read still opened a worker page: $(cat "$FAKE_LOG")"
  pass "fm-work-browser.sh: compartment-open does not create a page unless the read it connects with is hidden"
}

test_compartment_open_refuses_when_nothing_is_listening_without_calling_it_visible() {
  local out status port
  port=$(free_port)
  case "$port" in
    ''|9222|9333) fail "refusing unused port '$port'" ;;
  esac
  FAKE_PORT=$port
  printf '%s\n' "$port" > "$HOME_DIR/config/work-browser-port"
  status=0
  out=$(WB compartment-open worker-alpha example.com 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "compartment-open succeeded with nothing listening: $out"
  assert_not_contains "$out" "visible" "a missing browser was described as visible: $out"
  assert_not_contains "$out" "hide" "a missing browser was told to hide: $out"
  assert_contains "$out" "not answering" "a missing browser did not say it is not answering: $out"
  pass "fm-work-browser.sh: compartment-open refuses a missing browser without calling it visible"
}

test_start_on_a_visible_browser_names_hide() {
  local out
  start_fake visible
  reset_chrome_log
  out=$(WB start 2>&1) || fail "start failed on an already-running visible browser: $out"
  assert_contains "$out" "it is visible" "start did not say the browser is visible: $out"
  assert_contains "$out" "bin/fm-work-browser.sh hide" "start did not name hide: $out"
  chrome_was_launched && fail "start launched Chrome instead of naming hide: $(cat "$CHROME_LOG")"

  start_fake hidden
  reset_chrome_log
  out=$(WB start 2>&1) || fail "start failed on an already-hidden browser: $out"
  assert_contains "$out" "already running" "a hidden browser was not reported as already running: $out"
  assert_not_contains "$out" "it is visible" "a hidden browser was called visible: $out"
  chrome_was_launched && fail "start relaunched an already-hidden browser: $(cat "$CHROME_LOG")"
  pass "fm-work-browser.sh: start names hide when the browser is already visible"
}

test_hide_does_nothing_when_already_hidden_and_refuses_when_not_running() {
  local out status
  start_fake hidden
  reset_chrome_log
  out=$(WB hide 2>&1) || fail "hide failed on an already-hidden browser: $out"
  assert_contains "$out" "already hidden" "hide did not say the browser is already hidden: $out"
  assert_contains "$out" "nothing to do" "hide did not say it did nothing: $out"
  chrome_was_launched && fail "hide restarted an already-hidden browser: $(cat "$CHROME_LOG")"
  curl -sf --max-time 2 "http://127.0.0.1:$FAKE_PORT/json/version" >/dev/null \
    || fail "hide stopped a browser it said it would leave alone"

  FAKE_PORT=$(free_port)
  case "$FAKE_PORT" in
    ''|9222|9333) fail "refusing unused port '$FAKE_PORT'" ;;
  esac
  reset_chrome_log
  status=0
  out=$(WB hide 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "hide succeeded when no browser was running: $out"
  assert_contains "$out" "not running" "hide did not say the browser is not running: $out"
  chrome_was_launched && fail "hide launched Chrome when nothing was running: $(cat "$CHROME_LOG")"
  pass "fm-work-browser.sh: hide does nothing when already hidden and does not launch when stopped"
}

test_hide_refuses_while_a_worker_compartment_is_open_and_lists_its_context_id() {
  local out status
  # One compartment still shows its starting page and one has navigated to a
  # page titled fm-dashboard, which a title-based name would mislabel. The
  # refusal lists both by exact context id. The default context also has a
  # page; it must not be listed.
  start_fake visible "worker-alpha,title:fm-dashboard"
  reset_chrome_log
  status=0
  out=$(WB hide 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "hide restarted while worker compartments were open: $out"
  assert_contains "$out" "CTX1" "hide did not list the first compartment's context id: $out"
  assert_contains "$out" "CTX2" "hide did not list the navigated compartment's context id: $out"
  assert_contains "$out" "restart closes those pages" "the refusal did not say why it stopped: $out"
  assert_not_contains "$out" "dashboard" "hide labelled a compartment from its page title: $out"
  assert_not_contains "$out" "DEFAULT" "hide listed the default context as a worker compartment: $out"
  chrome_was_launched && fail "hide launched Chrome while refusing: $(cat "$CHROME_LOG")"
  curl -sf --max-time 2 "http://127.0.0.1:$FAKE_PORT/json/version" >/dev/null \
    || fail "hide stopped the browser while a worker compartment was open"
  pass "fm-work-browser.sh: hide refuses while a worker compartment is open and lists its context id"
}

test_hide_restarts_a_visible_browser_hidden_and_keeps_the_session_flag() {
  local out args profile
  start_fake visible
  reset_chrome_log
  CHROME_BIN_OVERRIDE=$RESTART_CHROME
  out=$(WB hide 2>&1) || {
    CHROME_BIN_OVERRIDE=
    fail "hide did not restart a visible browser with no compartments: $out"
  }
  CHROME_BIN_OVERRIDE=
  assert_contains "$out" "work browser stopped" "hide did not use the existing stop: $out"
  assert_contains "$out" "(headless)" "hide did not start the browser headless: $out"
  assert_contains "$out" "sessions were kept" "hide did not say the sessions were kept: $out"
  args=$(cat "$CHROME_LOG")
  assert_contains "$args" "--headless=new" "the restart did not request headless: $args"
  assert_contains "$args" "--restore-last-session" "the restart dropped the session-restore flag: $args"
  profile=$(sed -n 's/^--user-data-dir=//p' "$CHROME_LOG")
  case "$profile" in
    "$HOME_DIR"/*) ;;
    *) fail "the restart pointed at a profile outside the test home: $profile" ;;
  esac
  out=$(FM_WORK_BROWSER_PORT="$FAKE_PORT" curl -sf --max-time 2 "http://127.0.0.1:$FAKE_PORT/json/version") \
    || fail "the restarted browser is not answering"
  assert_contains "$out" "HeadlessChrome" "the restarted browser is not hidden: $out"
  pass "fm-work-browser.sh: hide restarts a visible browser headless and keeps session restore"
}

test_sign_in_and_usage_say_to_hide_before_a_worker_gets_a_page() {
  local out phrase
  phrase="Once the owner has signed in, run hide before any worker gets a page."
  start_fake hidden
  reset_chrome_log
  out=$(WB sign-in 2>&1) || fail "sign-in failed against an already-running browser: $out"
  assert_contains "$out" "$phrase" "sign-in did not tell the owner to run hide: $out"
  assert_contains "$out" "bin/fm-work-browser.sh hide" "sign-in did not name the hide command: $out"
  chrome_was_launched && fail "sign-in relaunched an already-running browser: $(cat "$CHROME_LOG")"

  out=$("$ROOT/bin/fm-work-browser.sh" help 2>&1) || fail "help failed: $out"
  assert_contains "$out" "$phrase" "usage did not tell the owner to run hide: $out"
  assert_contains "$out" "hide" "usage did not document hide: $out"
  pass "fm-work-browser.sh: sign-in and usage say to run hide before any worker gets a page"
}

test_status_reports_hidden_and_visible
test_compartment_open_refuses_while_visible_and_allows_hidden
test_compartment_open_refuses_when_version_times_out_and_then_answers_visible
test_compartment_open_refuses_when_its_own_version_read_is_visible
test_compartment_open_refuses_when_nothing_is_listening_without_calling_it_visible
test_start_on_a_visible_browser_names_hide
test_hide_does_nothing_when_already_hidden_and_refuses_when_not_running
test_hide_refuses_while_a_worker_compartment_is_open_and_lists_its_context_id
test_hide_restarts_a_visible_browser_hidden_and_keeps_the_session_flag
test_sign_in_and_usage_say_to_hide_before_a_worker_gets_a_page
printf '%s\n' "# all fm-work-browser-hidden tests passed"
