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
/// The renderer's derived configuration. Backend-independent and shared
/// across all renderer backends/variants (see `renderer/DerivedConfig.zig`).
pub const DerivedConfig = @import("renderer/DerivedConfig.zig").DerivedConfig;
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
/// GTK on Linux/BSD compiles BOTH the OpenGL and Vulkan backends so the
/// renderer can be selected at runtime (with OpenGL fallback). Every
/// other target / app-runtime keeps the single configured backend
/// (`build_config.renderer`). This must stay in lockstep with the
/// build-system's dep linking (`SharedDeps.rendererCompiled`).
///
/// The apprt uses this (comptime) to decide which render integrations to
/// compile in; `activeBackend()` (runtime) decides which one to use.
pub fn compiledIn(comptime b: Backend) bool {
    const t = builtin.target;
    if (build_config.app_runtime == .gtk and
        !t.os.tag.isDarwin() and
        t.cpu.arch != .wasm32 and
        t.cpu.arch != .wasm64)
    {
        return b == .opengl or b == .vulkan;
    }
    return b == build_config.renderer;
}

/// The renderer backend selected for this process. Defaults to the
/// configured backend; on builds that compile more than one backend the
/// apprt may override it at startup (e.g. GTK picks Vulkan or OpenGL
/// based on config + Vulkan availability) via `setActiveBackend`.
///
/// Written at most once, at startup before any surface/renderer exists,
/// so no synchronization is needed.
var active_backend: Backend = build_config.renderer;

/// Override the process renderer backend. Must be called before any
/// surface is created, and only with a backend that is `compiledIn`.
pub fn setActiveBackend(b: Backend) void {
    active_backend = b;
}

/// The renderer backend selected for this process. The apprt reads this
/// to decide its per-surface render integration (widget, present path).
pub fn activeBackend() Backend {
    return active_backend;
}

/// The concrete renderer implementation type for a backend, or `void`
/// if that backend isn't compiled into this build (see `compiledIn`).
/// `void` variants are never constructed and their dispatch arms compile
/// to nothing.
fn BackendImpl(comptime b: Backend) type {
    if (!compiledIn(b)) return void;
    return switch (b) {
        .opengl => GenericRenderer(OpenGL),
        .metal => GenericRenderer(Metal),
        .webgl => WebGL,
        .vulkan => GenericRenderer(Vulkan),
    };
}

/// The renderer implementation.
///
/// Historically this was a single comptime-chosen type. It is now a
/// tagged union over the renderer backends so the active backend can
/// eventually be chosen at runtime. For now exactly one backend is
/// compiled in (`build_config.renderer`); the other variants have `void`
/// payloads and are never constructed. `init`/`surfaceInit` build/seed
/// the active variant; the instance methods dispatch to it.
///
/// The `inline else` dispatch arms are generated per variant; the
/// `comptime ... != void` guard means the `void` arms compile to nothing
/// and never reference a method on `void`.
pub const Renderer = union(Backend) {
    opengl: BackendImpl(.opengl),
    metal: BackendImpl(.metal),
    webgl: BackendImpl(.webgl),
    vulkan: BackendImpl(.vulkan),

    // ---- construction ----------------------------------------------

    pub fn init(alloc: Allocator, options: Options) !Renderer {
        switch (activeBackend()) {
            inline else => |b| {
                if (comptime compiledIn(b)) {
                    return @unionInit(
                        Renderer,
                        @tagName(b),
                        try BackendImpl(b).init(alloc, options),
                    );
                } else unreachable;
            },
        }
    }

    pub fn surfaceInit(surface: *apprt.Surface) !void {
        switch (activeBackend()) {
            inline else => |b| {
                if (comptime compiledIn(b)) {
                    return BackendImpl(b).surfaceInit(surface);
                } else unreachable;
            },
        }
    }

    // ---- instance dispatch -----------------------------------------

    pub fn deinit(self: *Renderer) void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.deinit(),
        }
        unreachable;
    }

    pub fn finalizeSurfaceInit(self: *Renderer, surface: *apprt.Surface) !void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.finalizeSurfaceInit(surface),
        }
        unreachable;
    }

    pub fn threadEnter(self: *const Renderer, surface: *apprt.Surface) !void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.threadEnter(surface),
        }
        unreachable;
    }

    pub fn threadExit(self: *const Renderer) void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.threadExit(),
        }
        unreachable;
    }

    pub fn loopEnter(self: *Renderer, thr: *Thread) !void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.loopEnter(thr),
        }
        unreachable;
    }

    pub fn loopExit(self: *Renderer) void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.loopExit(),
        }
        unreachable;
    }

    pub fn displayRealized(self: *Renderer) !void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.displayRealized(),
        }
        unreachable;
    }

    pub fn displayUnrealized(self: *Renderer) void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.displayUnrealized(),
        }
        unreachable;
    }

    pub fn setMacOSDisplayID(self: *Renderer, id: u32) !void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.setMacOSDisplayID(id),
        }
        unreachable;
    }

    pub fn hasAnimations(self: *const Renderer) bool {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.hasAnimations(),
        }
        unreachable;
    }

    pub fn hasVsync(self: *const Renderer) bool {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.hasVsync(),
        }
        unreachable;
    }

    pub fn setFocus(self: *Renderer, focus: bool) !void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.setFocus(focus),
        }
        unreachable;
    }

    pub fn setVisible(self: *Renderer, visible: bool) void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.setVisible(visible),
        }
        unreachable;
    }

    pub fn setFontGrid(self: *Renderer, grid: *font.SharedGrid) void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.setFontGrid(grid),
        }
        unreachable;
    }

    pub fn updateFrame(
        self: *Renderer,
        state: *State,
        cursor_blink_visible: bool,
    ) Allocator.Error!void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.updateFrame(state, cursor_blink_visible),
        }
        unreachable;
    }

    pub fn drawFrame(self: *Renderer, sync: bool) !void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.drawFrame(sync),
        }
        unreachable;
    }

    pub fn changeConfig(self: *Renderer, config: *DerivedConfig) !void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.changeConfig(config),
        }
        unreachable;
    }

    pub fn setScreenSize(self: *Renderer, sz: Size) void {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.setScreenSize(sz),
        }
        unreachable;
    }

    // ---- field accessors -------------------------------------------
    //
    // The renderer thread and apprts touch a few fields directly. A union
    // can't expose a variant's fields transparently, so route them through
    // accessors that return a pointer into (or the value of) the active
    // variant's field.

    pub fn surfaceMailbox(self: *Renderer) *apprt.surface.Mailbox {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return &r.surface_mailbox,
        }
        unreachable;
    }

    pub fn searchMatchesPtr(self: *Renderer) *?Message.SearchMatches {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return &r.search_matches,
        }
        unreachable;
    }

    pub fn searchSelectedMatchPtr(self: *Renderer) *?Message.SearchMatch {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return &r.search_selected_match,
        }
        unreachable;
    }

    pub fn searchMatchesDirtyPtr(self: *Renderer) *bool {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return &r.search_matches_dirty,
        }
        unreachable;
    }

    pub fn fontGrid(self: *const Renderer) *font.SharedGrid {
        switch (self.*) {
            inline else => |*r| if (comptime @TypeOf(r.*) != void) return r.font_grid,
        }
        unreachable;
    }
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
