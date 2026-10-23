# Lighthouse mosaic (Zig 0.17 + raylib 6.0)

A procedurally drawn lighthouse at dusk, shown as a quadtree mosaic. Flat areas
(sky, calm sea) become large tiles, and detail (waves, rocks, the lighthouse
edges, dithered colour changes) breaks into small ones. Outline pixels always
stay 1px.

This is a Zig port of `lighthouse_mosaic.py`. The illustration and the mosaic
rules match; the star placement and the rock texture use a different random
generator, so they differ in detail.

## Requirements

- Zig 0.17.0
- A graphics driver with OpenGL 3.3 (any recent GPU driver provides this).

raylib 6.0 is vendored in `vendor/raylib` (its LICENSE is included), so you don't
need to install raylib separately.

### Windows

Nothing needs installing. OpenGL, GDI, and the Win32 API come with Windows, and
Zig ships the MinGW headers and libraries it needs. Install Zig 0.17.0 and run the
commands below from a terminal in the project folder.

### Linux

Install the X11 and OpenGL development headers. On Debian or Ubuntu:

```
sudo apt install libgl-dev libx11-dev libxrandr-dev libxinerama-dev libxi-dev libxcursor-dev
```

Software rendering also works (`LIBGL_ALWAYS_SOFTWARE=1`), which is how the Linux
build was tested headless.

## Build and run

```
zig build test          # illustration and mosaic tests; no window needed
zig build run           # open the window
zig build               # build zig-out/bin/lighthouse
```

After `zig build`, you can run the binary directly with flags:

```
./zig-out/bin/lighthouse --threshold 30
./zig-out/bin/lighthouse --threshold 60 --snapshot preview.png   # render, save, exit
```

## Controls

| key        | action                                           |
|------------|--------------------------------------------------|
| UP / DOWN  | raise / lower the split threshold by 2           |
| R          | reset the threshold to 40                        |
| SPACE      | toggle between the mosaic and the source drawing |
| S          | save `lighthouse_t<threshold>.png` in the working directory |
| ESC        | quit                                             |

The bar at the bottom of the window shows the current threshold and tile count. The
terminal prints a line each time the threshold changes.

## Flags

- `--threshold N`: start with split threshold N (default 40).
- `--snapshot FILE`: render two frames, write the window to FILE, and exit.

## How the mosaic works

The illustration is 256×256 pixels, shown at 4× in a 1024×1024 window, so each
illustration pixel becomes a 4×4 block on screen.

The quadtree starts with the whole image as one tile. A node stays one tile if
its colours are close, meaning the largest per-channel spread is below the
threshold, and it contains no outline pixel. Otherwise it splits into four
quadrants, down to single pixels. Outline pixels always reach 1px tiles.

The threshold is the only tuning knob. Lower values give more, smaller tiles;
higher values give bigger blocks. At the default of 40 the image has about 22,000
tiles, ranging from single pixels on the detail up to large blocks in the sky.

## Layout

```
build.zig              build graph: raylib C sources, Zig bindings, app, tests
build.zig.zon          package manifest (Zig 0.17.0)
src/art.zig            illustration and quadtree mosaic (plain Zig, tested)
src/main.zig           raylib window, controls, screenshots, flags
vendor/raylib/         raylib 6.0 C sources, headers, and bundled GLFW/miniaudio
```

## Notes on the build

raylib 6.0's own `build.zig` requires Zig 0.16, so this project compiles its C
sources directly, using the same source list and flags as raylib's Makefile
for desktop (GLFW with X11 on Linux or Win32 on Windows, OpenGL 3.3). The Zig bindings are generated from
`raylib.h`.

Two raylib details matter for the code:

- raylib batches draw calls until `EndDrawing`, so the screenshot helper calls
  `rlDrawRenderBatchActive` before reading the framebuffer. Without it the saved
  image is black.
- `TakeScreenshot` prepends the working directory to the file name, so the helper
  uses `LoadImageFromScreen` and `ExportImage` instead, which take the path as given.

## Platform support

- **Linux (X11):** built, run, and tested, including the keyboard controls and
  screenshots.
- **Windows (x86-64):** the executable cross-compiles from Linux with
  `zig build -Dtarget=x86_64-windows-gnu`, producing a 64-bit PE that imports
  opengl32, gdi32, and winmm. It has not been run on Windows.
- **macOS:** not supported. The build stops with a message naming the supported
  systems.
