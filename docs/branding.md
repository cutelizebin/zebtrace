# ZebTrace branding

ZebTrace combines Zeb's name with a trace of personal activity. The app icon uses
a pale mint Z path with an amber recording endpoint on a midnight navy tile.
The menu bar uses an original monochrome vector version, drawn in
`Sources/ZebTrace/StatusIcon.swift` so it stays sharp in light and dark mode.
Its endpoint is hollow while idle, filled while recording, an ellipsis during
start/save, and an exclamation mark when a recording fails.

## Assets and rebuilding

- `Resources/AppIcon.png`: the original AI-generated source, retained unchanged.
- `Resources/AppIcon.icns`: all standard macOS icon sizes, built with `sips` and `iconutil`.
- `scripts/build-icon.sh`: reproducible resizing and encoding; run `make icon`.

The assets are included under the repository's MIT license. The source was
generated using Codex's built-in image generation on 2026-09-05; no external
reference images were supplied. Image regeneration may produce a different
result; rebuilding the checked-in source does not require an AI service.

## Generation prompt

```text
Use case: logo-brand. Create ONE finished macOS app icon for ZebTrace, a minimal native personal activity recorder and personal timeline. Square 1024x1024 output. A single bold, beautifully proportioned geometric Z drawn as one continuous route: horizontal top, diagonal descending stroke, horizontal bottom. Use rounded stroke corners and a small warm amber circular endpoint at the lower right to suggest recording a trace. The Z should be instantly legible at 32 pixels. Main mark in pale luminous mint-white, on a deep midnight navy rounded-square macOS app tile, with very restrained cyan reflected lighting and subtly tactile satin material. Elegant flat-front design with just a little depth, no bulky inflated plastic, no excessive gloss. The tile occupies about 88 percent of the canvas, centered with equal transparent outer padding and genuinely transparent outer corners. Strong simple silhouette, balanced negative space, crisp clean geometry. No text or letters other than the stylized Z mark itself. No microphone, sound wave, brain, eye, infinity loop, extra symbols, watermarks, desktop mockup, contact sheet or surrounding scene. This is the actual app icon asset, not a presentation.
```
