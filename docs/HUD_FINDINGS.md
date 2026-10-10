# HUD recognition findings

## October 4 bar experiment

Four new Solo recordings provide 3,071 frames. A fixed-geometry color-bar prototype now measures health and shield offline. On 28 visually reviewed frames (56 values), the maximum error was 0.24 points and mean error was 0.077 points on the 0–100 scale. Measurement p95 was 0.368 ms across 616 sampled frames, excluding JPEG decoding and the rest of the pipeline.

These selected examples do not establish live accuracy. The prototype cannot distinguish an absent HUD from an empty bar, accepts only 3840 × 1736, and is not integrated into the app. Add HUD-presence and phase guards and test low health and layout changes before integration. The [Solo intake report](SOLO_INTAKE.md) records the sample limitations and reproducible command; [bar-benchmark.json](../data/solo-pilot/bar-benchmark.json) stores the exact configuration and source hash.

## Earlier OCR experiment

Source: `2026-10-03T19-05-31Z-8B8FDA`, 68 frames over 14.28 seconds. This small sample does not establish accuracy across matches, skins, or display settings.

## Readings

| Frame | Visible label | Accurate OCR | Result |
|---|---|---|---|
| 000000 | Health 100/100 | 100/100, confidence 1 | Correct |
| 000000 | Shield 44/100 | 44/100, confidence 1 | Correct |
| 000000 | Ammo 24/417 | 24/ 417, confidence 1 | Correct |
| 000527 | Health 77/100 | 77/100, confidence 1 | Correct |
| 000527 | Shield 5/100 | Separate fragments, including 100* | Reject |

Fast OCR missed the health/shield labels and returned low-confidence, incorrect ammo text. Accurate OCR improves these readings, but is not yet a validated live solution.

The source now parses complete health/shield fractions and slash-separated ammo, including thousands separators. It rejects detached maximum values, letters mistaken for digits, and fragmented vital labels. The healing indicator is interpreted as seconds remaining, converted to progress only when a verified consumable duration is known.

## Timing

Standalone processes took roughly 0.75–1.5 seconds for their first accurate OCR request. Repeating a broad HUD crop in one process took 94–157 ms after the first request. A tighter shield crop took 44–494 ms after its first request. These are OCR-only samples on this Mac, with other applications running; they are not full-pipeline benchmarks or a formal p95 acceptance run.

The bar experiment above offers a faster candidate for vitals. Inventory, ammo, and other text still need glyph recognition or asynchronous OCR with explicit snapshot expiry. Do not lower the confidence or freshness thresholds merely to enable input. The complete detector, HUD, and input pipeline still has to pass the planned latency and accuracy checks.

## Saved artifacts

`data/hud-calibration/` contains diagnostic JSON and `calibration-candidate.json`. The candidate includes measured HUD regions and approximate inventory-slot rectangles. It remains `verified: false`; phase, prompt, templates, and item timings still require validation. It has not replaced the app's configuration.

The app's viewport crop was saved separately through the calibration UI and visually checked against recorded images.

## Reproduce OCR inspection

```sh
swiftc -module-cache-path .build/clang-cache tools/training/inspect_hud.swift -o .build/inspect-hud
.build/inspect-hud /path/to/frame.jpg 0 0.82 0.23 0.18 --accurate --repeat=10
```

This inspector reads a local image and outputs text, coordinates, confidence, and timings. It does not capture the screen or send game input. In the restricted development sandbox, Vision could not allocate its image buffers; this read-only check was run with the required native system access.
