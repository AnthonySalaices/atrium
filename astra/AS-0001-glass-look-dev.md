# AS-0001 — Glass card look-dev for Glasshouse

**For:** Astra (Blender). **From:** Fable (Claude Code). **Date:** 2026-09-15.
**Deliver to:** `~/glasshouse/inbox/AS-0001/`

## What this is for

Glasshouse puts terminal sessions on floating glass cards in a Quest 3. The owner's direction:
*"the base foundation should be smooth, have glass windows and rounded edges with a bezel…
focus on clean look and good user experience."* He plans to build mods on this foundation and
hopes others will too, so the baseline has to be genuinely well-judged, not merely functional.

I have a working glass shader and a layout, rendered here:
`~/glasshouse/logs/preview-5.png` (also at `http://192.168.1.21:7550/glasshouse/preview-5.png`).
**Look at it first.** Earlier iterations are `preview-1..4.png` in the same places, and the
write-up with my own critique is at `http://192.168.1.21:4040/p/xr-workspace/renders`.

## ⛔ What I need back — and what I cannot use

**I need numbers and reference images, not assets.** The material is implemented as a GDScript
shader (`godot/shaders/glass_card.gdshader`), so a Blender material or a `.glb` cannot ship. What
transfers is: a render I can match by eye, plus the parameter values you chose and why.

Deliver into `~/glasshouse/inbox/AS-0001/`:

1. **`variants.png`** — a contact sheet of **6 glass card variants**, same card content each
   time, varying corner radius, bezel width and brightness, body translucency, and inner falloff.
   Label each one.
2. **`on-dark.png` / `on-bright.png`** — your best variant against two backdrops: a dark starfield
   nebula, and a bright, cluttered room (standing in for passthrough over a real desk).
   ⭐ The material has to survive both without retuning. That is the actual test.
3. **`attention.png`** — the same card at rest and in its "needs you" state, side by side. The
   signal is **edge luminance in the card's own material**, never a border drawn on top.
4. **`NOTES.md`** — your recommendation, with numbers: corner radius (as a fraction of card
   height), bezel width, body alpha, edge brightness at rest and at attention, and any falloff
   you used. Plus what you would change about the LAYOUT in preview-5.png — you have the better
   eye for that, and I would rather hear it bluntly.

## Constraints that are real, not preferences

- ⛔ **No backdrop blur.** Godot's Forward Mobile renderer (what the Quest uses) does not support
  screen-reading shaders, so I cannot blur what is behind a card. Do not design around frosted
  blur; it cannot be implemented. Transparency, a lit bezel, inner falloff and fine surface frost
  are what I actually have.
- ⛔ **Text legibility wins every argument.** These cards carry a terminal. At the Quest 3's
  ~25 PPD there is no margin for a material that fights the glyphs. If a variant looks gorgeous
  and costs contrast, say so and reject it.
- **Glass is for the WINDOWS only.** Never the backdrop — that is a separate, user-chosen thing
  (passthrough, a shipped sky, or their own .glb).
- **Angular sizes, so your framing matches the headset:** the focus panel is 51° wide at 1.5 m;
  a session card is about 15° × 5.5° at 1.55 m. Camera at human eye height, 104° horizontal FOV.
- Cards are flat quads facing the viewer. No thickness geometry — any sense of slab has to come
  from shading.

## Questions I would genuinely like your eye on

1. Does the bezel want to be uniform, or brighter along the top edge as if lit from above? The
   latter is more physical; I do not know whether it reads as fussy at this size.
2. Is my amber (`#FFB84A`) the right attention colour against both a purple nebula and a warm
   room, or does it need to shift?
3. The column of cards sits at −34° to the left. Too far? The owner asked for the left side.
4. At what point does the translucency stop reading as glass and start reading as grey plastic?
   I want the number where that happens, because it is the floor for the whole design.
