//! Apprt-neutral platform descriptors. These are the per-surface
//! configuration types the renderer reads via `rt_surface.platform`
//! regardless of which apprt is in use.
//!
//! The embedded apprt has additional `Platform.C` (extern union) and
//! `Platform.init` plumbing that decodes a C ABI struct into one of
//! these values — those stay local to `apprt/embedded.zig` because
//! they're the libghostty C API surface. Direct-Zig apprts (gtk,
//! none, browser) construct these structs themselves.

/// Configuration for a host that owns a Vulkan device libghostty
/// should render against. The host owns the
/// VkInstance / VkPhysicalDevice / VkDevice / VkQueue — libghostty
/// drives pipelines / images / command buffers against those handles
/// and hands rendered frames back as dmabuf file descriptors.
///
/// Handles are `?*anyopaque` so callers don't need Vulkan headers to
/// produce a value of this type; treat them as VkInstance,
/// VkPhysicalDevice, VkDevice, VkQueue respectively.
pub const VulkanPlatform = struct {
    userdata: ?*anyopaque,

    /// Resolve `vkGetInstanceProcAddr` (returned as `?*anyopaque`).
    /// libghostty bootstraps the rest of the Vulkan loader from it.
    get_instance_proc_addr: *const fn (
        ?*anyopaque,
        [*:0]const u8,
    ) callconv(.c) ?*anyopaque,

    /// Host-owned Vulkan handles. libghostty does not destroy these.
    instance: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    physical_device: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    device: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    queue: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    queue_family_index: *const fn (?*anyopaque) callconv(.c) u32,

    /// Query the compositor-supported DRM modifiers for a given
    /// DRM_FORMAT_* fourcc. Two-pass usage: call with
    /// `out=null, capacity=0` for the count, then again with a
    /// buffer of that size. Returns the number of modifiers
    /// actually written. The renderer intersects this with the
    /// GPU's per-modifier feature set to pick a tiling the
    /// compositor will accept on attach.
    get_supported_modifiers: *const fn (
        ?*anyopaque,
        u32, // DRM_FORMAT_*
        ?[*]u64, // out
        usize, // capacity
    ) callconv(.c) usize,

    /// Hand off a rendered frame to the host as a dmabuf fd. The
    /// host imports it for composition; libghostty retains
    /// ownership of the underlying VkDeviceMemory and the fd is
    /// valid only for the duration of the call (host must `dup()`
    /// if it needs to hold the fd longer). `image_backed` tells
    /// the host whether the fd was exported from a VkImage
    /// (directly importable as a 2D image via linux-dmabuf-v1)
    /// or from a VkBuffer (only usable via mmap + CPU readback).
    present: *const fn (
        ?*anyopaque,
        i32, // dmabuf fd
        u32, // DRM_FORMAT_*
        u64, // DRM modifier
        u32, // width (pixels)
        u32, // height (pixels)
        u32, // stride (bytes)
        bool, // image_backed
    ) callconv(.c) void,
};

/// Configuration for a host that owns an OpenGL/EGL context libghostty
/// should render against, and that can display a rendered frame handed
/// back as a dmabuf file descriptor (zero-copy, mirroring the Vulkan
/// path). This is the dmabuf-export OpenGL path: libghostty renders the
/// final frame into a GL texture exported as a dmabuf via
/// `EGL_MESA_image_dma_buf_export`, then hands the fd to `present`.
///
/// Hosts that can't satisfy the dmabuf path (no EGL display, or
/// `EGL_MESA_image_dma_buf_export` missing — e.g. some drivers) should
/// not construct this; the apprt falls back to its own compositing
/// (e.g. GTK's GtkGLArea).
///
/// Handles are `?*anyopaque` so callers don't need EGL headers; treat
/// `egl_display` as an `EGLDisplay`.
pub const OpenGLPlatform = struct {
    userdata: ?*anyopaque,

    /// Resolve an EGL/GL entry point by name (an `eglGetProcAddress`
    /// shim). libghostty resolves the `EGL_MESA_image_dma_buf_export`
    /// functions through this.
    get_proc_address: *const fn (
        ?*anyopaque,
        [*:0]const u8,
    ) callconv(.c) ?*anyopaque,

    /// The host's `EGLDisplay`. libghostty creates/exports `EGLImage`s
    /// against it. Returns null if EGL isn't available.
    egl_display: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,

    /// Make the host's GL context current on the calling thread. All
    /// GL work (including the dmabuf export) happens between this and
    /// the next frame. Called on the thread that drives draws (the GUI
    /// thread for GTK — OpenGL must draw there).
    make_current: *const fn (?*anyopaque) callconv(.c) void,

    /// Hand off a rendered frame to the host as a dmabuf fd, exported
    /// from a GL texture (always image-backed / importable). The fd is
    /// valid only for the duration of the call — the host must `dup()`
    /// to hold it longer; libghostty retains the backing texture.
    present: *const fn (
        ?*anyopaque,
        i32, // dmabuf fd
        u32, // DRM_FORMAT_*
        u64, // DRM modifier
        u32, // width (pixels)
        u32, // height (pixels)
        u32, // stride (bytes)
    ) callconv(.c) void,
};
