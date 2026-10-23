//! The lighthouse-at-dusk illustration and its quadtree mosaic, ported from
//! lighthouse_mosaic.py. Plain Zig with no graphics dependency, so the tests
//! run without a window.
//!
//! The starfield and rock texture use a different random generator and a
//! different blur than the Python version, so their exact placement differs.
//! Composition, palette and the mosaic rules match.

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

pub const W: usize = 256;
pub const H: usize = 256;
pub const SCALE: usize = 4;
pub const OUT_W: usize = W * SCALE;
pub const OUT_H: usize = H * SCALE;
pub const HORIZON: usize = 150;
/// Node sizes are 256, 128, ..., 1; a tile of size s is counted at index log2(s).
pub const LEVELS: usize = 9;
pub const DEFAULT_THRESHOLD: f32 = 40;

pub const Rgbf = [3]f32;

const INK: Rgbf = .{ 20, 14, 30 };
const SKY = [_]Rgbf{
    .{ 14, 12, 40 },   .{ 26, 20, 66 },   .{ 44, 32, 94 },    .{ 68, 42, 118 }, .{ 98, 52, 130 },
    .{ 134, 66, 134 }, .{ 178, 96, 132 }, .{ 224, 134, 124 }, .{ 252, 184, 138 },
};
const SEA = [_]Rgbf{
    .{ 20, 40, 84 }, .{ 26, 58, 108 }, .{ 34, 80, 128 }, .{ 52, 106, 146 }, .{ 84, 134, 162 }, .{ 138, 172, 186 },
};
const ROCK = [_]Rgbf{
    .{ 36, 26, 46 }, .{ 52, 40, 64 }, .{ 72, 58, 82 }, .{ 96, 80, 100 }, .{ 124, 106, 116 }, .{ 156, 138, 136 },
};
const CLOUD_LIGHT: Rgbf = .{ 116, 66, 142 };
const CLOUD_DARK: Rgbf = .{ 78, 42, 114 };
const MOON: Rgbf = .{ 255, 240, 200 };
const MOON_SHADE: Rgbf = .{ 226, 206, 170 };
const HALO: Rgbf = .{ 150, 92, 150 };
const STAR_WARM: Rgbf = .{ 255, 250, 235 };
const STAR_COOL: Rgbf = .{ 170, 190, 255 };
const REFL_A: Rgbf = .{ 150, 180, 196 };
const REFL_B: Rgbf = .{ 226, 218, 196 };
const WHITE_LIT: Rgbf = .{ 250, 246, 236 };
const WHITE_SHADE: Rgbf = .{ 190, 184, 198 };
const RED_LIT: Rgbf = .{ 226, 84, 72 };
const RED_SHADE: Rgbf = .{ 150, 42, 62 };
const ROOF_LIT: Rgbf = .{ 92, 62, 100 };
const ROOF_SHADE: Rgbf = .{ 60, 40, 70 };
const GLASS: Rgbf = .{ 255, 226, 120 };
const MULLION: Rgbf = .{ 60, 40, 60 };
const METAL: Rgbf = .{ 40, 36, 52 };
const DOOR: Rgbf = .{ 50, 36, 50 };
const BEAM: Rgbf = .{ 255, 236, 170 };
const GLOW: Rgbf = .{ 255, 236, 160 };
const FOAM: Rgbf = .{ 232, 240, 242 };

const MOON_X: f32 = 58;
const MOON_Y: f32 = 52;

const BEAM_POLY = [_][2]f32{ .{ 174, 98 }, .{ 0, 40 }, .{ 0, 166 } };
const TOWER_POLY = [_][2]f32{ .{ 166, 206 }, .{ 198, 206 }, .{ 192, 112 }, .{ 172, 112 } };
const ROOF_POLY = [_][2]f32{ .{ 170, 97 }, .{ 194, 97 }, .{ 182, 82 } };
const ROCK_A = [_][2]f32{ .{ 128, 256 }, .{ 132, 224 }, .{ 150, 210 }, .{ 170, 204 }, .{ 198, 206 }, .{ 222, 198 }, .{ 256, 206 }, .{ 256, 256 } };
const ROCK_B = [_][2]f32{ .{ 0, 240 }, .{ 30, 226 }, .{ 58, 230 }, .{ 84, 242 }, .{ 108, 256 }, .{ 0, 256 } };

const BAYER = [4][4]f32{
    .{ 0, 8, 2, 10 },
    .{ 12, 4, 14, 6 },
    .{ 3, 11, 1, 9 },
    .{ 15, 7, 13, 5 },
};

fn tof(v: usize) f32 {
    return @floatFromInt(v);
}

fn dist(ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = ax - bx;
    const dy = ay - by;
    return @sqrt(dx * dx + dy * dy);
}

fn shift(v: usize, d: i32) usize {
    return @intCast(@as(i32, @intCast(v)) + d);
}

fn inRect(x: usize, y: usize, x0: usize, y0: usize, x1: usize, y1: usize) bool {
    return x >= x0 and x <= x1 and y >= y0 and y <= y1;
}

/// Even-odd polygon test at integer pixel coordinates.
fn inPolygon(poly: []const [2]f32, x: usize, y: usize) bool {
    const px = tof(x);
    const py = tof(y);
    var inside = false;
    var j = poly.len - 1;
    for (poly, 0..) |p, i| {
        const q = poly[j];
        if ((p[1] > py) != (q[1] > py)) {
            const cross = (q[0] - p[0]) * (py - p[1]) / (q[1] - p[1]) + p[0];
            if (px < cross) inside = !inside;
        }
        j = i;
    }
    return inside;
}

/// Posterize a fractional palette index, dithering between neighbouring colours
/// with a 4x4 Bayer matrix.
fn posterize(f: f32, x: usize, y: usize, palette: []const Rgbf) Rgbf {
    const dither = BAYER[y % 4][x % 4] / 16.0;
    const top: f32 = tof(palette.len - 1);
    const i: usize = @intFromFloat(math.clamp(@floor(f + dither), 0, top));
    return palette[i];
}

const Canvas = struct {
    rgb: []Rgbf,
    ink: []bool,

    fn set(self: Canvas, x: usize, y: usize, c: Rgbf) void {
        self.rgb[y * W + x] = c;
    }

    fn blend(self: Canvas, x: usize, y: usize, c: Rgbf, a: f32) void {
        const p = &self.rgb[y * W + x];
        for (0..3) |k| p[k] = p[k] * (1 - a) + c[k] * a;
    }

    fn setInk(self: Canvas, x: usize, y: usize) void {
        self.rgb[y * W + x] = INK;
        self.ink[y * W + x] = true;
    }
};

fn paintSky(cv: Canvas) void {
    const sky_top: f32 = tof(SKY.len - 1);
    for (0..H) |y| {
        const t = math.clamp(tof(y) / tof(HORIZON), 0, 1);
        for (0..W) |x| cv.set(x, y, posterize(t * sky_top, x, y, &SKY));
    }
}

fn paintClouds(cv: Canvas) void {
    for (0..H) |y| {
        if (y <= 34 or y >= 96) continue;
        for (0..W) |x| {
            const fx = tof(x);
            const fy = tof(y);
            const c = @sin(fx * 0.045 + 1.3) * @sin(fy * 0.21 + 0.4) + 0.5 * @sin(fx * 0.11 - fy * 0.37);
            if (c > 0.55) {
                cv.set(x, y, CLOUD_DARK);
            } else if (c > 0.2) {
                cv.set(x, y, CLOUD_LIGHT);
            }
        }
    }
}

fn paintStars(cv: Canvas, rnd: std.Random) void {
    for (0..90) |_| {
        const x = rnd.intRangeLessThan(usize, 0, W);
        const y = rnd.intRangeLessThan(usize, 0, 112);
        if (dist(tof(x), tof(y), MOON_X, MOON_Y) < 26) continue;
        cv.set(x, y, if (rnd.float(f32) < 0.6) STAR_WARM else STAR_COOL);
    }
    const glints = [_][2]usize{ .{ 12, 20 }, .{ 96, 12 }, .{ 150, 30 }, .{ 226, 16 }, .{ 238, 70 }, .{ 30, 96 }, .{ 210, 56 } };
    const around = [_][2]i32{ .{ -2, 0 }, .{ 2, 0 }, .{ 0, -2 }, .{ 0, 2 }, .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
    for (glints) |g| {
        cv.set(g[0], g[1], STAR_WARM);
        for (around) |d| cv.set(shift(g[0], d[0]), shift(g[1], d[1]), STAR_COOL);
    }
}

fn paintMoon(cv: Canvas) void {
    const craters = [_][3]f32{ .{ 52, 46, 4 }, .{ 65, 58, 3 }, .{ 53, 63, 2.5 } };
    for (0..H) |y| {
        for (0..W) |x| {
            const d = dist(tof(x), tof(y), MOON_X, MOON_Y);
            if (d <= 16) {
                cv.set(x, y, MOON);
            } else if (d <= 21) {
                cv.set(x, y, HALO);
            }
            for (craters) |c| {
                if (dist(tof(x), tof(y), c[0], c[1]) <= c[2]) cv.set(x, y, MOON_SHADE);
            }
        }
    }
}

fn paintSea(cv: Canvas) void {
    const sea_top: f32 = tof(SEA.len - 1);
    for (HORIZON..H) |y| {
        const fy = tof(y);
        const sea_t = math.clamp((fy - tof(HORIZON)) / tof(H - HORIZON), 0, 1);
        for (0..W) |x| {
            const fx = tof(x);
            const ripple = 0.7 * @sin((fy - tof(HORIZON)) * 1.3 + 1.2 * @sin(fx * 0.07));
            const f = math.clamp(0.2 + sea_t * 3.2 + ripple, 0, sea_top);
            cv.set(x, y, posterize(f, x, y, &SEA));
        }
    }
}

/// Shimmering stripes of moonlight on the water below the moon.
fn paintReflection(cv: Canvas) void {
    for (HORIZON..H) |y| {
        const depth = tof(y) - tof(HORIZON);
        if (depth >= 70) continue;
        const spread = 3 + 0.07 * depth;
        for (0..W) |x| {
            const u = (tof(x) - MOON_X) / spread;
            if (@exp(-u * u) <= 0.5) continue;
            cv.set(x, y, if (y % 3 == 0) REFL_B else REFL_A);
        }
    }
}

fn paintBeam(cv: Canvas) void {
    for (0..H) |y| {
        for (0..W) |x| {
            if (!inPolygon(&BEAM_POLY, x, y)) continue;
            const fade = math.pow(f32, math.clamp(tof(x) / 174, 0, 1), 1.3);
            cv.blend(x, y, BEAM, 0.30 * fade);
        }
    }
}

fn paintGlow(cv: Canvas) void {
    for (0..H) |y| {
        for (0..W) |x| {
            if (inRect(x, y, 174, 96, 190, 107)) continue;
            const d = dist(tof(x), tof(y), 182, 103);
            if (d >= 16) continue;
            cv.blend(x, y, GLOW, 0.5 * (1 - d / 16));
        }
    }
}

fn fillRockMask(rocks: []bool) void {
    for (0..H) |y| {
        for (0..W) |x| {
            rocks[y * W + x] = inPolygon(&ROCK_A, x, y) or inPolygon(&ROCK_B, x, y);
        }
    }
}

fn paintRocks(cv: Canvas, rocks: []const bool, noise: []const f32) void {
    const rock_top: f32 = tof(ROCK.len - 1);
    for (0..H) |y| {
        const light = math.clamp(1 - (tof(y) - 200) / 56, 0, 1);
        for (0..W) |x| {
            const i = y * W + x;
            if (!rocks[i]) continue;
            const f = math.clamp(0.5 + 2.6 * noise[i] + 1.5 * light, 0, rock_top);
            cv.set(x, y, posterize(f, x, y, &ROCK));
        }
    }
}

/// Broken white line where the sea meets the rocks.
fn paintFoam(cv: Canvas, rocks: []const bool) void {
    for (HORIZON..H) |y| {
        for (0..W) |x| {
            if (rocks[y * W + x] or (x + y) % 3 == 0) continue;
            if (!nearMask(rocks, x, y, 2)) continue;
            cv.set(x, y, FOAM);
        }
    }
}

/// True if any mask pixel lies within `radius` of (x, y) (square neighbourhood).
fn nearMask(mask: []const bool, x: usize, y: usize, radius: usize) bool {
    const r: i32 = @intCast(radius);
    const xi: i32 = @intCast(x);
    const yi: i32 = @intCast(y);
    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            const nx = xi + dx;
            const ny = yi + dy;
            if (nx < 0 or ny < 0 or nx >= W or ny >= H) continue;
            if (mask[@as(usize, @intCast(ny)) * W + @as(usize, @intCast(nx))]) return true;
        }
    }
    return false;
}

/// Paints the lighthouse and records its silhouette for the outline pass.
fn paintLighthouse(cv: Canvas, sil: []bool) void {
    for (0..H) |y| {
        for (0..W) |x| {
            const i = y * W + x;
            if (inPolygon(&TOWER_POLY, x, y)) {
                sil[i] = true;
                const band = ((206 - y) / 12) % 2;
                const lit = x < 182;
                cv.set(x, y, if (band == 0)
                    (if (lit) WHITE_LIT else WHITE_SHADE)
                else
                    (if (lit) RED_LIT else RED_SHADE));
            }
            if (inRect(x, y, 179, 192, 185, 206)) cv.set(x, y, DOOR);
            if (inRect(x, y, 180, 150, 184, 156)) cv.set(x, y, GLASS);
            if (inRect(x, y, 168, 108, 196, 111)) {
                sil[i] = true;
                cv.set(x, y, METAL);
            }
            if (inRect(x, y, 174, 96, 190, 107)) {
                sil[i] = true;
                cv.set(x, y, GLASS);
                if (x == 178 or x == 182 or x == 186) cv.set(x, y, MULLION);
                if (y == 96 or y == 107) cv.set(x, y, METAL);
            }
            if (inPolygon(&ROOF_POLY, x, y)) {
                sil[i] = true;
                cv.set(x, y, if (x < 182) ROOF_LIT else ROOF_SHADE);
            }
        }
    }
}

/// True for a mask pixel that touches a pixel outside the mask (3x3 neighbourhood,
/// clamped at the image border the same way the Python version's filter is).
fn isEdge(mask: []const bool, x: usize, y: usize) bool {
    if (!mask[y * W + x]) return false;
    var inside = true;
    for (0..3) |dy| {
        for (0..3) |dx| {
            const nx: usize = @intCast(math.clamp(@as(i32, @intCast(x)) + @as(i32, @intCast(dx)) - 1, 0, W - 1));
            const ny: usize = @intCast(math.clamp(@as(i32, @intCast(y)) + @as(i32, @intCast(dy)) - 1, 0, H - 1));
            if (!mask[ny * W + nx]) inside = false;
        }
    }
    return !inside;
}

fn markInk(cv: Canvas, sil: []const bool, rocks: []const bool) void {
    for (0..H) |y| {
        for (0..W) |x| {
            if (isEdge(sil, x, y) or isEdge(rocks, x, y)) cv.setInk(x, y);
        }
    }
}

/// Lattice value noise with smoothstep interpolation, for the rock texture.
fn sampleLattice(grid: []const f32, g: usize, cell: usize, x: usize, y: usize) f32 {
    const gx = x / cell;
    const gy = y / cell;
    const tx = tof(x % cell) / tof(cell);
    const ty = tof(y % cell) / tof(cell);
    const sx = tx * tx * (3 - 2 * tx);
    const sy = ty * ty * (3 - 2 * ty);
    const a = grid[gy * g + gx];
    const b = grid[gy * g + gx + 1];
    const c = grid[(gy + 1) * g + gx];
    const d = grid[(gy + 1) * g + gx + 1];
    const top = a + (b - a) * sx;
    const bot = c + (d - c) * sx;
    return top + (bot - top) * sy;
}

fn computeNoise(out: []f32, rnd: std.Random) void {
    const gf = W / 3 + 2;
    const gc = W / 9 + 2;
    var fine: [gf * gf]f32 = undefined;
    var coarse: [gc * gc]f32 = undefined;
    for (&fine) |*v| v.* = rnd.float(f32);
    for (&coarse) |*v| v.* = rnd.float(f32);

    var lo: f32 = math.inf(f32);
    var hi: f32 = -math.inf(f32);
    for (0..H) |y| {
        for (0..W) |x| {
            const v = 0.6 * sampleLattice(&fine, gf, 3, x, y) + 0.4 * sampleLattice(&coarse, gc, 9, x, y);
            out[y * W + x] = v;
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
    }
    for (out) |*v| v.* = (v.* - lo) / (hi - lo);
}

/// Integer-stepped line, one ink pixel per step (the birds are 1px strokes).
fn drawLine(cv: Canvas, x0: i32, y0: i32, x1: i32, y1: i32) void {
    const steps: i32 = @intCast(@max(@abs(x1 - x0), @abs(y1 - y0)));
    var s: i32 = 0;
    while (s <= steps) : (s += 1) {
        const t: f32 = if (steps == 0) 0 else @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
        const x: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(x0)) + t * @as(f32, @floatFromInt(x1 - x0))));
        const y: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(y0)) + t * @as(f32, @floatFromInt(y1 - y0))));
        if (x < 0 or y < 0 or x >= W or y >= H) continue;
        cv.setInk(@intCast(x), @intCast(y));
    }
}

fn paintBirds(cv: Canvas) void {
    const birds = [_][2]i32{ .{ 120, 66 }, .{ 131, 58 }, .{ 142, 70 } };
    for (birds) |b| {
        drawLine(cv, b[0] - 3, b[1] + 1, b[0], b[1]);
        drawLine(cv, b[0], b[1], b[0] + 3, b[1] + 1);
    }
}

/// Truncate to whole colour values, as the Python version's uint8 conversion does.
fn quantize(rgb: []Rgbf) void {
    for (rgb) |*c| {
        for (c) |*v| v.* = @floor(math.clamp(v.*, 0, 255));
    }
}

pub const Illustration = struct {
    rgb: []Rgbf,
    ink: []bool,

    pub fn init(gpa: Allocator) Allocator.Error!Illustration {
        const rgb = try gpa.alloc(Rgbf, W * H);
        errdefer gpa.free(rgb);
        const ink = try gpa.alloc(bool, W * H);
        errdefer gpa.free(ink);
        @memset(ink, false);

        const rocks = try gpa.alloc(bool, W * H);
        defer gpa.free(rocks);
        const sil = try gpa.alloc(bool, W * H);
        defer gpa.free(sil);
        @memset(sil, false);
        const noise = try gpa.alloc(f32, W * H);
        defer gpa.free(noise);

        var prng = std.Random.DefaultPrng.init(11);
        const rnd = prng.random();
        const cv = Canvas{ .rgb = rgb, .ink = ink };

        paintSky(cv);
        paintClouds(cv);
        paintStars(cv, rnd);
        paintMoon(cv);
        paintSea(cv);
        paintReflection(cv);
        paintBeam(cv);
        paintGlow(cv);

        fillRockMask(rocks);
        computeNoise(noise, rnd);
        paintRocks(cv, rocks, noise);
        paintFoam(cv, rocks);
        paintLighthouse(cv, sil);
        markInk(cv, sil, rocks);
        quantize(rgb);
        paintBirds(cv);

        return .{ .rgb = rgb, .ink = ink };
    }

    pub fn deinit(self: *Illustration, gpa: Allocator) void {
        gpa.free(self.rgb);
        gpa.free(self.ink);
        self.* = undefined;
    }

    /// Writes the illustration as RGBA8 (W*H*4 bytes).
    pub fn toRgba(self: *const Illustration, out: []u8) void {
        std.debug.assert(out.len == W * H * 4);
        for (self.rgb, 0..) |c, i| {
            out[i * 4 + 0] = @intFromFloat(c[0]);
            out[i * 4 + 1] = @intFromFloat(c[1]);
            out[i * 4 + 2] = @intFromFloat(c[2]);
            out[i * 4 + 3] = 255;
        }
    }
};

pub const Stats = struct {
    tiles: usize = 0,
    /// Tile count per size, indexed by log2(size).
    by_level: [LEVELS]usize = @splat(0),
};

const MosaicBuilder = struct {
    ill: *const Illustration,
    threshold: f32,
    out: []u8,
    stats: Stats = .{},
    covered: usize = 0,

    fn visit(self: *MosaicBuilder, y0: usize, x0: usize, size: usize) void {
        var lo: Rgbf = .{ 255, 255, 255 };
        var hi: Rgbf = .{ 0, 0, 0 };
        var sum: Rgbf = .{ 0, 0, 0 };
        var has_ink = false;
        for (y0..y0 + size) |y| {
            for (x0..x0 + size) |x| {
                const i = y * W + x;
                const c = self.ill.rgb[i];
                for (0..3) |k| {
                    lo[k] = @min(lo[k], c[k]);
                    hi[k] = @max(hi[k], c[k]);
                    sum[k] += c[k];
                }
                if (self.ill.ink[i]) has_ink = true;
            }
        }

        var spread: f32 = 0;
        for (0..3) |k| spread = @max(spread, hi[k] - lo[k]);
        if (size == 1 or (!has_ink and spread < self.threshold)) {
            self.emit(y0, x0, size, sum);
            return;
        }
        const h = size / 2;
        self.visit(y0, x0, h);
        self.visit(y0, x0 + h, h);
        self.visit(y0 + h, x0, h);
        self.visit(y0 + h, x0 + h, h);
    }

    fn emit(self: *MosaicBuilder, y0: usize, x0: usize, size: usize, sum: Rgbf) void {
        const n = tof(size * size);
        const colour = [3]u8{
            toByte(sum[0] / n),
            toByte(sum[1] / n),
            toByte(sum[2] / n),
        };
        self.stats.tiles += 1;
        self.stats.by_level[math.log2_int(usize, size)] += 1;
        self.covered += size * size;

        for (y0 * SCALE..(y0 + size) * SCALE) |oy| {
            for (x0 * SCALE..(x0 + size) * SCALE) |ox| {
                const p = (oy * OUT_W + ox) * 4;
                self.out[p + 0] = colour[0];
                self.out[p + 1] = colour[1];
                self.out[p + 2] = colour[2];
                self.out[p + 3] = 255;
            }
        }
    }
};

fn toByte(v: f32) u8 {
    return @intFromFloat(math.clamp(@round(v), 0, 255));
}

/// Builds the quadtree mosaic into `out` (OUT_W*OUT_H*4 RGBA bytes).
///
/// A node becomes one tile when its colours are close (max channel spread below
/// `threshold`) and it contains no outline pixel. Outline pixels always end up
/// as 1px tiles.
pub fn renderMosaic(ill: *const Illustration, threshold: f32, out: []u8) Stats {
    std.debug.assert(out.len == OUT_W * OUT_H * 4);
    var builder = MosaicBuilder{ .ill = ill, .threshold = threshold, .out = out };
    builder.visit(0, 0, W);
    std.debug.assert(builder.covered == W * H);
    return builder.stats;
}

test "illustration has a dark sky at the top edge" {
    var ill = try Illustration.init(std.testing.allocator);
    defer ill.deinit(std.testing.allocator);
    try std.testing.expectEqual(SKY[0], ill.rgb[0]);
}

test "outline pixels always become 1px tiles" {
    var ill = try Illustration.init(std.testing.allocator);
    defer ill.deinit(std.testing.allocator);
    const out = try std.testing.allocator.alloc(u8, OUT_W * OUT_H * 4);
    defer std.testing.allocator.free(out);

    const stats = renderMosaic(&ill, DEFAULT_THRESHOLD, out);
    var ink_count: usize = 0;
    for (ill.ink) |is_ink| {
        if (is_ink) ink_count += 1;
    }
    try std.testing.expect(ink_count > 0);
    try std.testing.expect(stats.by_level[0] >= ink_count);
}

test "a higher threshold never produces more tiles" {
    var ill = try Illustration.init(std.testing.allocator);
    defer ill.deinit(std.testing.allocator);
    const out = try std.testing.allocator.alloc(u8, OUT_W * OUT_H * 4);
    defer std.testing.allocator.free(out);

    const fine = renderMosaic(&ill, 18, out);
    const coarse = renderMosaic(&ill, 40, out);
    try std.testing.expect(coarse.tiles <= fine.tiles);
    try std.testing.expect(coarse.tiles > 0);
}
