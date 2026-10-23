# Quadtree mosaic proof of concept (Zig 0.17)

A procedurally animated sprite rendered as a per-frame quadtree mosaic, with
the quadtree stabilized against flicker. The program renders four variants and
reports how much the tile layout changes between frames.

## Requirements

- Zig 0.17.0
- Python 3 with Pillow, only for the optional GIF step

## Commands

Run from the project root.

```
zig build test                                              # unit tests
zig build run                                               # writes out/<variant>/frame_NN.ppm and prints stats
python3 tools/make_gif.py out comparison.gif baseline stabilized
```

Frames are plain PPM (P6), so no image library is needed to write them.

## Variants

| name           | hysteresis | merge debounce | color smoothing |
|----------------|------------|----------------|-----------------|
| baseline       | no         | no             | no              |
| debounce-only  | no         | 2 frames       | no              |
| hyst-only      | yes        | no             | no              |
| stabilized     | yes        | 2 frames       | 0.5             |

- **Hysteresis:** an unsplit node splits when its color range reaches 24. A split node
  merges only when the range drops below 16.
- **Merge debounce:** a merge takes effect only after it has held for two frames.
  Splits always apply immediately.
- **Color smoothing:** a tile that persists from the previous frame blends its color
  toward the new mean. Tiles that are new, or that change structure, snap to the mean.
- Outline pixels always resolve to 1px tiles immediately, and their colors are never smoothed.

## Statistics

- **tile churn:** tiles that appeared or disappeared since the previous frame.
- **far churn:** churn in regions with no sprite pixel within 6 source pixels. Background the
  sprite never touches should contribute zero.
- **blinks:** tiles present in frames t-2 and t but missing in t-1. These are the one-frame
  holes that read as flicker.

Results from `zig build run` (averages per frame over 22 frames):

| variant        | tile churn | far churn | blinks |
|----------------|-----------:|----------:|-------:|
| baseline       |       43.4 |       0.0 |    4.1 |
| debounce-only  |       33.7 |       0.0 |    0.0 |
| hyst-only      |       43.4 |       0.0 |    4.1 |
| stabilized     |       33.7 |       0.0 |    0.0 |

## What the results show

- The merge debounce removes all one-frame blinks and cuts total churn by about 22%.
  Hysteresis alone changes nothing in this scene. Its mechanism is covered by a unit test
  (`hysteresis stops a node from toggling when its range sits in the band`), but this scene
  is flat-colored, so almost every color boundary has a range well outside the 16–24 band.
  Expect hysteresis to matter with soft shading or anti-aliased sprites.
- Far background never changes, so the flicker is confined to the moving edge.
- About 34 tile changes per frame remain near the sprite. These come from the moving edge
  crossing quadtree boundaries, which is a real structural change. Stabilization makes them
  steadier, but it can't remove them without a shared layout.

## Design notes

- Splits are immediate. An early version debounced splits as well, and that cascaded down the
  tree, roughly two frames per level. It also made the very first frame come out blurred.
- Detection is per frame and top-down. A node is only visited if its parent is split, so
  per-node state (split flag, pending count, color) is stored in flat arrays indexed by level
  and cell. A merged node clears the state of its descendants.
- Each frame, the emitted tiles are checked to cover the canvas exactly once (`std.debug.assert`).

## Not included

- **Vulkan:** not implemented. The renderer writes one RGB buffer (`OutFrame`) per frame, so a
  Vulkan backend can upload it as a texture, or draw the tiles as instanced quads. I haven't
  built or tested a Vulkan path, since this environment has no GPU or Vulkan driver.
- **Real sprites:** the character is drawn procedurally from primitives. Loading sprite sheets
  would only change how `paintCover` and the background are produced.
