//! Process-singleton EGL host for the GTK OpenGL dmabuf-export present
//! path — the OpenGL analog of `gtk/vulkan/Host.zig`.
//!
//! When the OpenGL backend renders, it exports the finished frame as a
//! Linux dmabuf via `EGL_MESA_image_dma_buf_export` and hands the fd to
//! `cbPresent`, which parks it on the surface's `DmabufPaintable` for
//! zero-copy display (`GdkDmabufTexture`) — the same present path Vulkan
//! uses. This bypasses `GtkGLArea`'s GL→GSK compositor import.
//!
//! We `dlopen` libEGL (we don't link it) so the binary still launches on
//! systems without it; `available()` reports whether the dmabuf path can
//! be used so the apprt can fall back to `GtkGLArea` compositing.

const std = @import("std");
const build_options = @import("build_options");
const apprt = @import("../../../apprt.zig");
const gdk = @import("gdk");
const gobject = @import("gobject");
const glib = @import("glib");
const DmabufPaintable = @import("../DmabufPaintable.zig").DmabufPaintable;

const gdk_wayland = if (build_options.wayland) @import("gdk_wayland") else struct {};

const log = std.log.scoped(.gtk_opengl_host);

/// EGL handles we never deref; only pass back through callbacks.
const EglDisplay = ?*anyopaque;

/// `eglGetProcAddress(const char*) -> __eglMustCastToProperFunctionPointerType`.
const GetProcAddressFn = *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque;
/// `eglQueryString(EGLDisplay, EGLint) -> const char*`.
const QueryStringFn = *const fn (EglDisplay, c_int) callconv(.c) ?[*:0]const u8;

const EGL_EXTENSIONS: c_int = 0x3055;

var egl_lib: ?std.DynLib = null;
var get_proc_address: ?GetProcAddressFn = null;
var query_string: ?QueryStringFn = null;

/// Tri-state cache for `available()` so the probe runs once.
var probe: enum { unknown, yes, no } = .unknown;

/// Per-surface state handed back to the platform callbacks as
/// `userdata`: the GL context to make current and the paintable to park
/// presented frames on.
pub const Surface = struct {
    /// Our GdkGLContext; null until the widget realizes (set by the
    /// apprt). `make_current` is a no-op until then — no draw happens
    /// before realize anyway.
    gl_context: ?*gdk.GLContext = null,
    paintable: *DmabufPaintable,
};

/// True if the OpenGL dmabuf-export path can be used: libEGL is present,
/// we're on a Wayland display with an EGL display, and that display
/// advertises `EGL_MESA_image_dma_buf_export`. Cached after first call.
pub fn available() bool {
    switch (probe) {
        .yes => return true,
        .no => return false,
        .unknown => {},
    }
    probe = .no;

    if (comptime !build_options.wayland) return false;

    const display = gdk.Display.getDefault() orelse return false;
    const wl_display = gobject.ext.cast(gdk_wayland.WaylandDisplay, display) orelse {
        // X11 / non-Wayland: the dmabuf present path isn't validated
        // there (mirrors the Vulkan host's Wayland gate).
        return false;
    };

    if (!ensureLib()) return false;

    const egl_display: EglDisplay = wl_display.getEglDisplay() orelse {
        log.debug("no EGL display from GDK; OpenGL dmabuf path unavailable", .{});
        return false;
    };

    const exts_raw = (query_string.?)(egl_display, EGL_EXTENSIONS) orelse return false;
    const exts = std.mem.span(exts_raw);
    if (std.mem.indexOf(u8, exts, "EGL_MESA_image_dma_buf_export") == null) {
        log.info("EGL_MESA_image_dma_buf_export unavailable; OpenGL uses GtkGLArea", .{});
        return false;
    }

    log.info("OpenGL dmabuf export available (EGL_MESA_image_dma_buf_export)", .{});
    probe = .yes;
    return true;
}

/// The default GDK EGL display, or null if unavailable.
fn defaultEglDisplay() EglDisplay {
    if (comptime !build_options.wayland) return null;
    const display = gdk.Display.getDefault() orelse return null;
    const wl_display = gobject.ext.cast(gdk_wayland.WaylandDisplay, display) orelse return null;
    return wl_display.getEglDisplay();
}

fn ensureLib() bool {
    if (egl_lib != null) return get_proc_address != null and query_string != null;

    var lib = std.DynLib.open("libEGL.so.1") catch
        std.DynLib.open("libEGL.so") catch
        {
            log.warn("failed to dlopen libEGL; OpenGL dmabuf path unavailable", .{});
            return false;
        };
    get_proc_address = lib.lookup(GetProcAddressFn, "eglGetProcAddress") orelse {
        lib.close();
        return false;
    };
    query_string = lib.lookup(QueryStringFn, "eglQueryString") orelse {
        lib.close();
        return false;
    };
    egl_lib = lib;
    return true;
}

/// Build an `OpenGLPlatform` for a surface. `state` lives on the apprt
/// surface; libghostty hands it back to each callback.
pub fn asPlatform(state: *Surface) apprt.platform.OpenGLPlatform {
    return .{
        .userdata = state,
        .get_proc_address = cbGetProcAddress,
        .egl_display = cbEglDisplay,
        .make_current = cbMakeCurrent,
        .present = cbPresent,
    };
}

fn cbGetProcAddress(_: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque {
    const gpa = get_proc_address orelse return null;
    return @constCast(gpa(name));
}

fn cbEglDisplay(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    return defaultEglDisplay();
}

fn cbMakeCurrent(userdata: ?*anyopaque) callconv(.c) void {
    const state: *Surface = @ptrCast(@alignCast(userdata orelse return));
    if (state.gl_context) |ctx| ctx.makeCurrent();
}

fn cbPresent(
    userdata: ?*anyopaque,
    dmabuf_fd: i32,
    drm_format: u32,
    drm_modifier: u64,
    width: u32,
    height: u32,
    stride: u32,
) callconv(.c) void {
    const state: *Surface = @ptrCast(@alignCast(userdata orelse {
        log.warn("present: null userdata (no surface state)", .{});
        return;
    }));
    if (dmabuf_fd < 0) {
        log.warn("present: invalid dmabuf fd {d}", .{dmabuf_fd});
        return;
    }

    // GL-exported dmabufs are always image-backed (importable as a 2D
    // texture), so we always take the direct `GdkDmabufTexture` path.
    // The fd is borrowed; the paintable dups it (its texture destroy
    // notify closes the dup).
    _ = state.paintable.parkBorrowedDirect(dmabuf_fd, drm_format, drm_modifier, width, height, stride);
}
