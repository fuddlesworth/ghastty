//! Renderer implementation and utilities. The renderer is responsible for
//! taking the internal screen state and turning into some output format,
//! usually for a screen.
//!
//! The renderer is closely tied to the windowing system which usually
//! has to prepare the window for the given renderer using system-specific
//! APIs. The renderers in this package assume that the renderer is already
//! setup (OpenGL has a context, Vulkan has a surface, etc.)

const build_config = @import("build_config.zig");
const builtin = @import("builtin");
const std = @import("std");
const apprt = @import("apprt.zig");
const font = @import("font/main.zig");
const Allocator = std.mem.Allocator;

const cursor = @import("renderer/cursor.zig");
const message = @import("renderer/message.zig");
const size = @import("renderer/size.zig");
pub const shadertoy = @import("renderer/shadertoy.zig");
pub const Backend = @import("renderer/backend.zig").Backend;
pub const GenericRenderer = @import("renderer/generic.zig").Renderer;
pub const Metal = @import("renderer/Metal.zig");
pub const OpenGL = @import("renderer/OpenGL.zig");
pub const Vulkan = @import("renderer/Vulkan.zig");
pub const WebGL = @import("renderer/WebGL.zig");
pub const Options = @import("renderer/Options.zig");
pub const Overlay = @import("renderer/Overlay.zig");
pub const Thread = @import("renderer/Thread.zig");
pub const State = @import("renderer/State.zig");
pub const CursorStyle = cursor.Style;
pub const Message = message.Message;
pub const Size = size.Size;
pub const Coordinate = size.Coordinate;
pub const CellSize = size.CellSize;
pub const ScreenSize = size.ScreenSize;
pub const GridSize = size.GridSize;
pub const Padding = size.Padding;
pub const cursorStyle = cursor.style;
pub const lib = @import("lib/main.zig");
/// Whether backend `b` is compiled into this build.
///
/// Exactly one renderer backend is compiled per build, chosen at build
/// time via `build_config.renderer`. Kept as a helper so apprt code can
/// ask the question without reaching into `build_config` directly; the
/// result is comptime-known, so guarded branches fold away.
pub fn compiledIn(comptime b: Backend) bool {
    return b == build_config.renderer;
}

/// The renderer backend in use. Comptime-known: it is the backend this
/// build compiled in. The apprt reads this to decide its per-surface
/// render integration (widget, present path).
pub inline fn activeBackend() Backend {
    return build_config.renderer;
}

/// The renderer implementation. Comptime-chosen so that every build has
/// exactly one renderer implementation.
pub const Renderer = switch (build_config.renderer) {
    .metal => GenericRenderer(Metal),
    .opengl => GenericRenderer(OpenGL),
    .vulkan => GenericRenderer(Vulkan),
    .webgl => WebGL,
};


/// The health status of a renderer. These must be shared across all
/// renderers even if some states aren't reachable so that our API users
/// can use the same enum for all renderers.
pub const Health = enum(c_int) {
    healthy,
    unhealthy,

    test "ghostty.h Health" {
        try lib.checkGhosttyHEnum(Health, "GHOSTTY_RENDERER_HEALTH_");
    }
};

test {
    // Our comptime-chosen renderer
    _ = Renderer;

    _ = cursor;
    _ = message;
    _ = shadertoy;
    _ = size;
    _ = Thread;
    _ = State;
}
