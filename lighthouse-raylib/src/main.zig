//! Lighthouse at dusk, rendered as a quadtree mosaic in a raylib window.
//!
//! Keys
//!   UP / DOWN   raise / lower the split threshold (+/- 2)
//!   R           reset the threshold to the default
//!   SPACE       toggle between the mosaic and the source illustration
//!   S           save a screenshot (lighthouse_t<threshold>.png)
//!   ESC         quit
//!
//! Flags
//!   --threshold N     start with split threshold N (default 40)
//!   --snapshot FILE   render a couple of frames, save FILE, and exit

const std = @import("std");
const rl = @import("raylib");
const art = @import("art.zig");

const WINDOW_W: c_int = @intCast(art.OUT_W);
const HUD_H: c_int = 40;
const WINDOW_H: c_int = @as(c_int, @intCast(art.OUT_H)) + HUD_H;
const THRESHOLD_STEP: f32 = 2;
const THRESHOLD_MIN: f32 = 4;
const THRESHOLD_MAX: f32 = 120;

const Options = struct {
    threshold: f32 = art.DEFAULT_THRESHOLD,
    snapshot: ?[:0]const u8 = null,
};

fn parseArgs(args: []const [:0]const u8) !Options {
    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--threshold")) {
            i += 1;
            if (i >= args.len) return error.MissingThreshold;
            opts.threshold = try std.fmt.parseFloat(f32, args[i]);
        } else if (std.mem.eql(u8, arg, "--snapshot")) {
            i += 1;
            if (i >= args.len) return error.MissingSnapshotPath;
            opts.snapshot = args[i];
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }
    return opts;
}

// Declared from rlgl.h, which the umbrella raylib.h header does not include.
extern fn rlDrawRenderBatchActive() void;

/// Saves what is currently on screen. Call between BeginDrawing and EndDrawing.
/// raylib queues draw calls, so the batch is flushed before the framebuffer is read.
fn saveScreenshot(path: [:0]const u8) void {
    rlDrawRenderBatchActive();
    const img = rl.LoadImageFromScreen();
    defer rl.UnloadImage(img);
    if (!rl.ExportImage(img, path.ptr)) {
        std.debug.print("could not save {s}\n", .{path});
    } else {
        std.debug.print("saved {s}\n", .{path});
    }
}

fn imageOf(pixels: []u8, width: usize, height: usize) rl.Image {
    return .{
        .data = @ptrCast(pixels.ptr),
        .width = @intCast(width),
        .height = @intCast(height),
        .mipmaps = 1,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = try parseArgs(args);

    var ill = try art.Illustration.init(gpa);
    defer ill.deinit(gpa);

    const source_px = try gpa.alloc(u8, art.W * art.H * 4);
    defer gpa.free(source_px);
    ill.toRgba(source_px);

    const mosaic_px = try gpa.alloc(u8, art.OUT_W * art.OUT_H * 4);
    defer gpa.free(mosaic_px);

    var threshold = opts.threshold;
    var stats = art.renderMosaic(&ill, threshold, mosaic_px);

    rl.SetTraceLogLevel(rl.LOG_WARNING);
    rl.InitWindow(WINDOW_W, WINDOW_H, "Lighthouse mosaic");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    const mosaic_tex = rl.LoadTextureFromImage(imageOf(mosaic_px, art.OUT_W, art.OUT_H));
    defer rl.UnloadTexture(mosaic_tex);
    rl.SetTextureFilter(mosaic_tex, rl.TEXTURE_FILTER_POINT);

    const source_tex = rl.LoadTextureFromImage(imageOf(source_px, art.W, art.H));
    defer rl.UnloadTexture(source_tex);
    rl.SetTextureFilter(source_tex, rl.TEXTURE_FILTER_POINT);

    const hud_bg = rl.Color{ .r = 14, .g = 12, .b = 26, .a = 255 };
    const hud_fg = rl.Color{ .r = 220, .g = 214, .b = 236, .a = 255 };

    var show_source = false;
    var frame: u32 = 0;
    var hud_buf: [192]u8 = undefined;
    var name_buf: [64]u8 = undefined;

    while (!rl.WindowShouldClose()) {
        var changed = false;
        if (rl.IsKeyPressed(rl.KEY_UP)) {
            threshold = @min(threshold + THRESHOLD_STEP, THRESHOLD_MAX);
            changed = true;
        }
        if (rl.IsKeyPressed(rl.KEY_DOWN)) {
            threshold = @max(threshold - THRESHOLD_STEP, THRESHOLD_MIN);
            changed = true;
        }
        if (rl.IsKeyPressed(rl.KEY_R)) {
            threshold = art.DEFAULT_THRESHOLD;
            changed = true;
        }
        if (rl.IsKeyPressed(rl.KEY_SPACE)) show_source = !show_source;
        if (changed) {
            stats = art.renderMosaic(&ill, threshold, mosaic_px);
            rl.UpdateTexture(mosaic_tex, mosaic_px.ptr);
            std.debug.print("threshold {d:.0}: {d} tiles\n", .{ threshold, stats.tiles });
        }

        const hud = try std.fmt.bufPrintSentinel(
            &hud_buf,
            "threshold {d:.0}   tiles {d}   UP/DOWN threshold   SPACE source/mosaic   S save   R reset",
            .{ threshold, stats.tiles },
            0,
        );

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);
        if (show_source) {
            rl.DrawTextureEx(source_tex, .{ .x = 0, .y = 0 }, 0, @floatFromInt(art.SCALE), rl.WHITE);
        } else {
            rl.DrawTexture(mosaic_tex, 0, 0, rl.WHITE);
        }
        rl.DrawRectangle(0, @intCast(art.OUT_H), WINDOW_W, HUD_H, hud_bg);
        rl.DrawText(hud.ptr, 12, @as(c_int, @intCast(art.OUT_H)) + 11, 18, hud_fg);

        if (rl.IsKeyPressed(rl.KEY_S)) {
            const name = try std.fmt.bufPrintSentinel(&name_buf, "lighthouse_t{d:.0}.png", .{threshold}, 0);
            saveScreenshot(name);
        }

        // Snapshot mode: draw a second frame so the texture upload has happened, save, exit.
        var done = false;
        if (opts.snapshot) |path| {
            if (frame == 1) {
                saveScreenshot(path);
                done = true;
            }
        }
        rl.EndDrawing();

        frame += 1;
        if (done) break;
    }
}
