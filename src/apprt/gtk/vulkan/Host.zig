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
//! The host owns the VkInstance/Device/Queue and implements the
//! platform callbacks: handle lookups resolve through the singleton,
//! `get_supported_modifiers` reads GDK's dmabuf format registry, and
//! `present` hands the renderer's frame to the per-surface
//! `DmabufPaintable` — directly as a `GdkDmabufTexture` for
//! image-backed (VkImage) frames, or via an mmap + `GdkMemoryTexture`
//! copy for `.legacy_copy` (LINEAR VkBuffer) frames that can't be
//! imported as a dmabuf texture.

const std = @import("std");
const builtin = @import("builtin");
const apprt = @import("../../../apprt.zig");
const gdk = @import("gdk");
const gobject = @import("gobject");
const glib = @import("glib");
const build_options = @import("build_options");
/// Only available when the GTK build includes Wayland support. Used
/// solely to detect whether the default display is a Wayland display
/// (see `displayIsWayland`); guarded by `build_options.wayland` so
/// non-Wayland builds never reference it.
const gdk_wayland = if (build_options.wayland) @import("gdk_wayland") else struct {};
const vulkan = @import("vulkan");
const vk = vulkan.c;
const DmabufPaintable = @import("DmabufPaintable.zig").DmabufPaintable;

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
///
/// `once_mutex` + `once_done` implements a hand-rolled `std.once`:
/// the std API in 0.15.x takes the init function as a comptime
/// argument and returns a struct, which doesn't compose well with
/// the runtime-fallible init we need (init can fail and leave the
/// host as null; we still want subsequent `instance()` calls to
/// short-circuit on `once_done` and return null).
var once_mutex: std.Thread.Mutex = .{};
var once_done: bool = false;
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
    // Fast path: once initialized, no lock needed (writes to
    // `host` and `once_done` are guarded by `once_mutex`, and the
    // memory ordering on x86-64 / aarch64 makes the lock-free read
    // safe after the first synchronized read on this thread). This
    // function is hot — every libghostty platform-callback invocation
    // hits it.
    if (@atomicLoad(bool, &once_done, .acquire)) {
        return if (host) |*h| h else null;
    }

    once_mutex.lock();
    defer once_mutex.unlock();
    if (!once_done) {
        var built: Host = undefined;
        if (bringUp(&built)) |_| {
            host = built;
        } else |err| {
            log.warn("Vulkan host init failed: {s}", .{@errorName(err)});
        }
        @atomicStore(bool, &once_done, true, .release);
    }
    return if (host) |*h| h else null;
}

/// Destroy the process-wide Vulkan host. No-op if it was never
/// brought up, and idempotent (safe if the app teardown path calls
/// it more than once).
///
/// Ordering contract: call this only after every surface's renderer
/// — which *borrows* these handles (see `pkg/vulkan/Device.zig`) —
/// has been torn down. In the GTK apprt that means at app shutdown
/// (`Application.deinit`), after the main loop has exited and all
/// surfaces are finalized, so their renderer threads are joined. The
/// `vkDeviceWaitIdle` below is a belt-and-braces drain of any GPU
/// work that outlived the join; it does not substitute for the
/// thread-join ordering above.
pub fn deinit() void {
    once_mutex.lock();
    defer once_mutex.unlock();
    const h = if (host) |*h| h else return;
    _ = vk.vkDeviceWaitIdle(h.device_handle);
    vk.vkDestroyDevice(h.device_handle, null);
    vk.vkDestroyInstance(h.instance_handle, null);
    host = null;
    // `once_done` stays true: re-initializing after shutdown is
    // unsupported, and leaving it set makes any late `instance()`
    // call return null rather than racing a fresh bring-up.
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
// `present` callback's userdata is the per-surface DmabufPaintable.

fn cbGetInstanceProcAddr(
    _: ?*anyopaque,
    name: [*:0]const u8,
) callconv(.c) ?*anyopaque {
    const h = instance() orelse return null;
    const fp = vk.vkGetInstanceProcAddr(h.instance_handle, name) orelse
        return null;
    // PFN_vkVoidFunction is a `?*const fn() callconv(.c) void`. The
    // platform contract returns `?*anyopaque`; libghostty's loader
    // re-casts back to a typed PFN. The cast chain only ever round-
    // trips, so dropping const here is safe.
    return @constCast(@ptrCast(fp));
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

/// Whether `display` is a Wayland display. The direct dmabuf-import
/// present path is only validated on Wayland; on X11 we steer the
/// renderer to `.legacy_copy` (see `cbGetSupportedModifiers`). On GTK
/// builds without Wayland support this is comptime-false and the
/// `gdk_wayland` reference is never analyzed.
fn displayIsWayland(display: *gdk.Display) bool {
    return if (comptime build_options.wayland)
        gobject.ext.cast(gdk_wayland.WaylandDisplay, display) != null
    else
        false;
}

/// Source compositor-supported DRM modifiers from GDK. Two-pass
/// usage: caller first calls with `out=null, capacity=0` to query
/// the count, then again with a buffer to fill. Returns the number
/// of modifiers matching `drm_format` (capped at `capacity` if `out`
/// is non-null).
///
/// `gdk_display_get_dmabuf_formats` returns a `GdkDmabufFormats`
/// holding the *intersection* of formats both the GPU and the
/// compositor support — exactly what the Vulkan renderer needs
/// for its `pickModifier` intersection. Returning 0 is fail-safe:
/// the renderer falls back to legacy_copy mode (CPU readback), which
/// is required for direct mode on NVIDIA (no COLOR_ATTACHMENT for the
/// LINEAR modifier) and is also how we deliberately steer X11 — see
/// the backend gate below.
fn cbGetSupportedModifiers(
    _: ?*anyopaque,
    drm_format: u32,
    out: ?[*]u64,
    capacity: usize,
) callconv(.c) usize {
    const display = gdk.Display.getDefault() orelse return 0;

    // The direct dmabuf-import present path (`GdkDmabufTexture` in
    // `cbPresent`) is only exercised and validated on Wayland. On other
    // backends (X11) report no modifiers so the renderer falls back to
    // `.legacy_copy`, presenting through the display-agnostic mmap +
    // `GdkMemoryTexture` copy path, which is known to work everywhere.
    // Zero-copy dmabuf scanout on X11 is future work pending validation.
    if (!displayIsWayland(display)) {
        log.debug("non-Wayland display: steering renderer to legacy_copy (CPU) present path", .{});
        return 0;
    }

    const formats = display.getDmabufFormats();
    const total = formats.getNFormats();

    var matched: usize = 0;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        var fourcc: u32 = 0;
        var modifier: u64 = 0;
        formats.getFormat(i, &fourcc, &modifier);
        if (fourcc != drm_format) continue;
        if (out) |buf| {
            if (matched < capacity) buf[matched] = modifier;
        }
        matched += 1;
    }

    // When `out` is non-null we report only what we wrote; when
    // null we report the unbounded count (caller's two-pass query).
    return if (out != null) @min(matched, capacity) else matched;
}

/// Build a `GdkDmabufTexture` from the dmabuf fd libghostty hands
/// us and install it on the per-surface `DmabufPaintable`
/// (`userdata`). The paintable swaps the texture atomically and
/// invalidates its contents, queueing a redraw on the GUI thread.
///
/// libghostty's `present` contract:
///   - The fd is *borrowed*; we must `dup()` if we hold it past
///     the call. The renderer keeps the underlying VkDeviceMemory
///     alive — when our dup'd fd is closed (via the destroy
///     notify on the texture), the memory is freed.
///   - `image_backed` is true when the dmabuf was exported from a
///     VkImage (importable as a 2D image), which is the path this
///     function handles. When false it came from a VkBuffer fallback
///     (NVIDIA, no COLOR_ATTACHMENT for the LINEAR modifier) that
///     can't be imported as a GdkDmabufTexture; `cbPresent` routes
///     those to `presentLegacyCopy` (mmap + GdkMemoryTexture) before
///     ever reaching here.
///
/// Threading: called from libghostty's renderer thread.
/// `GdkDmabufTextureBuilder.build` has no documented thread
/// restriction (it's metadata + an fd hold). The actual GPU
/// import is deferred to the GtkPicture's snapshot path on the
/// GUI thread.
fn cbPresent(
    userdata: ?*anyopaque,
    dmabuf_fd: i32,
    drm_format: u32,
    drm_modifier: u64,
    width: u32,
    height: u32,
    stride: u32,
    image_backed: bool,
) callconv(.c) void {
    const paintable: *DmabufPaintable = @ptrCast(@alignCast(userdata orelse {
        // No paintable wired up — this is a contract violation by
        // the apprt (Surface ctor must populate userdata before
        // any render). Fail closed so the renderer's fd ownership
        // contract isn't broken; do nothing else.
        log.warn("present: null userdata (no paintable)", .{});
        return;
    }));
    // Defensive: a negative fd would be a contract violation by
    // libghostty, but we'd rather log than crash.
    if (dmabuf_fd < 0) {
        log.warn("present: invalid dmabuf fd {d}", .{dmabuf_fd});
        return;
    }

    // `.legacy_copy` frames: the fd is a LINEAR VkBuffer (e.g.
    // NVIDIA, which doesn't expose COLOR_ATTACHMENT for the LINEAR
    // modifier, or any GPU/compositor pair with no importable
    // modifier intersection). It can't be wrapped as a
    // `GdkDmabufTexture`, so it takes the mmap + `GdkMemoryTexture`
    // copy path instead. The fd stays borrowed there too — that
    // path neither dups nor closes it.
    if (!image_backed) {
        presentLegacyCopy(paintable, dmabuf_fd, drm_format, width, height, stride);
        return;
    }

    // dup() the fd so its lifetime is bound to our texture, not
    // libghostty's call stack. The destroy notify below will
    // close it when GDK drops the last reference.
    const owned_fd = std.posix.dup(dmabuf_fd) catch |err| {
        log.warn("present: dup(dmabuf_fd) failed: {s}", .{@errorName(err)});
        return;
    };

    const display = gdk.Display.getDefault() orelse {
        log.warn("present: no default display", .{});
        std.posix.close(owned_fd);
        return;
    };

    const builder = gdk.DmabufTextureBuilder.new();
    defer builder.unref();
    builder.setDisplay(display);
    builder.setWidth(width);
    builder.setHeight(height);
    builder.setFourcc(drm_format);
    builder.setModifier(drm_modifier);
    builder.setNPlanes(1);
    builder.setFd(0, owned_fd);
    builder.setStride(0, stride);
    builder.setOffset(0, 0);
    // Renderer outputs premultiplied alpha — see the `VK_FORMAT_B8G8R8A8_SRGB`
    // comment in `vulkan/Target.zig::initTarget`.
    builder.setPremultiplied(@intFromBool(true));

    var gerr: ?*@import("glib").Error = null;
    const tex = builder.build(&fdDestroyNotify, @ptrFromInt(@as(usize, @intCast(owned_fd))), &gerr);
    if (tex == null) {
        const msg = if (gerr) |e| (if (e.f_message) |m| std.mem.sliceTo(m, 0) else "(no message)") else "(no error)";
        log.warn("present: GdkDmabufTexture build failed: {s}", .{msg});
        if (gerr) |e| e.free();
        // The destroy notify did NOT fire on build failure — close
        // the dup'd fd ourselves to avoid a leak.
        std.posix.close(owned_fd);
        return;
    }

    // Hand the texture to the surface's paintable. `setTexture`
    // takes a strong ref internally; we drop our build-time ref
    // afterward. The previous texture (if any) is unref'd by the
    // setter, which cascades to its destroy notify and frees the
    // previous frame's `VkDeviceMemory`.
    paintable.setTexture(tex);
    tex.?.as(gobject.Object).unref();
}

/// `.legacy_copy` present path: the renderer exported a LINEAR
/// VkBuffer rather than an importable VkImage, so the dmabuf fd
/// can't be wrapped as a `GdkDmabufTexture`. We mmap it read-only,
/// copy the pixels into a `GdkMemoryTexture` (a one-shot CPU copy
/// GTK uploads on the GUI thread), and install it on the paintable.
/// Mirrors the Qt frontend's mmap + QImage fallback
/// (`qt/src/GhosttySurface.cpp`), including its size/format guards.
///
/// fd ownership: borrowed, per the platform contract. The copy path
/// neither dups nor closes it — libghostty frees the backing memory
/// (and the fd) when its `Target` is freed.
///
/// Threading: runs on libghostty's renderer thread. The mmap, the
/// copy into the GBytes, and texture construction are plain
/// memory/object ops; the GPU upload is deferred to the paintable's
/// snapshot on the GUI thread, and `setTexture` is thread-safe.
fn presentLegacyCopy(
    paintable: *DmabufPaintable,
    dmabuf_fd: i32,
    drm_format: u32,
    width: u32,
    height: u32,
    stride: u32,
) void {
    // Only DRM_FORMAT_ARGB8888 ('AR24') is handled: the renderer
    // outputs premultiplied B8G8R8A8 (see `vulkan/Target.zig`
    // vkFormatToDrmFourcc), which on little-endian is B,G,R,A in
    // memory == GDK's `b8g8r8a8_premultiplied`. Any other fourcc
    // would map to the wrong channel order and render miscolored,
    // so reject it loudly rather than silently.
    const drm_format_argb8888: u32 = 0x34325241; // 'AR24'
    if (drm_format != drm_format_argb8888) {
        log.warn(
            "present: dropping legacy-copy frame, unsupported drm_format=0x{x:0>8} (only 'AR24'/ARGB8888 is mapped)",
            .{drm_format},
        );
        return;
    }

    // Validate dimensions before deriving the mmap length. width,
    // height and stride are bug/attacker-reachable u32s and the byte
    // count below would otherwise be trusted blindly. Cap on a bound
    // that dwarfs any real terminal (65536²), require a stride that's
    // at least tightly-packed BGRA8 and not absurdly large, and
    // compute the length in u64 so the multiply can't wrap.
    const max_dim: u32 = 65536;
    const max_stride: u32 = max_dim * 16;
    if (width == 0 or height == 0) return;
    if (width > max_dim or height > max_dim) {
        log.warn("present: legacy-copy frame too large {d}x{d}", .{ width, height });
        return;
    }
    if (@as(u64, stride) < @as(u64, width) * 4 or stride > max_stride) {
        log.warn("present: legacy-copy frame bad stride={d} for width={d}", .{ stride, width });
        return;
    }
    const len: usize = @intCast(@as(u64, stride) * @as(u64, height));

    // Map read-only and copy out immediately: the renderer reuses
    // this host-visible buffer for the next frame, so we must not
    // retain a live view of it past the copy.
    const mapped = std.posix.mmap(
        null,
        len,
        std.posix.PROT.READ,
        .{ .TYPE = .SHARED },
        dmabuf_fd,
        0,
    ) catch |err| {
        log.warn("present: mmap of dmabuf fd={d} failed: {s}", .{ dmabuf_fd, @errorName(err) });
        return;
    };
    defer std.posix.munmap(mapped);

    // `glib.Bytes.new` copies the data, so the GBytes — and the
    // texture built from it — outlive the munmap above.
    const bytes = glib.Bytes.new(mapped.ptr, len);
    defer bytes.unref();

    const tex = gdk.MemoryTexture.new(
        @intCast(width),
        @intCast(height),
        .b8g8r8a8_premultiplied,
        bytes,
        stride,
    );

    // setTexture takes its own ref; drop our construction ref.
    paintable.setTexture(tex.as(gdk.Texture));
    tex.as(gobject.Object).unref();
}

/// glib.DestroyNotify trampoline that closes the dup'd dmabuf fd.
/// `data` is the fd cast to a pointer (we never deref it as a
/// pointer; the cast is just for the void* slot).
fn fdDestroyNotify(data: ?*anyopaque) callconv(.c) void {
    const fd: i32 = @intCast(@intFromPtr(data));
    if (fd >= 0) std.posix.close(fd);
}

/// Build a `VulkanPlatform` callback struct pointing at this
/// process-singleton. `userdata` is the per-surface `DmabufPaintable`,
/// which libghostty hands back to `cbPresent` for each frame.
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
    if (!@import("../../../renderer.zig").compiledIn(.vulkan)) {
        @compileError("apprt/gtk/vulkan/Host.zig may only be imported when the Vulkan backend is compiled in");
    }
}

test {
    _ = builtin;
}
