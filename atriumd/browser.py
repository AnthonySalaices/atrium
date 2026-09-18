"""Browser mode: web apps on a panel, rendered here, shown in the headset.

The same bargain as the terminal: the HOST does the hard part (a real Chromium,
via Playwright) and the headset is dumb glass that paints JPEG frames and sends
back pointer/keyboard events. Nothing web-related runs on the Quest, and you
never leave the app.

* One persistent profile (logins survive restarts), one page per configured app.
* Frames come from Chrome's own screencast (CDP Page.startScreencast), which
  only produces a frame when the page actually changes, and only while someone
  is watching.
* A link that opens a new tab is loaded in place instead: there are no tabs to
  get lost in.

⛔ Which URLs exist is the HOST's config (`browser.apps`). The client can only
name an app and send input to it.
⛔ Playwright's async API lives on ONE thread with its own event loop; every
public function here hops onto it and is safe to call from daemon threads.
"""

import asyncio
import base64
import os
import threading
import time

PREFIX = "web:"

# tmux key names (keys.py whitelist) -> Playwright key names.
_KEYMAP = {
    "Enter": "Enter", "Escape": "Escape", "Tab": "Tab", "BTab": "Shift+Tab",
    "BSpace": "Backspace", "Space": " ", "DC": "Delete", "Delete": "Delete",
    "IC": "Insert", "Insert": "Insert", "Up": "ArrowUp", "Down": "ArrowDown",
    "Left": "ArrowLeft", "Right": "ArrowRight", "Home": "Home", "End": "End",
    "PageUp": "PageUp", "PPage": "PageUp", "PageDown": "PageDown", "NPage": "PageDown",
}
_MODS = {"C": "Control", "M": "Alt", "S": "Shift"}
MAX_LITERAL = 2048


def is_web(key):
    return isinstance(key, str) and key.startswith(PREFIX)


def pw_key(name):
    """'C-M-x' / 'S-Up' / 'Enter' / 'F5' -> 'Control+Alt+x' / 'Shift+ArrowUp' / …
    Returns None for anything not understood (refused, never typed)."""
    mods = []
    while len(name) > 2 and name[1] == "-" and name[0] in _MODS:
        mods.append(_MODS[name[0]])
        name = name[2:]
    if name in _KEYMAP:
        base = _KEYMAP[name]
    elif len(name) == 1:
        base = name
    elif name.startswith("F") and name[1:].isdigit() and 1 <= int(name[1:]) <= 12:
        base = name
    else:
        return None
    if base == " " and mods:
        base = "Space"
    return "+".join(mods + [base])


class _App:
    def __init__(self, key, spec):
        self.key = key
        self.spec = spec
        self.page = None
        self.cdp = None
        self.casting = False
        self.watchers = 0
        self.size = (0, 0)             # CSS px of the viewport
        self.last_frame = None         # the latest frame message, for new watchers
        self.sent_t = 0.0
        self.flush_pending = False
        self.dirty = False
        self.shooting = False


class Browser:
    def __init__(self, on_frame):
        """on_frame(key, msg) is called on the browser thread for every frame."""
        self.on_frame = on_frame
        self.cfg = {}
        self.apps = {}                 # key -> _App
        self.loop = None
        self._ctx = None
        self._pw = None
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        self._ready.wait(timeout=30)

    # ── thread plumbing ────────────────────────────────────────────────────
    def _run(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        # ⚠️ Every input coroutine takes this, in the order it was scheduled.
        # Without it a click and the keys typed after it interleave on the loop
        # and text lands out of order ("hello" + BSpace came out as "\nxhello").
        self._input = asyncio.Lock()
        self._ready.set()
        self.loop.run_forever()

    def _call(self, coro, wait=True, timeout=30):
        fut = asyncio.run_coroutine_threadsafe(coro, self.loop)
        if not wait:
            return fut
        return fut.result(timeout=timeout)

    # ── config ─────────────────────────────────────────────────────────────
    def configure(self, cfg):
        """cfg = the validated `browser` table. Returns the list of app keys."""
        self.cfg = cfg or {}
        wanted = {}
        for a in self.cfg.get("apps", []):
            wanted[PREFIX + a["name"]] = a
        for key in list(self.apps):
            if key not in wanted:
                self._call(self._close_app(key), wait=False)
        for key, spec in wanted.items():
            if key in self.apps:
                old = self.apps[key].spec
                self.apps[key].spec = spec
                if old != spec and self.apps[key].page is not None:
                    self._call(self._reopen(key), wait=False)
            else:
                self.apps[key] = _App(key, spec)
        return list(wanted)

    def keys(self):
        return list(self.apps)

    # ── public API (any thread) ────────────────────────────────────────────
    def watch(self, key):
        return self._call(self._watch(key), timeout=60)

    def unwatch(self, key):
        self._call(self._unwatch(key), wait=False)

    def click(self, key, u, v):
        self._call(self._pointer(key, "click", u, v, 0), wait=False)

    def move(self, key, u, v):
        self._call(self._pointer(key, "move", u, v, 0), wait=False)

    def wheel(self, key, u, v, lines):
        self._call(self._pointer(key, "wheel", u, v, lines), wait=False)

    def send_keys(self, key, seq):
        """Same items as keys.send: {"k": name} or {"l": text}. Returns count."""
        items = []
        for it in seq[:64]:
            if "k" in it:
                k = pw_key(str(it["k"]))
                if k is None:
                    raise ValueError("key not understood: %r" % it["k"])
                items.append(("press", k))
            elif "l" in it:
                items.append(("text", str(it["l"])[:MAX_LITERAL]))
        self._call(self._keys(key, items), wait=False)
        return len(items)

    def back(self, key):
        self._call(self._nav(key, "back"), wait=False)

    def reload(self, key):
        self._call(self._nav(key, "reload"), wait=False)

    def shutdown(self):
        try:
            self._call(self._shutdown(), timeout=10)
        except Exception:
            pass

    # ── browser thread ─────────────────────────────────────────────────────
    async def _context(self):
        if self._ctx is not None:
            return self._ctx
        from playwright.async_api import async_playwright
        self._pw = await async_playwright().start()
        profile = os.path.expanduser(self.cfg.get("profile_dir")
                                     or "~/.local/share/atrium/browser")
        os.makedirs(profile, exist_ok=True)
        d = self.cfg.get("desktop", {})
        self._ctx = await self._pw.chromium.launch_persistent_context(
            profile, headless=True,
            viewport={"width": int(d.get("width", 1280)), "height": int(d.get("height", 800))},
            args=["--disable-dev-shm-usage"])
        self._ctx.on("page", self._on_new_page)
        # The persistent context opens with one blank page; it is not an app.
        for p in list(self._ctx.pages):
            try:
                await p.close()
            except Exception:
                pass
        return self._ctx

    def _on_new_page(self, page):
        # A new tab (target=_blank, window.open): load it in the app it came
        # from instead, and close the tab. Never leave the app. ⚠️ Only pages
        # with an OPENER are popups — _open()'s own new_page() fires this too.
        async def adopt():
            try:
                opener = await page.opener()
            except Exception:
                opener = None
            app = next((a for a in self.apps.values() if opener is not None and a.page is opener), None)
            if app is None:
                return
            try:
                await page.wait_for_load_state("commit", timeout=10000)
            except Exception:
                pass
            url = page.url
            try:
                await page.close()
            except Exception:
                pass
            if url and url != "about:blank":
                try:
                    await app.page.goto(url)
                    print("[browser] %s: new tab %s loaded in place" % (app.key, url), flush=True)
                except Exception as e:
                    print("[browser] %s: popup %s failed: %s" % (app.key, url, e), flush=True)
        asyncio.ensure_future(adopt())

    async def _open(self, app):
        ctx = await self._context()
        spec = app.spec
        layout = self.cfg.get(spec.get("layout", "desktop"), {})
        w, h = int(layout.get("width", 1280)), int(layout.get("height", 800))
        scale = float(layout.get("scale", 1.0))
        app.page = await ctx.new_page()
        app.cdp = await ctx.new_cdp_session(app.page)
        await app.cdp.send("Emulation.setDeviceMetricsOverride", {
            "width": w, "height": h, "deviceScaleFactor": scale,
            "mobile": spec.get("layout") == "mobile"})
        if spec.get("layout") == "mobile":
            await app.cdp.send("Emulation.setTouchEmulationEnabled", {"enabled": True})
        app.size = (w, h)
        app.cdp.on("Page.screencastFrame", lambda ev, a=app: self._frame(a, ev))
        try:
            await app.page.goto(spec["url"], wait_until="commit", timeout=20000)
        except Exception as e:
            print("[browser] %s: %s failed to load: %s" % (app.key, spec["url"], e), flush=True)
        print("[browser] %s opened %s at %dx%d x%.1f" % (app.key, spec["url"], w, h, scale), flush=True)

    async def _reopen(self, key):
        app = self.apps.get(key)
        if app is None:
            return
        watching = app.watchers
        await self._close_page(app)
        if watching:
            await self._open(app)
            await self._cast(app, True)

    async def _close_page(self, app):
        if app.page is not None:
            try:
                await app.page.close()
            except Exception:
                pass
        app.page, app.cdp, app.casting, app.last_frame = None, None, False, None

    async def _close_app(self, key):
        app = self.apps.pop(key, None)
        if app:
            await self._close_page(app)

    async def _cast(self, app, on):
        if app.cdp is None or on == app.casting:
            return
        app.casting = on
        if on:
            w, h = app.size
            await app.cdp.send("Page.startScreencast", {
                "format": "jpeg", "quality": int(self.cfg.get("quality", 70)),
                "maxWidth": w, "maxHeight": h, "everyNthFrame": 1})
        else:
            try:
                await app.cdp.send("Page.stopScreencast")
            except Exception:
                pass

    def _scale(self, app):
        return float(self.cfg.get(app.spec.get("layout", "desktop"), {}).get("scale", 1.0))

    def _frame(self, app, ev):
        """One screencast frame. ⚠️ Headless Chrome's screencast is always 1x
        (deviceScaleFactor is ignored — verified on 149), so for scale > 1 the
        frame is only the "it changed" signal and a real screenshot at full
        resolution is taken instead (~60 ms at 860x1720)."""
        asyncio.ensure_future(app.cdp.send("Page.screencastFrameAck",
                                           {"sessionId": ev["sessionId"]}))
        if self._scale(app) <= 1.0:
            self._deliver(app, ev["data"], ev.get("metadata", {}))
            return
        app.dirty = True
        if not app.shooting:
            asyncio.ensure_future(self._shoot(app))

    async def _shoot(self, app):
        app.shooting = True
        try:
            while app.dirty and app.casting and app.cdp is not None:
                app.dirty = False
                try:
                    r = await app.cdp.send("Page.captureScreenshot", {
                        "format": "jpeg", "quality": int(self.cfg.get("quality", 70))})
                except Exception as e:
                    print("[browser] %s screenshot failed: %s" % (app.key, e), flush=True)
                    break
                self._deliver(app, r["data"], {})
                await asyncio.sleep(self._min_dt())
        finally:
            app.shooting = False

    def _min_dt(self):
        return 1.0 / max(1.0, float(self.cfg.get("fps", 15)))

    def _deliver(self, app, data, md):
        """Pace to `fps` without ever dropping the LAST frame: a page that
        stops changing must end on its final state, not one frame before it."""
        app.last_frame = {"type": "web-frame", "key": app.key, "jpeg": data,
                          "css_w": app.size[0], "css_h": app.size[1],
                          "url": app.page.url if app.page else "",
                          "scroll_y": md.get("scrollOffsetY", 0)}
        wait = app.sent_t + self._min_dt() - time.time()
        if wait <= 0:
            self._send(app)
        elif not app.flush_pending:
            app.flush_pending = True
            self.loop.call_later(wait, self._flush, app)

    def _flush(self, app):
        app.flush_pending = False
        if app.casting and app.last_frame is not None:
            self._send(app)

    def _send(self, app):
        app.sent_t = time.time()
        try:
            self.on_frame(app.key, app.last_frame)
        except Exception as e:
            print("[browser] frame callback failed: %s" % e, flush=True)

    async def _watch(self, key):
        app = self.apps.get(key)
        if app is None:
            raise KeyError("no such web app: %s" % key)
        app.watchers += 1
        if app.page is None:
            await self._open(app)
        await self._cast(app, True)
        return app.last_frame

    async def _unwatch(self, key):
        app = self.apps.get(key)
        if app is None:
            return
        app.watchers = max(0, app.watchers - 1)
        if app.watchers == 0:
            await self._cast(app, False)   # page stays open: state survives a switch

    def _xy(self, app, u, v):
        w, h = app.size
        return max(0.0, min(1.0, float(u))) * w, max(0.0, min(1.0, float(v))) * h

    async def _pointer(self, key, kind, u, v, lines):
        app = self.apps.get(key)
        if app is None or app.page is None:
            return
        x, y = self._xy(app, u, v)
        async with self._input:
            m = app.page.mouse
            try:
                await m.move(x, y)
                if kind == "click":
                    await m.click(x, y)
                elif kind == "wheel":
                    # One terminal "line" = 40 px of wheel; lines > 0 = older = up.
                    await m.wheel(0, -float(lines) * 40.0)
            except Exception as e:
                print("[browser] %s %s failed: %s" % (key, kind, e), flush=True)

    async def _keys(self, key, items):
        app = self.apps.get(key)
        if app is None or app.page is None:
            return
        async with self._input:
            kb = app.page.keyboard
            for kind, val in items:
                try:
                    if kind == "press":
                        await kb.press(val)
                    else:
                        await kb.insert_text(val)
                except Exception as e:
                    print("[browser] %s key %r failed: %s" % (key, val, e), flush=True)

    async def _nav(self, key, what):
        app = self.apps.get(key)
        if app is None or app.page is None:
            return
        try:
            if what == "back":
                await app.page.go_back()
            else:
                await app.page.reload()
        except Exception:
            pass

    async def _shutdown(self):
        for key in list(self.apps):
            await self._close_app(key)
        if self._ctx is not None:
            await self._ctx.close()
        if self._pw is not None:
            await self._pw.stop()
