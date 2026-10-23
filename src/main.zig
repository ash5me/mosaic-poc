//! Proof of concept: per-frame quadtree mosaic of an animated sprite.
//!
//! Each frame is rebuilt from scratch, but the quadtree keeps per-node state
//! so decisions near a threshold don't flip back and forth. Four variants are
//! rendered and compared:
//!   baseline        - stateless: a node splits when its color range >= 20.
//!   debounce-only   - as baseline, but merges must hold for two frames.
//!   hyst-only       - hysteresis band (split at 24, merge below 16) only.
//!   stabilized      - hysteresis + merge debounce + color smoothing.
//! Splits always apply immediately, and outline (dark) pixels always resolve
//! to 1px tiles, so detail never lags behind the sprite.

const std = @import("std");

const SRC: usize = 64; // source canvas, power of two
const SCALE: usize = 8; // output pixels per source pixel
const OUT: usize = SRC * SCALE;
const LEVELS: usize = 7; // node sizes 64, 32, 16, 8, 4, 2, 1
const MAX_NODES: usize = SRC * SRC; // cells at the finest level
const FRAMES: usize = 24;
const FAR_MARGIN: usize = 6; // source pixels of clearance that count as "far" from the sprite

const Rgb = [3]u8;
const Rgbf = [3]f32;
const Frame = [SRC][SRC]Rgb;
const OutFrame = [OUT][OUT]Rgb;

const Params = struct {
    name: []const u8,
    hysteresis: bool,
    /// An unsplit node splits when its max-channel color range reaches this.
    t_split: f32,
    /// A split node merges only when its color range drops below this.
    t_merge: f32,
    /// Frames a merge must persist before it takes effect (splits are immediate).
    debounce: u8,
    /// Blend factor for tiles that persist from the previous frame (1.0 = snap).
    smooth: f32,
};

const baseline = Params{
    .name = "baseline",
    .hysteresis = false,
    .t_split = 20,
    .t_merge = 20,
    .debounce = 1,
    .smooth = 1.0,
};

const stabilized = Params{
    .name = "stabilized",
    .hysteresis = true,
    .t_split = 24,
    .t_merge = 16,
    .debounce = 2,
    .smooth = 0.5,
};

// Ablations: each stabilization mechanism on its own.
const hysteresis_only = Params{
    .name = "hyst-only",
    .hysteresis = true,
    .t_split = 24,
    .t_merge = 16,
    .debounce = 1,
    .smooth = 1.0,
};

const debounce_only = Params{
    .name = "debounce-only",
    .hysteresis = false,
    .t_split = 20,
    .t_merge = 20,
    .debounce = 2,
    .smooth = 1.0,
};

const INK: Rgb = .{ 28, 22, 34 };
const SUN: Rgb = .{ 255, 214, 120 };
const FAR: Rgb = .{ 110, 96, 140 };
const NEAR: Rgb = .{ 70, 72, 110 };
const GRASS: Rgb = .{ 88, 150, 84 };
const GRASS_DARK: Rgb = .{ 52, 102, 66 };
const SKY = [_]Rgb{
    .{ 33, 40, 84 },
    .{ 52, 64, 120 },
    .{ 84, 96, 150 },
    .{ 128, 124, 176 },
    .{ 176, 140, 180 },
    .{ 232, 166, 150 },
};
const GROUND_Y: usize = 48;

const NONE: u8 = 0;
const HAIR: u8 = 1;
const SKIN: u8 = 2;
const SHIRT: u8 = 3;
const PANTS: u8 = 4;
const SHOES: u8 = 5;
const SPRITE_PAL = [_]Rgb{
    .{ 0, 0, 0 },
    .{ 96, 56, 44 },
    .{ 238, 196, 160 },
    .{ 60, 150, 220 },
    .{ 58, 64, 100 },
    .{ 120, 76, 64 },
};

fn isInk(c: Rgb) bool {
    return @as(u32, c[0]) + @as(u32, c[1]) + @as(u32, c[2]) < 120;
}

// ---------------------------------------------------------------- scene

const far_pts = [_][2]f32{ .{ 0, 40 }, .{ 14, 22 }, .{ 26, 34 }, .{ 38, 18 }, .{ 52, 36 }, .{ 63, 26 } };
const near_pts = [_][2]f32{ .{ 0, 46 }, .{ 12, 36 }, .{ 22, 44 }, .{ 34, 30 }, .{ 46, 44 }, .{ 56, 38 }, .{ 63, 44 } };

fn profile(pts: []const [2]f32, x: f32) f32 {
    var i: usize = 0;
    while (i + 2 < pts.len and x > pts[i + 1][0]) : (i += 1) {}
    const a = pts[i];
    const b = pts[i + 1];
    const t = std.math.clamp((x - a[0]) / (b[0] - a[0]), 0.0, 1.0);
    return a[1] + (b[1] - a[1]) * t;
}

/// Static background: sky bands, sun, two mountain ranges, grass.
fn buildBackground(bg: *Frame) void {
    for (0..SRC) |y| {
        for (0..SRC) |x| {
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            if (y >= GROUND_Y) {
                bg[y][x] = if (y < 56) GRASS else GRASS_DARK;
                continue;
            }
            var c = SKY[@min(y / 8, SKY.len - 1)];
            const dx = fx - 47.0;
            const dy = fy - 15.0;
            const d2 = dx * dx + dy * dy;
            if (d2 <= 30.0) {
                c = SUN;
            } else if (d2 <= 38.0) {
                c = INK;
            }
            if (fy >= profile(&far_pts, fx)) c = FAR;
            const near_top: usize = @intFromFloat(@ceil(profile(&near_pts, fx)));
            if (y == near_top) {
                c = INK;
            } else if (y > near_top) {
                c = NEAR;
            }
            bg[y][x] = c;
        }
    }
}

// ---------------------------------------------------------------- sprite

fn distPt(px: f32, py: f32, ax: f32, ay: f32) f32 {
    const dx = px - ax;
    const dy = py - ay;
    return @sqrt(dx * dx + dy * dy);
}

fn distSeg(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const vx = bx - ax;
    const vy = by - ay;
    const t = std.math.clamp(((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy), 0.0, 1.0);
    return distPt(px, py, ax + vx * t, ay + vy * t);
}

/// Fills `cover` with a palette id per source pixel for walk-cycle frame t.
fn paintCover(t: usize, cover: *[SRC][SRC]u8) void {
    const cx: f32 = 32.0;
    const phase = 2.0 * std.math.pi * @as(f32, @floatFromInt(t)) / @as(f32, @floatFromInt(FRAMES));
    const s = @sin(phase);
    const bob = @round(@abs(s) * 1.5);
    const hip_y = 40.0 - bob;
    const shoulder_y = 31.0 - bob;
    const head_y = 25.0 - bob;
    const feet_y: f32 = 46.5;
    const hip_l = cx - 1.5;
    const hip_r = cx + 1.5;
    const foot_l = hip_l + 3.0 * s;
    const foot_r = hip_r - 3.0 * s;
    const sh_l = cx - 3.5;
    const sh_r = cx + 3.5;
    const hand_l = sh_l - 2.0 * s;
    const hand_r = sh_r + 2.0 * s;
    const hand_y = shoulder_y + 7.0;

    for (0..SRC) |y| {
        for (0..SRC) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            var id: u8 = NONE;
            if (distSeg(px, py, hip_l, hip_y, foot_l, feet_y) < 1.3 or
                distSeg(px, py, hip_r, hip_y, foot_r, feet_y) < 1.3) id = PANTS;
            if (distPt(px, py, foot_l, feet_y) < 1.6 or
                distPt(px, py, foot_r, feet_y) < 1.6) id = SHOES;
            if (px >= cx - 4.0 and px < cx + 4.0 and py >= shoulder_y and py < hip_y + 1.0) id = SHIRT;
            if (distSeg(px, py, sh_l, shoulder_y + 1.0, hand_l, hand_y) < 1.1 or
                distSeg(px, py, sh_r, shoulder_y + 1.0, hand_r, hand_y) < 1.1) id = SHIRT;
            if (distPt(px, py, hand_l, hand_y) < 1.1 or
                distPt(px, py, hand_r, hand_y) < 1.1) id = SKIN;
            if (distPt(px, py, cx, head_y) < 4.5) {
                id = if (py < head_y - 1.0) HAIR else SKIN;
            }
            cover[y][x] = id;
        }
    }
}

fn isEdge(cover: *const [SRC][SRC]u8, x: usize, y: usize) bool {
    if (x == 0 or y == 0 or x == SRC - 1 or y == SRC - 1) return true;
    return cover[y - 1][x] == NONE or cover[y + 1][x] == NONE or
        cover[y][x - 1] == NONE or cover[y][x + 1] == NONE;
}

/// Composites the sprite over the background, with a 1px ink outline.
fn renderSprite(bg: *const Frame, t: usize, out: *Frame) void {
    var cover: [SRC][SRC]u8 = undefined;
    paintCover(t, &cover);
    for (0..SRC) |y| {
        for (0..SRC) |x| {
            const id = cover[y][x];
            out[y][x] = if (id == NONE)
                bg[y][x]
            else if (isEdge(&cover, x, y))
                INK
            else
                SPRITE_PAL[id];
        }
    }
}

// ---------------------------------------------------------------- quadtree

const Measure = struct {
    mean: Rgbf,
    /// Largest max-min spread over the three channels within the node.
    range: f32,
    ink: bool,
};

fn measure(src: *const Frame, x0: usize, y0: usize, size: usize) Measure {
    var sum: Rgbf = .{ 0, 0, 0 };
    var lo: Rgb = .{ 255, 255, 255 };
    var hi: Rgb = .{ 0, 0, 0 };
    var ink = false;
    for (y0..y0 + size) |y| {
        for (x0..x0 + size) |x| {
            const c = src[y][x];
            for (0..3) |k| {
                sum[k] += @as(f32, @floatFromInt(c[k]));
                lo[k] = @min(lo[k], c[k]);
                hi[k] = @max(hi[k], c[k]);
            }
            if (isInk(c)) ink = true;
        }
    }
    var range: f32 = 0;
    for (0..3) |k| {
        range = @max(range, @as(f32, @floatFromInt(hi[k] - lo[k])));
    }
    const n: f32 = @floatFromInt(size * size);
    return .{
        .mean = .{ sum[0] / n, sum[1] / n, sum[2] / n },
        .range = range,
        .ink = ink,
    };
}

/// True if any pixel within `margin` of the region differs from the background.
fn isNearSprite(src: *const Frame, bg: *const Frame, x0: usize, y0: usize, size: usize, margin: usize) bool {
    const xa = x0 -| margin;
    const ya = y0 -| margin;
    const xb = @min(SRC, x0 + size + margin);
    const yb = @min(SRC, y0 + size + margin);
    for (ya..yb) |y| {
        for (xa..xb) |x| {
            if (!std.mem.eql(u8, &src[y][x], &bg[y][x])) return true;
        }
    }
    return false;
}

const Tree = struct {
    /// split[L][idx]: node idx at level L is currently subdivided.
    split: [LEVELS][MAX_NODES]bool,
    /// pend[L][idx]: consecutive frames a changed decision has been pending.
    pend: [LEVELS][MAX_NODES]u8,
    /// color[L][idx]: last emitted color, used for smoothing.
    color: [LEVELS][MAX_NODES]Rgbf,
    /// leaf[slot][L][idx]: node was emitted as a tile in frame (slot).
    /// Three slots rotate so churn and blink can be counted.
    leaf: [3][LEVELS][MAX_NODES]bool,
};

const Stats = struct {
    /// Tiles that appeared or disappeared since the previous frame.
    churn: u32 = 0,
    /// Subset of churn with no sprite pixel within `FAR_MARGIN` source pixels.
    /// Background that the sprite never touches should contribute zero here.
    far_churn: u32 = 0,
    /// Tiles present in frames t-2 and t but missing in t-1 (one-frame holes).
    blink: u32 = 0,
};

const Ctx = struct {
    tree: *Tree,
    p: Params,
    src: *const Frame,
    bg: *const Frame,
    out: *OutFrame,
    slot: usize,
    prev_slot: usize,
    stats: *Stats,
};

fn visit(ctx: *Ctx, L: usize, r: usize, c: usize) void {
    const n = @as(usize, 1) << @intCast(L);
    const size = SRC / n;
    const idx = r * n + c;
    const m = measure(ctx.src, c * size, r * size, size);
    const was_split = ctx.tree.split[L][idx];
    const pend = &ctx.tree.pend[L][idx];
    var split = was_split;

    if (L == LEVELS - 1) {
        split = false;
        pend.* = 0;
    } else if (m.ink) {
        // Outlines resolve to 1px tiles immediately so they never blur.
        split = true;
        pend.* = 0;
    } else {
        const want = if (ctx.p.hysteresis)
            (m.range >= (if (was_split) ctx.p.t_merge else ctx.p.t_split))
        else
            (m.range >= ctx.p.t_split);
        if (want and !was_split) {
            // Adding detail is immediate so edges never blur. Debouncing splits
            // would delay every level of the tree by a frame or two.
            split = true;
            pend.* = 0;
        } else if (want == was_split) {
            pend.* = 0;
        } else {
            // Removing detail must hold for `debounce` frames before it takes effect.
            pend.* += 1;
            if (pend.* >= ctx.p.debounce) {
                split = false;
                pend.* = 0;
            }
        }
    }
    ctx.tree.split[L][idx] = split;

    if (split) {
        for (0..2) |dr| {
            for (0..2) |dc| visit(ctx, L + 1, 2 * r + dr, 2 * c + dc);
        }
    } else {
        emitLeaf(ctx, L, r, c, idx, size, m);
        clearBelow(ctx.tree, L, r, c);
    }
}

fn emitLeaf(ctx: *Ctx, L: usize, r: usize, c: usize, idx: usize, size: usize, m: Measure) void {
    const persisted = ctx.tree.leaf[ctx.prev_slot][L][idx];
    ctx.tree.leaf[ctx.slot][L][idx] = true;

    var col = m.mean;
    if (persisted and !m.ink and ctx.p.smooth < 1.0) {
        const old = ctx.tree.color[L][idx];
        for (0..3) |k| {
            col[k] = old[k] + (m.mean[k] - old[k]) * ctx.p.smooth;
        }
    }
    ctx.tree.color[L][idx] = col;
    fillTile(ctx.out, c * size, r * size, size, .{ toByte(col[0]), toByte(col[1]), toByte(col[2]) });
}

/// A merged node's descendants start fresh the next time they are split.
fn clearBelow(state: *Tree, L: usize, r: usize, c: usize) void {
    if (L + 1 >= LEVELS) return;
    const n = @as(usize, 1) << @intCast(L + 1);
    for (0..2) |dr| {
        for (0..2) |dc| {
            const cr = 2 * r + dr;
            const cc = 2 * c + dc;
            state.split[L + 1][cr * n + cc] = false;
            state.pend[L + 1][cr * n + cc] = 0;
            clearBelow(state, L + 1, cr, cc);
        }
    }
}

fn fillTile(out: *OutFrame, x0: usize, y0: usize, size: usize, c: Rgb) void {
    for ((y0 * SCALE)..((y0 + size) * SCALE)) |y| {
        for ((x0 * SCALE)..((x0 + size) * SCALE)) |x| out[y][x] = c;
    }
}

fn toByte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0.0, 255.0));
}

/// Renders one frame into `out` and updates the frame-to-frame statistics.
fn stepFrame(
    state: *Tree,
    p: Params,
    src: *const Frame,
    bg: *const Frame,
    out: *OutFrame,
    t: usize,
    stats: *Stats,
) void {
    const slot = t % 3;
    for (0..LEVELS) |L| @memset(&state.leaf[slot][L], false);

    var ctx = Ctx{
        .tree = state,
        .p = p,
        .src = src,
        .bg = bg,
        .out = out,
        .slot = slot,
        .prev_slot = (t + 2) % 3,
        .stats = stats,
    };
    visit(&ctx, 0, 0, 0);

    // Sanity check: the emitted tiles must cover the canvas exactly once.
    var covered: usize = 0;
    for (0..LEVELS) |L| {
        const n = @as(usize, 1) << @intCast(L);
        for (0..n * n) |idx| {
            if (state.leaf[slot][L][idx]) covered += (SRC / n) * (SRC / n);
        }
    }
    std.debug.assert(covered == SRC * SRC);

    if (t >= 2) frameStats(state, t, src, bg, stats);
}

fn frameStats(state: *const Tree, t: usize, src: *const Frame, bg: *const Frame, stats: *Stats) void {
    const cur = t % 3;
    const prev = (t + 2) % 3;
    const prev2 = (t + 1) % 3;
    for (0..LEVELS) |L| {
        const n = @as(usize, 1) << @intCast(L);
        const size = SRC / n;
        for (0..n * n) |idx| {
            const a = state.leaf[cur][L][idx];
            const b = state.leaf[prev][L][idx];
            const d = state.leaf[prev2][L][idx];
            if (a != b) {
                stats.churn += 1;
                if (!isNearSprite(src, bg, (idx % n) * size, (idx / n) * size, size, FAR_MARGIN)) {
                    stats.far_churn += 1;
                }
            }
            if (a and d and !b) stats.blink += 1;
        }
    }
}

// ---------------------------------------------------------------- output

var tree: Tree = undefined;
var out_img: OutFrame = undefined;

fn writePpm(io: std.Io, dir: std.Io.Dir, name: []const u8, img: *const OutFrame) !void {
    var file = try dir.createFile(io, name, .{});
    defer file.close(io);
    var hdr_buf: [64]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "P6\n{d} {d}\n255\n", .{ OUT, OUT });
    try file.writeStreamingAll(io, hdr);
    try file.writeStreamingAll(io, std.mem.asBytes(img));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var bg: Frame = undefined;
    buildBackground(&bg);
    var src: Frame = undefined;

    var out_root = try std.Io.Dir.cwd().createDirPathOpen(io, "out", .{});
    defer out_root.close(io);

    for ([_]Params{ baseline, debounce_only, hysteresis_only, stabilized }) |p| {
        var dir = try out_root.createDirPathOpen(io, p.name, .{});
        defer dir.close(io);

        tree = std.mem.zeroes(Tree);
        var stats = Stats{};
        var name_buf: [32]u8 = undefined;
        for (0..FRAMES) |t| {
            renderSprite(&bg, t, &src);
            stepFrame(&tree, p, &src, &bg, &out_img, t, &stats);
            const name = try std.fmt.bufPrint(&name_buf, "frame_{d:0>2}.ppm", .{t});
            try writePpm(io, dir, name, &out_img);
        }

        const n: f32 = @floatFromInt(FRAMES - 2);
        std.debug.print(
            "{s:<10} tile churn/frame {d:>6.1}   far churn/frame {d:>5.1}   blinks/frame {d:>5.1}\n",
            .{
                p.name,
                @as(f32, @floatFromInt(stats.churn)) / n,
                @as(f32, @floatFromInt(stats.far_churn)) / n,
                @as(f32, @floatFromInt(stats.blink)) / n,
            },
        );
    }
}

// ---------------------------------------------------------------- tests

test "unchanging input settles into zero churn" {
    var bg: Frame = undefined;
    buildBackground(&bg);
    var src: Frame = undefined;
    renderSprite(&bg, 5, &src);

    for ([_]Params{ baseline, stabilized }) |p| {
        tree = std.mem.zeroes(Tree);
        var stats = Stats{};
        for (0..6) |t| {
            if (t == 4) stats = Stats{};
            stepFrame(&tree, p, &src, &bg, &out_img, t, &stats);
        }
        try std.testing.expectEqual(@as(u32, 0), stats.churn);
        try std.testing.expectEqual(@as(u32, 0), stats.blink);
    }
}

test "flat sky tile comes out as its exact band color" {
    var bg: Frame = undefined;
    buildBackground(&bg);
    var src: Frame = undefined;
    renderSprite(&bg, 3, &src);
    tree = std.mem.zeroes(Tree);
    var stats = Stats{};
    stepFrame(&tree, stabilized, &src, &bg, &out_img, 0, &stats);
    // The top-left corner is plain sky, so its tile must be the exact band color.
    try std.testing.expectEqual(SKY[0], out_img[0][0]);
}

/// A flat field with one 8x8 block whose color range is `r`, inside a
/// surrounding field with strong contrast so the ancestors always split.
fn fillBandTestFrame(src: *Frame, r: u8) void {
    for (0..SRC) |y| {
        for (0..SRC) |x| src[y][x] = .{ 100, 100, 100 };
    }
    for (0..8) |y| {
        for (4..8) |x| src[y][x] = .{ 100 + r, 100 + r, 100 + r };
    }
    for (0..8) |y| {
        for (8..16) |x| {
            const v: u8 = if (x % 2 == 0) 100 else 220;
            src[y][x] = .{ v, v, v };
        }
    }
}

test "hysteresis stops a node from toggling when its range sits in the band" {
    var bg: Frame = undefined;
    buildBackground(&bg);
    var src: Frame = undefined;
    // 26 pushes the block above t_split; then it hovers between 18 and 22,
    // which is below t_split (24) but above t_merge (16) for stabilized and
    // straddles t_split (20) for baseline.
    const ranges = [_]u8{ 26, 22, 18, 22, 18, 22, 18, 22 };

    for ([_]Params{ baseline, stabilized }) |p| {
        tree = std.mem.zeroes(Tree);
        var stats = Stats{};
        var toggles: u32 = 0;
        var prev_split = false;
        for (ranges, 0..) |r, t| {
            fillBandTestFrame(&src, r);
            stepFrame(&tree, p, &src, &bg, &out_img, t, &stats);
            const now = tree.split[3][0];
            if (t > 0 and now != prev_split) toggles += 1;
            prev_split = now;
        }
        if (p.hysteresis) {
            try std.testing.expectEqual(@as(u32, 0), toggles);
        } else {
            try std.testing.expect(toggles >= 4);
        }
    }
}
