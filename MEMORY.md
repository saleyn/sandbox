# Debugging JS/WebSocket apps (LiveView, canvas/DOM editors) with headless Chrome + raw CDP

Lessons from debugging the nice-dag-core-based DAG editor (`assets/js/nice-dag-hook.js`).
Headless `--screenshot` is a dead end for anything interactive — it's single-shot and can't
click, drag, or wait for async state. Driving Chrome DevTools Protocol (CDP) directly over a
WebSocket is the way to actually reproduce click/drag bugs and read live JS state.

## Setup (once per debugging session)

```bash
google-chrome-stable --headless --no-sandbox --disable-gpu \
  --remote-debugging-port=9333 --user-data-dir=/tmp/chrome-prof-cdp-<unique> about:blank &
sleep 3
node -e "fetch('http://localhost:9333/json/version').then(r=>r.json()).then(d=>console.log(d.Browser))"
```

- Launch with the Bash tool's `run_in_background: true`, not `&` inside a foreground call —
  a foregrounded launch can get SIGTERM'd by the tool's own timeout before Chrome finishes
  starting, leaving CDP unreachable with a confusing `ECONNREFUSED`.
- Give every profile dir a unique suffix (`$$`, a timestamp). A stale/reused profile can
  mask bugs or carry over state between "fresh" test runs.
- Install `ws` in a scratch dir once (`cd /tmp && npm init -y && npm install ws`) — Node 18
  has no built-in WebSocket client suitable for raw CDP framing.

## Minimal CDP driver shape

Every test script is the same skeleton: connect to the browser-level `webSocketDebuggerUrl`,
create+attach to a target, then send numbered JSON-RPC messages and resolve on matching `id`:

```js
const WebSocket = require("/tmp/node_modules/ws");
const browserWs = new WebSocket(webSocketDebuggerUrl);
let msgId = 1;
const pending = new Map();
function send(ws, method, params = {}, sessionId) {
  return new Promise((resolve) => {
    const id = msgId++;
    pending.set(id, resolve);
    ws.send(JSON.stringify({ id, method, params, ...(sessionId && { sessionId }) }));
  });
}
browserWs.on("message", (data) => {
  const msg = JSON.parse(data);
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg.result); pending.delete(msg.id); }
});
const { targetId } = await send(browserWs, "Target.createTarget", { url: "about:blank" });
const { sessionId } = await send(browserWs, "Target.attachToTarget", { targetId, flatten: true });
await send(browserWs, "Runtime.enable", {}, sessionId);
await send(browserWs, "Page.enable", {}, sessionId);
```

## Real interaction, not `.click()`

`element.click()` / `element.dispatchEvent(new MouseEvent(...))` bypasses real hit-testing
and coordinate computation. It's fine for simple "did this listener fire" checks, but it
produced **false positives** for drag-and-drop here — code that worked under `.click()`
failed for the actual user with a real mouse. Use `Input.dispatchMouseEvent` with a full
press → N intermediate moves → release sequence to get genuinely representative behavior:

```js
await send(browserWs, "Input.dispatchMouseEvent", { type: "mouseMoved", x, y }, sessionId);
await send(browserWs, "Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 }, sessionId);
for (let i = 1; i <= 10; i++) {
  await send(browserWs, "Input.dispatchMouseEvent", {
    type: "mouseMoved", x: startX + (endX-startX)*i/10, y: startY + (endY-startY)*i/10,
    button: "left", buttons: 1
  }, sessionId);
  await new Promise(r => setTimeout(r, 20)); // real gap between frames matters for some libs
}
await send(browserWs, "Input.dispatchMouseEvent", { type: "mouseReleased", x: endX, y: endY, button: "left", clickCount: 1 }, sessionId);
```

Caveat discovered here: synthetic `MouseEvent`s built via `new MouseEvent(...)` leave
`pageX`/`pageY` at `0` even when `clientX`/`clientY` are set (not part of `MouseEventInit`).
Any library code reading `e.pageX` instead of `e.clientX` will silently break with
hand-built events. `Input.dispatchMouseEvent`-driven events don't have this problem.

## Reading live app state

`Runtime.evaluate` with `expression` is the workhorse — always `JSON.stringify()` the return
value, since `result.value` for non-primitive returns comes back `undefined` and causes a
confusing `JSON.parse` crash in the driver script, not in the app.

For module-scoped JS that never attaches to `window`, there's no way to reach it from
outside — reuse the real hook/module file in an isolated harness page instead of trying to
peek into the live page's closures (see "Isolated re-test harness" below).

## Patching library internals you can't edit

To observe what a black-box dependency does internally (arguments, call counts, whether a
listener fires at all) without modifying `node_modules`, monkey-patch a shared prototype
method via `Page.addScriptToEvaluateOnNewDocument` — this runs before ANY page script,
including the one that attaches the library's own listeners:

```js
await send(browserWs, "Page.addScriptToEvaluateOnNewDocument", {
  source: `
    const orig = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = function(type, listener, opts) {
      if (type === "mouseup" && this.className === "target-class") {
        const wrapped = function(e) { console.log("FIRED", e.clientX, e.clientY); return listener.call(this, e); };
        return orig.call(this, type, wrapped, opts);
      }
      return orig.call(this, type, listener, opts);
    };
  `
}, sessionId);
// ... THEN navigate:
await send(browserWs, "Page.navigate", { url }, sessionId);
```

**Patching after navigation is too late** — if the library attaches its listener during
page load (e.g. in a constructor that runs at `mounted()`), a patch injected via
`Runtime.evaluate` post-load never sees it. This cost significant time before realizing it;
always inject via `addScriptToEvaluateOnNewDocument` + navigate after, never patch-then-check
on an already-loaded page.

Same technique works for intercepting `Object.defineProperty` (to wrap instance methods
assigned via `Object.defineProperty(this, "methodName", {value: fn})` — a common pattern in
bundled/minified class-field-polyfilled code) or `Element.prototype.setAttribute` (to catch
every DOM mutation of a specific attribute, e.g. an SVG path's `d`).

## Isolated re-test harness for an un-exported module

When a bug might be in your own code vs. a library, and the real page is a Phoenix
LiveView you can't easily inject into mid-session: bundle the *actual* hook file standalone
with esbuild and drive it directly, bypassing LiveView entirely:

```bash
esbuild assets/js/nice-dag-hook.js --bundle --format=iife --global-name=HookModule \
  --outfile=/tmp/test/hook.bundle.js
```

```html
<script src="hook.bundle.js"></script>
<script>
  const hook = Object.create(HookModule.NiceDagHook);
  hook.el = document.getElementById("dag-editor-root");
  hook.pushEvent = (event, payload) => console.log("PUSHED", event, payload);
  hook.mounted();
</script>
```

This proved the real fix (not just a guess) for several bugs here: it let me call
`add-task`/`add-condition`/`save` exactly as the toolbar would, and inspect the pushed
`save_graph` payload directly — something impossible to observe from outside a live
LiveView session without a full round trip.

## General debugging posture that worked here

- **Don't trust a single green test.** `.click()` succeeding was a false signal for
  drag-and-drop; always re-verify the specific interaction *shape* (click vs. click-drag vs.
  multi-step drag) that the user actually performs, not just "can this code path execute."
- **Isolate one variable at a time.** When edge position was wrong, the fastest progress came
  from testing plain task→task edges (no custom logic) to find out whether the bug was in
  *my* code or in the library's own default path — ruled out my code in one step instead of
  re-reading my own function for the tenth time.
- **A value matching something unrelated (e.g. the mouse's last drop coordinate) is a strong
  clue**, not a coincidence — if a computed value keeps lining up with input you didn't feed
  into that computation, suspect a stale/cached reference or a different code path firing
  than the one you're staring at.
- **When a hand-reasoned trace and live instrumentation disagree, trust the instrumentation.**
  Re-reading minified library source line-by-line is slow and easy to misjudge (operator
  precedence, closure capture, `o(this, ...)` class-field polyfills); a runtime log of actual
  arguments/call-counts resolves ambiguity in one run.
