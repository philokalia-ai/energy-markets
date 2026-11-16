"""Computed-visibility check for the scoreboard Naive selector (#437 review P3; not CI).

`.filter { display:flex }` beats the browser's `[hidden]` rule, so `hidden=true` alone
left the selector on screen. Loads web/index.html in headless Chromium (light and dark,
390 and 1440 px) and asserts that #naive-filter has computed display:none and a 0x0 box
while hidden, and is laid out (display:flex, non-zero box) once unhidden. Optional
second argument: a served site URL (e.g. the stub API with old JSON) whose board must
render with the selector hidden.

  python test/scripts/naive_filter_visibility.py [chromium_executable] [site_url]
"""
import pathlib, sys
from playwright.sync_api import sync_playwright

exe = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
site = sys.argv[2] if len(sys.argv) > 2 else None
page_url = (pathlib.Path(__file__).resolve().parents[2] / "web" / "index.html").as_uri()
probe = """e => { const r = e.getBoundingClientRect();
  return {display: getComputedStyle(e).display, w: r.width, h: r.height, hidden: e.hidden}; }"""
fails = 0
with sync_playwright() as p:
    b = p.chromium.launch(**({"executable_path": exe} if exe else {}))
    for scheme in ("light", "dark"):
        for width in (390, 1440):
            pg = b.new_page(viewport={"width": width, "height": 900}, color_scheme=scheme)
            pg.goto(page_url)
            pg.wait_for_selector("#naive-filter", state="attached")
            # file:// has no data plane, so show the board view by hand (its section is hidden)
            pg.evaluate("() => { const v = document.getElementById('view-board'); v.hidden = false; v.style.display = 'block'; }")
            el = pg.query_selector("#naive-filter")
            hid = el.evaluate("e => { e.hidden = true; return 0; }") or el.evaluate(probe)
            shown = el.evaluate("e => { e.hidden = false; return 0; }") or el.evaluate(probe)
            ok = (hid["display"] == "none" and hid["w"] == 0 and hid["h"] == 0
                  and shown["display"] == "flex" and shown["w"] > 0 and shown["h"] > 0)
            fails += not ok
            print(("ok  " if ok else "FAIL"), scheme, width, "hidden:", hid, "shown:", shown)
            pg.close()
    if site:   # a served board with data: the selector's visibility as the app sets it
        pg = b.new_page(viewport={"width": 1440, "height": 900})
        pg.goto(site)
        pg.wait_for_selector("#scoreboard-table tbody tr", timeout=20000)
        pg.wait_for_timeout(500)
        st = pg.eval_on_selector("#naive-filter", probe)
        print("site", site, "->", st)
    b.close()
print("all passed" if not fails else f"{fails} failure(s)")
sys.exit(1 if fails else 0)
