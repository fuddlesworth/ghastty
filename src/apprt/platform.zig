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
