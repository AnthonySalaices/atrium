#!/usr/bin/env python3
"""Summarise logs/probe.jsonl into the four answers the spike exists to get."""
import json, os, sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "logs", "probe.jsonl")

recs = []
for line in open(LOG):
    try:
        r = json.loads(line)
    except ValueError:
        continue
    src = r.get("from", "")
    # Headset reports only: skip anything posted from this machine by a local test.
    if src and not src.startswith("127.0.0.1") and not src.startswith("::1"):
        recs.append(r)

if not recs:
    print("no reports from the headset yet")
    sys.exit(0)

caps = {}
keys = []
last_hb = None
for r in recs:
    d = r["data"]
    k = d.get("kind")
    if k == "session_start" or (k == "session_end" and d.get("caps")):
        caps.update(d.get("caps", {}))
    if k == "keys":
        keys.extend(d.get("events", []))
    if k == "session_end":
        keys.extend(d.get("keys", []))
    if k == "heartbeat":
        last_hb = d

print("=" * 62)
print("2 CAPABILITY")
for k in ("model", "xr_runtime", "quad_native", "cylinder_native", "hand_tracking",
          "refresh_rate", "refresh_rates", "blend_modes", "render_target_size"):
    if k in caps:
        print("  %-20s %s" % (k, caps[k]))

print()
print("1 KEYBOARD  (the question that decides the architecture)")
if not keys:
    print("  NO KEY EVENTS RECEIVED")
    print("  ⚠️  Before reading this as a failure, confirm a keyboard was actually")
    print("      PAIRED to the headset — check `dumpsys bluetooth_manager` for a")
    print("      bonded HID device. An unpaired keyboard looks identical to a")
    print("      keyboard whose events never arrive.")
else:
    uniq = {}
    for e in keys:
        uniq[(e.get("as_text"), e.get("ctrl"))] = True
    print("  total events: %d   distinct: %d" % (len(keys), len(uniq)))
    ctrl = [e for e in keys if e.get("ctrl")]
    arrows = [e for e in keys if e.get("as_text") in ("Left", "Right", "Up", "Down")]
    special = [e for e in keys if e.get("as_text") in ("Tab", "Escape", "BackSpace", "Enter", "Delete")]
    printable = [e for e in keys if e.get("unicode", 0) > 31]
    print("  printable (unicode > 0): %d" % len(printable))
    print("  arrow keys:              %d  %s" % (len(arrows), sorted({e['as_text'] for e in arrows})))
    print("  Tab/Esc/Backspace/Enter: %d  %s" % (len(special), sorted({e['as_text'] for e in special})))
    print("  ctrl chords:             %d  %s" % (len(ctrl), sorted({str(e['as_text']) for e in ctrl})))
    print()
    print("  VERDICT: %s" % (
        "keyboard works in an immersive session" if (printable and arrows and ctrl)
        else "PARTIAL — see which categories are 0 above"))

print()
print("4 HANDS")
if last_hb:
    print("  false pinches (<2cm): %s" % last_hb.get("false_pinches"))
    print("  min pinch L / R:      %s / %s" % (last_hb.get("pinch_min_left"), last_hb.get("pinch_min_right")))
    if last_hb.get("pinch_min_left") == -1.0 and last_hb.get("pinch_min_right") == -1.0:
        print("  ⚠️  -1.0 means NO tracking data — check hand tracking is enabled")
        print("      in the headset (Settings > Movement Tracking), not that hands")
        print("      were still.")
print()
print("reports: %d   (3 LEGIBILITY is a human judgement — ask him)" % len(recs))
