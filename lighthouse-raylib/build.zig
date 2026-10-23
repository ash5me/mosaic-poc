const std = @import("std");

// raylib 6.0, compiled from vendor/raylib/src with the same sources and flags as
// its Makefile for desktop builds (GLFW, OpenGL 3.3). GLFW picks its Win32 or X11
// backend from the target OS inside rglfw.c.
const raylib_sources = [_][]const u8{
    "rcore.c",
    "rshapes.c",
    "rtextures.c",
    "rtext.c",
    "rmodels.c",
    "raudio.c",
    "rglfw.c",
};
const common_flags = [_][]const u8{
    "-std=gnu99",
    "-D_GNU_SOURCE",
    "-DPLATFORM_DESKTOP_GLFW",
    "-DGRAPHICS_API_OPENGL_33",
    "-fno-strict-aliasing",
    "-Wno-missing-braces",
    // stb_vorbis.c compares pointers in a way clang flags as always false;
    // the code is upstream's and works, so the diagnostic is silenced.
    "-Wno-tautological-pointer-compare",
};
const x11_flags = [_][]const u8{"-D_GLFW_X11"};
const linux_libs = [_][]const u8{ "GL", "X11", "Xrandr", "Xinerama", "Xi", "Xcursor", "pthread", "dl", "m" };
const windows_libs = [_][]const u8{ "opengl32", "gdi32", "winmm" };

fn concat(b: *std.Build, a: []const []const u8, c: []const []const u8) []const []const u8 {
    const out = b.allocator.alloc([]const u8, a.len + c.len) catch @panic("out of memory");
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], c);
    return out;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const os = target.result.os.tag;
    const is_windows = os == .windows;
    if (os != .linux and os != .windows) {
        std.debug.panic("this project builds for Linux (X11) and Windows (Win32); got {s}", .{@tagName(os)});
    }
    const raylib_flags = if (is_windows) &common_flags else concat(b, &common_flags, &x11_flags);
    const system_libs: []const []const u8 = if (is_windows) &windows_libs else &linux_libs;

    const raylib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    raylib_mod.addIncludePath(b.path("vendor/raylib/src"));
    raylib_mod.addIncludePath(b.path("vendor/raylib/src/external/glfw/include"));
    raylib_mod.addCSourceFiles(.{
        .root = b.path("vendor/raylib/src"),
        .files = &raylib_sources,
        .flags = raylib_flags,
    });
    for (system_libs) |lib| raylib_mod.linkSystemLibrary(lib, .{});
    const raylib_lib = b.addLibrary(.{
        .name = "raylib",
        .root_module = raylib_mod,
        .linkage = .static,
    });

    // Zig bindings generated from raylib.h, so the app uses the real C API.
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/raylib/src/raylib.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app_mod.addImport("raylib", translate.createModule());
    app_mod.linkLibrary(raylib_lib);
    for (system_libs) |lib| app_mod.linkSystemLibrary(lib, .{});

    const exe = b.addExecutable(.{ .name = "lighthouse", .root_module = app_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Open the lighthouse mosaic window").dependOn(&run.step);

    // The illustration and quadtree are plain Zig: these tests need no window.
    const art_mod = b.createModule(.{
        .root_source_file = b.path("src/art.zig"),
        .target = target,
        .optimize = optimize,
    });
    const art_tests = b.addTest(.{ .root_module = art_mod });
    const run_art_tests = b.addRunArtifact(art_tests);
    b.step("test", "Run illustration and mosaic tests (no window needed)").dependOn(&run_art_tests.step);
}
