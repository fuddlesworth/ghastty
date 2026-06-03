//! Minimal EGL bindings for the dmabuf-export path (`DmabufTarget`).
//!
//! We don't link libEGL; the host hands us an `eglGetProcAddress`-style
//! loader (`OpenGLPlatform.get_proc_address`) and we resolve exactly the
//! handful of entry points the export needs. Keeping this tiny avoids a
//! hard EGL dependency on builds/platforms that never use it.

const std = @import("std");

const log = std.log.scoped(.opengl);

pub const Display = ?*anyopaque;
pub const Context = ?*anyopaque;
pub const Image = *anyopaque;
pub const ClientBuffer = ?*anyopaque;
pub const Int = c_int;
pub const Boolean = c_uint;
pub const Enum = c_uint;

pub const TRUE: Boolean = 1;
pub const NONE: Int = 0x3038;
pub const GL_TEXTURE_2D_KHR: Enum = 0x30B1;

/// `eglGetProcAddress`-style loader: `(userdata, name) -> ?fn`.
///
/// Caveat: `eglGetProcAddress` is only *guaranteed* to resolve EGL
/// extension entry points. `eglGetCurrentContext` (resolved in
/// `Dispatch.init`) is a core function; EGL 1.5 /
/// `EGL_KHR_get_all_proc_addresses` make resolving it via the loader
/// reliable, and Mesa (our validated stack) does. If a stricter loader
/// returns null for it, `Dispatch.init` returns null and the dmabuf path
/// is cleanly disabled — no crash.
pub const Loader = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;

const GetCurrentContextFn = *const fn () callconv(.c) Context;
const CreateImageFn = *const fn (
    Display,
    Context,
    Enum,
    ClientBuffer,
    ?[*]const Int,
) callconv(.c) ?Image;
const DestroyImageFn = *const fn (Display, Image) callconv(.c) Boolean;
const ExportQueryFn = *const fn (
    Display,
    Image,
    *c_int, // fourcc
    *c_int, // num_planes
    *u64, // modifiers
) callconv(.c) Boolean;
const ExportImageFn = *const fn (
    Display,
    Image,
    *c_int, // fds
    *Int, // strides
    *Int, // offsets
) callconv(.c) Boolean;

/// Resolved EGL entry points needed for `EGL_MESA_image_dma_buf_export`.
pub const Dispatch = struct {
    getCurrentContext: GetCurrentContextFn,
    createImage: CreateImageFn,
    destroyImage: DestroyImageFn,
    exportQuery: ExportQueryFn,
    exportImage: ExportImageFn,

    /// Resolve all entry points through `loader`. Returns null if any is
    /// missing — i.e. `EGL_MESA_image_dma_buf_export` is unavailable and
    /// the caller must fall back to non-dmabuf presentation.
    pub fn init(loader: Loader, userdata: ?*anyopaque) ?Dispatch {
        return .{
            .getCurrentContext = @ptrCast(resolve(loader, userdata, "eglGetCurrentContext") orelse return null),
            .createImage = @ptrCast(resolve(loader, userdata, "eglCreateImageKHR") orelse return null),
            .destroyImage = @ptrCast(resolve(loader, userdata, "eglDestroyImageKHR") orelse return null),
            .exportQuery = @ptrCast(resolve(loader, userdata, "eglExportDMABUFImageQueryMESA") orelse return null),
            .exportImage = @ptrCast(resolve(loader, userdata, "eglExportDMABUFImageMESA") orelse return null),
        };
    }

    fn resolve(loader: Loader, userdata: ?*anyopaque, name: [*:0]const u8) ?*anyopaque {
        return loader(userdata, name) orelse {
            log.warn("EGL entry point unavailable: {s}", .{name});
            return null;
        };
    }
};
