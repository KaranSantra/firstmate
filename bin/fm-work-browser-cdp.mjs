#!/usr/bin/env node
// Compartment operations against the fleet work browser, over Chrome's own
// remote-control protocol. bin/fm-work-browser.sh is the operator-facing entry
// point and owns the port, profile and lifecycle; this file owns only the
// protocol calls, which have no shell equivalent.
//
// A compartment is a Chrome browser context: a private cookie jar inside the one
// signed-in work browser. It starts EMPTY, is handed only the cookies whose
// domain is on this task's allowlist, and is disposed whole at teardown. That is
// what gives a worker the captain's real session for its own sites while leaving
// it genuinely signed out of everything else.
//
// Verified 2026-09-08 against Chrome 152.0.7977.82 on a throwaway work browser:
// a compartment handed 1 of 2 shared cookies saw only that one, could not see a
// cookie added to the shared jar afterwards, and driving its tab through
// chrome-devtools-axi read back exactly the allowlisted cookie while the shared
// tab read back both. Disposal removed the context and its tab together.
//
// This NEVER touches the captain's personal Chrome. It speaks only to the work
// browser it is given, which is a separate browser he signs into once.
//
// Cookies are carried; localStorage is not. A site that keeps its login in the
// page rather than in a cookie will present as signed out inside the
// compartment, which the worker reports rather than silently working around.

const [, , op, base, ...rest] = process.argv;

function die(msg) {
  process.stderr.write(`error: ${msg}\n`);
  process.exit(1);
}

function versionConfirmsHidden(body) {
  return typeof body === 'string' && body.includes('HeadlessChrome');
}

async function connect(baseUrl, unreadable = `the work browser is not answering at ${baseUrl}; start it with bin/fm-work-browser.sh start`) {
  let version;
  let versionBody = '';
  try {
    const res = await fetch(`${baseUrl}/json/version`, { signal: AbortSignal.timeout(5000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    versionBody = await res.text();
    version = JSON.parse(versionBody);
  } catch {
    die(unreadable);
  }
  const ws = new WebSocket(version.webSocketDebuggerUrl);
  let id = 0;
  const pending = new Map();
  await new Promise((res, rej) => {
    ws.onopen = res;
    ws.onerror = () => rej(new Error('could not open a control connection to the work browser'));
  }).catch(e => die(e.message));
  ws.onmessage = e => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  };
  const send = (method, params = {}) => new Promise((res, rej) => {
    const mid = ++id;
    pending.set(mid, m => (m.error ? rej(new Error(`${method}: ${m.error.message}`)) : res(m.result)));
    ws.send(JSON.stringify({ id: mid, method, params }));
  });
  return { ws, send, versionBody };
}

// A cookie belongs to an allowlisted site when its domain is that site or any
// subdomain of it. Chrome writes host cookies as "example.com" and domain
// cookies as ".example.com", so both spellings must match.
function cookieAllowed(domain, sites) {
  const d = domain.replace(/^\./, '').toLowerCase();
  return sites.some(s => d === s || d.endsWith(`.${s}`));
}

if (op === 'open') {
  const [taskId, allowlist] = rest;
  if (!taskId || !allowlist) die('open needs <task-id> <comma-separated-sites>');
  const sites = allowlist.split(',').map(s => s.trim().replace(/^\./, '').toLowerCase()).filter(Boolean);
  if (!sites.length) die('open needs at least one site in the allowlist');

  const { ws, send, versionBody } = await connect(base,
    'could not confirm the work browser is hidden because its /json/version read failed, so no worker page opens; hide it with bin/fm-work-browser.sh hide before any worker gets a page');
  if (!versionConfirmsHidden(versionBody)) {
    ws.close();
    die('the work browser is visible, so a worker page would open on screen; hide it with bin/fm-work-browser.sh hide before any worker gets a page');
  }
  const { browserContextId } = await send('Target.createBrowserContext', {});
  const shared = await send('Storage.getCookies', {});
  const give = shared.cookies.filter(c => cookieAllowed(c.domain, sites));
  if (give.length) await send('Storage.setCookies', { browserContextId, cookies: give });
  // The tab's URL names the task so a worker can identify its own tab in a
  // `chrome-devtools-axi pages` listing, whose ids are positional and shift.
  const { targetId } = await send('Target.createTarget', {
    url: `data:text/html,<title>fm-${taskId}</title>fm-${taskId}`,
    browserContextId,
  });
  process.stdout.write(`context=${browserContextId}\ntarget=${targetId}\ncookies=${give.length}\nsites=${sites.join(',')}\n`);
  if (!give.length) {
    process.stderr.write(
      `warning: the work browser holds no cookies for ${sites.join(', ')}; this compartment will be signed out. ` +
      'To sign it in, close this compartment first with bin/fm-work-browser.sh compartment-close ' +
      `${browserContextId} (or exit this worker), then run bin/fm-work-browser.sh sign-in, then bin/fm-work-browser.sh hide, ` +
      'then start the worker again.\n');
  }
  ws.close();
} else if (op === 'close') {
  const [contextId] = rest;
  if (!contextId) die('close needs <context-id>');
  const { ws, send } = await connect(base);
  // Idempotent by contract: a context already gone is a successful close, so
  // teardown can always call it.
  try {
    await send('Target.disposeBrowserContext', { browserContextId: contextId });
    process.stdout.write('closed\n');
  } catch (e) {
    if (/Failed to find context|No browser context/i.test(e.message)) {
      process.stdout.write('closed (already gone)\n');
    } else {
      ws.close();
      die(e.message);
    }
  }
  ws.close();
} else if (op === 'compartments') {
  // A worker compartment is a context this fleet created, not the default one.
  // Current Chrome gives the default context an id too, so "any browserContextId"
  // is not a compartment. Target.getBrowserContexts.browserContextIds is the list
  // of created contexts, reported here by their exact ids.
  const { ws, send } = await connect(base);
  const listed = await send('Target.getBrowserContexts', {});
  if (!Array.isArray(listed.browserContextIds)) {
    ws.close();
    die('the work browser did not report its compartments; refusing to treat that as none open');
  }
  for (const contextId of listed.browserContextIds) process.stdout.write(`${contextId}\n`);
  ws.close();
} else if (op === 'status') {
  const { ws, send } = await connect(base);
  const targets = await send('Target.getTargets', {});
  const pages = targets.targetInfos.filter(t => t.type === 'page');
  const contexts = new Set(pages.map(t => t.browserContextId).filter(Boolean));
  process.stdout.write(`pages=${pages.length}\ncontexts=${contexts.size}\n`);
  ws.close();
} else {
  die('usage: fm-work-browser-cdp.mjs <open|close|status|compartments> <browser-url> [args]');
}
