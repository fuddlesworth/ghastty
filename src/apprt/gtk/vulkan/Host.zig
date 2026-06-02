//! Process-wide Vulkan host for the GTK apprt's Vulkan renderer
//! path. libghostty doesn't create its own VkInstance/Device/Queue
//! — the host does, then hands the handles down via the per-surface
//! `apprt.platform.VulkanPlatform` callbacks. This module is the
//! GTK-side owner of those handles, mirroring Qt's
//! `qt/src/vulkan/Host.{h,cpp}` but in Zig and without the C++
//! `PresentSink` indirection.
//!
//! Singleton. One Vulkan instance + device shared across every GTK
//! surface; constructed lazily on first `instance()` call and
//! retained for the lifetime of the process. Requires a physical
//! device that supports `VK_KHR_external_memory_fd`,
//! `VK_EXT_external_memory_dma_buf`, and
//! `VK_EXT_image_drm_format_modifier` — all three are needed for
//! the dmabuf-as-importable-image export path the Vulkan renderer
//! uses to hand frames back to the host.
//!
//! Phase 1 scope: instance + device bring-up only. The
//! `asPlatform()` callback set is shaped but stubbed — `present`
//! and `get_supported_modifiers` return inert defaults so that a
//! `-Drenderer=vulkan -Dapp-runtime=gtk` build at least links.
//! Wiring the real dmabuf import path through `GdkDmabufTexture`
//! and the Wayland/GDK modifier registry is phase 2.

const std = @import("std");
const builtin = @import("builtin");
const apprt = @import("../../../apprt.zig");
const vulkan = @import("vulkan");
const vk = vulkan.c;

const log = std.log.scoped(.gtk_vulkan_host);

/// Device extensions libghostty's Vulkan renderer requires on the
/// physical device. Mirrored from `qt/src/vulkan/Host.cpp` —
/// `VK_EXT_image_drm_format_modifier` is the linchpin: without it,
/// the device-level proc-addr lookup for
/// `vkGetImageDrmFormatModifierPropertiesEXT` returns null and
/// `Target.init` fails.
const required_device_extensions: []const [*:0]const u8 = &.{
    "VK_KHR_external_memory_fd",
    "VK_EXT_external_memory_dma_buf",
    "VK_EXT_image_drm_format_modifier",
};

/// Process-singleton state. Constructed on first `instance()` and
/// never torn down — the Vulkan renderer assumes the host's handles
/// outlive every surface, and this module is the host.
var once: std.once.Once = .{};
var host: ?Host = null;

pub const Host = struct {
    instance_handle: vk.VkInstance,
    physical_device_handle: vk.VkPhysicalDevice,
    device_handle: vk.VkDevice,
    queue_handle: vk.VkQueue,
    queue_family_index: u32,
};

/// Get-or-init the process-wide Vulkan host. Returns null if
/// Vulkan can't be brought up on this system (no loader, no
/// suitable physical device, etc.) — caller should fall back to
/// rejecting the surface with `error.UnsupportedPlatform`. Cached
/// after the first call so repeated lookups are cheap.
pub fn instance() ?*const Host {
    once.call(initOnce);
    return if (host) |*h| h else null;
}

fn initOnce() void {
    var built: Host = undefined;
    bringUp(&built) catch |err| {
        log.warn("Vulkan host init failed: {s}", .{@errorName(err)});
        return;
    };
    host = built;
}

const Error = error{
    InstanceCreateFailed,
    NoPhysicalDevices,
    NoSuitablePhysicalDevice,
    DeviceCreateFailed,
};

fn bringUp(out: *Host) Error!void {
    // ---- instance ---------------------------------------------------
    var app_info: vk.VkApplicationInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = "ghostty",
        .applicationVersion = 1,
        .pEngineName = "ghostty",
        .engineVersion = 1,
        .apiVersion = vk.VK_API_VERSION_1_3,
    };
    var inst_info: vk.VkInstanceCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = 0,
        .ppEnabledExtensionNames = null,
    };
    var inst: vk.VkInstance = undefined;
    if (vk.vkCreateInstance(&inst_info, null, &inst) != vk.VK_SUCCESS) {
        return error.InstanceCreateFailed;
    }
    errdefer vk.vkDestroyInstance(inst, null);

    // ---- physical device + queue family ----------------------------
    var pd_count: u32 = 0;
    _ = vk.vkEnumeratePhysicalDevices(inst, &pd_count, null);
    if (pd_count == 0) return error.NoPhysicalDevices;

    var pds_buf: [16]vk.VkPhysicalDevice = undefined;
    const pds = pds_buf[0..@min(pd_count, pds_buf.len)];
    pd_count = @intCast(pds.len);
    _ = vk.vkEnumeratePhysicalDevices(inst, &pd_count, pds.ptr);

    var picked_pd: vk.VkPhysicalDevice = null;
    var picked_qfi: u32 = 0;
    for (pds[0..pd_count]) |pd| {
        var props: vk.VkPhysicalDeviceProperties = undefined;
        vk.vkGetPhysicalDeviceProperties(pd, &props);
        if (props.apiVersion < vk.VK_API_VERSION_1_3) continue;
        if (!hasRequiredExtensions(pd)) continue;
        const qfi = findGraphicsQueueFamily(pd) orelse continue;
        picked_pd = pd;
        picked_qfi = qfi;
        break;
    }
    if (picked_pd == null) return error.NoSuitablePhysicalDevice;

    // ---- logical device + queue ------------------------------------
    var queue_priority: f32 = 1.0;
    var qci: vk.VkDeviceQueueCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = picked_qfi,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };

    // libghostty's Vulkan renderer uses Vulkan 1.3 dynamic rendering
    // (vkCmdBeginRendering / vkCmdEndRendering, no VkRenderPass).
    // The feature has to be explicitly enabled at device creation
    // via VkPhysicalDeviceVulkan13Features.
    var vk13_features: vk.VkPhysicalDeviceVulkan13Features = .{
        .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .pNext = null,
        .robustImageAccess = vk.VK_FALSE,
        .inlineUniformBlock = vk.VK_FALSE,
        .descriptorBindingInlineUniformBlockUpdateAfterBind = vk.VK_FALSE,
        .pipelineCreationCacheControl = vk.VK_FALSE,
        .privateData = vk.VK_FALSE,
        .shaderDemoteToHelperInvocation = vk.VK_FALSE,
        .shaderTerminateInvocation = vk.VK_FALSE,
        .subgroupSizeControl = vk.VK_FALSE,
        .computeFullSubgroups = vk.VK_FALSE,
        .synchronization2 = vk.VK_TRUE,
        .textureCompressionASTC_HDR = vk.VK_FALSE,
        .shaderZeroInitializeWorkgroupMemory = vk.VK_FALSE,
        .dynamicRendering = vk.VK_TRUE,
        .shaderIntegerDotProduct = vk.VK_FALSE,
        .maintenance4 = vk.VK_FALSE,
    };

    var dci: vk.VkDeviceCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &vk13_features,
        .flags = 0,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = @intCast(required_device_extensions.len),
        .ppEnabledExtensionNames = required_device_extensions.ptr,
        .pEnabledFeatures = null,
    };

    var dev: vk.VkDevice = undefined;
    if (vk.vkCreateDevice(picked_pd, &dci, null, &dev) != vk.VK_SUCCESS) {
        return error.DeviceCreateFailed;
    }

    var queue: vk.VkQueue = undefined;
    vk.vkGetDeviceQueue(dev, picked_qfi, 0, &queue);

    var props: vk.VkPhysicalDeviceProperties = undefined;
    vk.vkGetPhysicalDeviceProperties(picked_pd, &props);
    log.info("device ready: {s} (Vulkan {d}.{d}.{d}, qfi={d})", .{
        std.mem.sliceTo(&props.deviceName, 0),
        vk.VK_API_VERSION_MAJOR(props.apiVersion),
        vk.VK_API_VERSION_MINOR(props.apiVersion),
        vk.VK_API_VERSION_PATCH(props.apiVersion),
        picked_qfi,
    });

    out.* = .{
        .instance_handle = inst,
        .physical_device_handle = picked_pd,
        .device_handle = dev,
        .queue_handle = queue,
        .queue_family_index = picked_qfi,
    };
}

fn hasRequiredExtensions(pd: vk.VkPhysicalDevice) bool {
    var n: u32 = 0;
    _ = vk.vkEnumerateDeviceExtensionProperties(pd, null, &n, null);
    if (n == 0) return false;

    // Heap-allocate via a fixed-buffer fallback so we don't pull
    // the apprt's allocator into the singleton init path. 256
    // extensions is comfortably above what any current driver
    // exposes (Mesa ~110, NVIDIA ~140); we truncate beyond that
    // and the missing-required-ext check fails closed.
    var buf: [256]vk.VkExtensionProperties = undefined;
    const cap: u32 = @intCast(@min(n, buf.len));
    n = cap;
    _ = vk.vkEnumerateDeviceExtensionProperties(pd, null, &n, &buf);

    for (required_device_extensions) |req| {
        var found = false;
        const req_slice = std.mem.sliceTo(req, 0);
        for (buf[0..n]) |ext| {
            const have = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ext.extensionName)), 0);
            if (std.mem.eql(u8, have, req_slice)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn findGraphicsQueueFamily(pd: vk.VkPhysicalDevice) ?u32 {
    var n: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, null);
    if (n == 0) return null;
    var buf: [16]vk.VkQueueFamilyProperties = undefined;
    const cap: u32 = @intCast(@min(n, buf.len));
    n = cap;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, &buf);
    for (buf[0..n], 0..) |q, i| {
        if (q.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT != 0) return @intCast(i);
    }
    return null;
}

// ---- Platform callback trampolines ----------------------------------
//
// Mirror the layout of `qt/src/vulkan/Host.cpp::cb*`. The handle
// callbacks ignore userdata and resolve through the singleton; the
// `present` callback's userdata is the per-surface sink (phase 2).

fn cbGetInstanceProcAddr(
    _: ?*anyopaque,
    name: [*:0]const u8,
) callconv(.c) ?*anyopaque {
    const h = instance() orelse return null;
    const fp = vk.vkGetInstanceProcAddr(h.instance_handle, name);
    return @ptrCast(fp);
}

fn cbInstance(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    const h = instance() orelse return null;
    return @ptrCast(h.instance_handle);
}

fn cbPhysicalDevice(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    const h = instance() orelse return null;
    return @ptrCast(h.physical_device_handle);
}

fn cbDevice(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    const h = instance() orelse return null;
    return @ptrCast(h.device_handle);
}

fn cbQueue(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    const h = instance() orelse return null;
    return @ptrCast(h.queue_handle);
}

fn cbQueueFamilyIndex(_: ?*anyopaque) callconv(.c) u32 {
    const h = instance() orelse return 0;
    return h.queue_family_index;
}

/// Phase 1 stub. Returns 0 unconditionally → renderer's
/// modifier intersection comes up empty → `Target.init` falls
/// through to legacy_copy mode (CPU readback). Phase 2 will source
/// modifiers from `gdk_display_get_dmabuf_formats()` (GTK ≥ 4.14).
fn cbGetSupportedModifiers(
    _: ?*anyopaque,
    _: u32,
    _: ?[*]u64,
    _: usize,
) callconv(.c) usize {
    return 0;
}

/// Phase 1 stub. Discards the dmabuf fd. Wiring the real present
/// path (GdkDmabufTexture → GtkPicture → Wayland subsurface) is
/// phase 2. The GTK apprt currently constructs no Vulkan surfaces
/// (`Self.platform` stays `undefined` for non-Vulkan builds and
/// nothing populates it in this commit), so this callback is
/// unreachable on `-Dapp-runtime=gtk` builds today; it exists so
/// that the symbol resolution and ABI shape are present for
/// downstream wiring.
fn cbPresent(
    _: ?*anyopaque,
    dmabuf_fd: i32,
    _: u32,
    _: u64,
    _: u32,
    _: u32,
    _: u32,
    _: bool,
) callconv(.c) void {
    if (dmabuf_fd >= 0) std.posix.close(dmabuf_fd);
}

/// Build a `VulkanPlatform` callback struct pointing at this
/// process-singleton. `userdata` is reserved for the per-surface
/// present sink; phase 1 always passes null.
pub fn asPlatform(userdata: ?*anyopaque) apprt.platform.VulkanPlatform {
    return .{
        .userdata = userdata,
        .get_instance_proc_addr = cbGetInstanceProcAddr,
        .instance = cbInstance,
        .physical_device = cbPhysicalDevice,
        .device = cbDevice,
        .queue = cbQueue,
        .queue_family_index = cbQueueFamilyIndex,
        .get_supported_modifiers = cbGetSupportedModifiers,
        .present = cbPresent,
    };
}

comptime {
    // This module exists to host the Vulkan renderer; importing it
    // on a non-Vulkan build is a project misconfiguration. Keep the
    // assertion narrow — only the actual import sites should opt
    // into Vulkan-renderer-conditional compilation.
    if (@import("../../../build_config.zig").renderer != .vulkan) {
        @compileError("apprt/gtk/vulkan/Host.zig may only be imported on -Drenderer=vulkan builds");
    }
}

test {
    _ = builtin;
}
