# Print Prep — SketchUp extension (v0.1)

Checks a house model before 3D printing:

- **Solid check.** Lists every group/component that isn't a closed solid. These are the parts that make Subtract/Intersect/Split fail.
- **Scale vs. printer bed.** Shows the printed size at 1:N, how many pieces it needs, and the largest scale that fits in one piece.
- **Thin walls.** Shoots rays through each part to find its thinnest wall, then flags parts that end up below the minimum wall thickness at the chosen scale.
- **Show / Show spot.** Zooms to a problem part, or opens it and selects the exact face where the thinnest wall is.

## Install
SketchUp Pro → **Extensions → Extension Manager → Install Extension…** → pick `print_prep.rbz`.
Then open it from **Extensions → Print Prep…**

## Use
1. Pick the printer (or type the bed size), the scale, and the minimum wall.
   0.8 mm is a safe default for FDM with a 0.4 mm nozzle; resin printers can go lower.
2. Click **Analyze** (whole model or just the selection).
3. Change the scale freely afterwards: everything recalculates without re-analyzing.

## Limitations (v0.1)
- Read-only: it never changes the model.
- "Pieces" is a straight-grid estimate; real cuts can be smarter.
- Thickness is measured from up to 800 faces per part (marked `*` when sampled), so a tiny thin detail on a huge part can be missed.
- Faces sitting directly in the model (not inside a group) are only counted, not checked.
- Hidden parts and parts on hidden tags are skipped.
- Use Solid Inspector² to actually fix non-solid parts.

## Build the .rbz
From the repo root:
```
zip -r -X print_prep.rbz print_prep.rb print_prep/
```
