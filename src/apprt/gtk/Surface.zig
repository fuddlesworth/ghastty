const Self = @This();

const std = @import("std");
const build_config = @import("../../build_config.zig");
const rendererpkg = @import("../../renderer.zig");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");
const ApprtApp = @import("App.zig");
const Application = @import("class/application.zig").Application;
const Surface = @import("class/surface.zig").Surface;

/// Per-surface Vulkan platform descriptor type. Present whenever the
/// Vulkan backend is *compiled in* (not just when it's the configured
/// default), since the compiled Vulkan renderer reads
/// `rt_surface.platform` for host handles + the `present` callback. On
/// builds without Vulkan it collapses to `void` so we don't pay a
/// per-surface cost for unused function-pointer storage.
///
/// When Vulkan is the active backend the `Surface` ctor
/// (`class/surface.zig`) populates `rt_surface.platform` via
/// `vulkan_host.asPlatform()`; otherwise it's left undefined and never
/// read (the Vulkan renderer isn't constructed).
pub const Platform = if (rendererpkg.compiledIn(.vulkan))
    apprt.platform.VulkanPlatform
else
    void;

/// The GObject Surface
surface: *Surface,
platform: Platform = if (Platform == void) {} else undefined,

pub fn deinit(self: *Self) void {
    _ = self;
}

/// Returns the GObject surface for this apprt surface. This is a function
/// so we can add some extra logic if we ever have to here.
pub fn gobj(self: *Self) *Surface {
    return self.surface;
}

pub fn core(self: *Self) *CoreSurface {
    // This asserts the non-optional because libghostty should only
    // be calling this for initialized surfaces.
    return self.surface.core().?;
}

pub fn rtApp(self: *Self) *ApprtApp {
    _ = self;
    return Application.default().rt();
}

pub fn close(self: *Self, process_active: bool) void {
    _ = process_active;
    self.surface.close();
}

pub fn cgroup(self: *Self) ?[]const u8 {
    return self.surface.cgroupPath();
}

pub fn getTitle(self: *Self) ?[:0]const u8 {
    return self.surface.getTitle();
}

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    return self.surface.getContentScale();
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    return self.surface.getSize();
}

pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    return self.surface.getCursorPos();
}

pub fn supportsClipboard(
    self: *const Self,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard,
        .selection,
        .primary,
        => true,
    };
}

pub fn clipboardRequest(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !bool {
    return try self.surface.clipboardRequest(
        clipboard_type,
        state,
    );
}

pub fn setClipboard(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    self.surface.setClipboard(
        clipboard_type,
        contents,
        confirm,
    );
}

pub fn defaultTermioEnv(self: *Self) !std.process.EnvMap {
    return try self.surface.defaultTermioEnv();
}

/// Redraw the inspector for our surface.
pub fn redrawInspector(self: *Self) void {
    self.surface.redrawInspector();
}
