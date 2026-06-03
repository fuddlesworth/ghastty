//! `GdkPaintable` that holds the latest dmabuf-backed `GdkTexture`
//! the renderer handed back through a `present` callback. One per GTK
//! Surface, attached to the surface's `present_picture` widget (see
//! `class/surface.zig`). Render-backend agnostic: used by both the
//! Vulkan present path (`vulkan/Host.zig`, dmabuf from a `VkImage`) and
//! the OpenGL dmabuf-export path (`opengl/Host.zig`, dmabuf from a GL
//! texture via `EGL_MESA_image_dma_buf_export`).
//!
//! Threading. `cbPresent` (Host.zig) runs on libghostty's renderer
//! thread *and* — during a resize — on the GUI thread (via
//! `Surface.draw` → `drawFrame(true)`, which renders inline on the
//! caller). It never touches GDK: it `park`s the raw frame here
//! (fd + metadata, or a CPU pixel copy) under `pending_mutex`. A
//! GUI-thread `drain` then builds the `GdkTexture` and installs it
//! via `setTexture`. Steady-state frames drain through a `g_idle`
//! source; the resize path drains synchronously right after its
//! draw so the new-size frame is on screen before size-allocate
//! returns (no `content-fit:fill` stretch). Keeping every GDK call
//! on the GUI thread — and out of the inline present — is what
//! avoids the size-allocate re-entrancy crash. `setTexture` itself
//! still swaps the texture pointer atomically since `f_snapshot`
//! (GUI thread) may read it.
//!
//! Lifetime. The paintable holds a strong ref on its current
//! texture. `setTexture(null)` drops that ref, freeing the
//! underlying `VkDeviceMemory` (via the destroy notify on the fd
//! the texture was built around).

const std = @import("std");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gtk = @import("gtk");

const log = std.log.scoped(.gtk_vulkan_paintable);

/// A frame parked by `cbPresent` (renderer thread) awaiting a
/// GUI-thread drain that builds the `GdkTexture` and installs it.
///
/// We never build GDK objects on the renderer thread: GTK is happiest
/// when `GdkTexture` construction + `gdk_paintable_*` calls happen on
/// the GUI thread, and — critically — doing the install *inline* on
/// the renderer-thread present (or inside a GUI-thread resize draw,
/// which runs during GTK's size-allocate) re-enters GTK layout and
/// crashes. So `present` parks the raw frame here and the drain (a
/// GUI idle, or a synchronous call from the resize path) does the
/// GDK work outside size-allocate. Mirrors the Qt frontend's
/// park-in-`present` + `drainVulkan` split.
const Pending = union(enum) {
    /// Direct dmabuf import. `fd` is owned (a `dup()` of the
    /// renderer's borrowed fd); the drain hands it to a
    /// `GdkDmabufTexture` whose destroy notify closes it, or closes
    /// it itself on build failure / supersession.
    direct: struct {
        fd: i32,
        drm_format: u32,
        drm_modifier: u64,
        width: u32,
        height: u32,
        stride: u32,
    },
    /// Legacy CPU copy. `bytes` owns a copy of the frame pixels
    /// (the renderer's host-visible buffer was already mmap'd +
    /// copied on the renderer thread, since it gets reused); the
    /// drain wraps it in a `GdkMemoryTexture`. We hold one strong
    /// ref, dropped at drain / supersession / finalize.
    legacy: struct {
        bytes: *glib.Bytes,
        width: u32,
        height: u32,
        stride: u32,
    },

    /// Release the resources a parked-but-undrained frame owns.
    fn deinit(self: Pending) void {
        switch (self) {
            .direct => |d| if (d.fd >= 0) std.posix.close(d.fd),
            .legacy => |l| l.bytes.unref(),
        }
    }
};

pub const DmabufPaintable = extern struct {
    parent_instance: Parent,
    pub const Parent = gobject.Object;

    /// The Paintable interface is installed in the class init via
    /// `gobject.ext.implement(gdk.Paintable, ...)`. The vtable
    /// (`paintableIfaceInit` below) populates `f_snapshot`, `f_get_flags`,
    /// and the `f_get_intrinsic_*` size hints. All other vfuncs use the
    /// PaintableInterface defaults.
    pub const Implements = [_]type{gdk.Paintable};

    pub const getGObjectType = gobject.ext.defineClass(@This(), .{
        .name = "GhosttyDmabufPaintable",
        .instanceInit = &init,
        .classInit = &classInit,
        .parent_class = &class_parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
        .implements = &.{
            gobject.ext.implement(gdk.Paintable, .{ .init = &paintableIfaceInit }),
        },
    });

    pub const Class = extern struct {
        parent_class: Parent.Class,
        pub const Instance = DmabufPaintable;
    };

    var class_parent: *Parent.Class = undefined;

    const Private = struct {
        /// Currently displayed texture. Strong ref. May be null
        /// before the first frame arrives. Mutated on the GUI
        /// thread under normal operation, but `setTexture` is
        /// callable from any thread (the renderer thread uses it).
        ///
        /// The pointer itself is swapped atomically; the texture's
        /// refcount manipulations are atomic by GObject contract.
        texture: ?*gdk.Texture = null,

        /// Last known texture size, cached so the `intrinsicWidth`
        /// / `intrinsicHeight` vfuncs don't have to call into the
        /// texture each time GTK measures the widget. GTK calls
        /// these on every layout pass.
        intrinsic_width: c_int = 0,
        intrinsic_height: c_int = 0,

        /// Frame parked by `park*` (any thread) awaiting a GUI-thread
        /// `drain`. Only the newest frame is kept — a `park` that
        /// finds one already pending releases the old one. Guarded by
        /// `pending_mutex`.
        pending: ?Pending = null,
        pending_mutex: std.Thread.Mutex = .{},

        /// The widget whose `GdkFrameClock` paces our drain — the
        /// `present_picture` we're attached to. Set at surface init
        /// (`setDriverWidget`), cleared at teardown (`stop`); read on the
        /// GUI thread only. We don't hold a ref — but the paintable can
        /// outlive the widget (a pending `armTickIdle` holds a ref on us,
        /// not the widget), so `stop()` MUST null this before the widget
        /// is freed or a late `armTickIdle`/`tickCallback` would use a
        /// dangling pointer.
        picture: ?*gtk.Widget = null,

        /// Active frame-clock tick-callback id (0 = none). GUI-thread
        /// only. The tick drains parked frames in lockstep with the
        /// compositor so continuous animation can't out-run / fall
        /// behind the frame clock (a plain idle decouples from it and
        /// the clock sleeps mid-animation → visible stalls).
        tick_id: c_uint = 0,

        /// True while a tick callback is active OR an arm idle is
        /// queued to start one. Lets `park` (any thread) start the
        /// tick exactly once per animation burst. Guarded by
        /// `pending_mutex`.
        tick_live: bool = false,

        /// Consecutive tick callbacks that found nothing to drain.
        /// After `tick_idle_limit` we disarm so an idle terminal
        /// doesn't keep the frame clock (and its wakeups) running.
        /// GUI-thread only.
        idle_ticks: u8 = 0,

        /// Set once the first frame has been parked. The resize path
        /// gates its synchronous draw on this so we never drive a
        /// draw before the renderer thread has produced a frame.
        has_presented: bool = false,

        /// Set by `stop()` at surface teardown. Prevents `park` /
        /// `armTickIdle` from (re)arming a tick on the now-cleared
        /// `picture`. Guarded by `pending_mutex` (read on the renderer
        /// thread in `park`).
        stopped: bool = false,

        var offset: c_int = 0;
    };

    /// Ticks with no new frame before we disarm the frame clock.
    /// During animation the renderer parks faster than the clock
    /// ticks, so this only elapses once animation truly stops.
    const tick_idle_limit: u8 = 8;

    /// Construct a fresh `DmabufPaintable`. Returns a strong ref —
    /// caller takes ownership.
    pub fn new() *DmabufPaintable {
        return gobject.ext.newInstance(DmabufPaintable, .{});
    }

    /// Wire up the widget whose frame clock paces our drain (the
    /// `present_picture`). Called once at surface init, GUI thread.
    pub fn setDriverWidget(self: *DmabufPaintable, widget: *gtk.Widget) void {
        privateOf(self).picture = widget;
    }

    /// Detach from the driver widget at surface teardown — GUI thread,
    /// while `present_picture` is still alive (call before it's freed).
    /// Removes any active tick callback and clears `picture` + sets
    /// `stopped`, so a late `armTickIdle`/`park` (e.g. from an in-flight
    /// renderer frame) can't arm a tick on the about-to-be-freed widget.
    /// Idempotent.
    pub fn stop(self: *DmabufPaintable) void {
        const priv = privateOf(self);

        // Remove the live tick callback (GUI-thread-only state). Its
        // DestroyNotify drops the ref `armTickIdle` took for it.
        if (priv.tick_id != 0) {
            if (priv.picture) |p| p.removeTickCallback(priv.tick_id);
            priv.tick_id = 0;
        }

        priv.pending_mutex.lock();
        priv.stopped = true;
        priv.tick_live = false;
        priv.pending_mutex.unlock();

        priv.picture = null;
    }

    /// Swap in a freshly-built texture. Drops the previous texture's
    /// strong ref (which cascades to the fd destroy notify and
    /// ultimately the renderer's `VkDeviceMemory`).
    ///
    /// GUI-thread only: called from the drain, the only place a
    /// `GdkTexture` is built. The pointer swap is atomic because
    /// `f_snapshot` reads it on the GUI thread between paints. This
    /// does NOT request a redraw — the caller (tick callback or
    /// resize path) issues `queueDraw` on the driver widget, so the
    /// repaint stays paced by the frame clock and we never emit a
    /// paintable invalidation mid size-allocate.
    fn installTexture(self: *DmabufPaintable, texture: *gdk.Texture) void {
        const priv = privateOf(self);

        // Ref the new texture before swapping so the old ref drop
        // happens last (avoids freeing memory the GUI thread might
        // still be mid-snapshot on).
        _ = texture.as(gobject.Object).ref();
        const prev = @atomicRmw(?*gdk.Texture, &priv.texture, .Xchg, texture, .acq_rel);

        // Cache the size for intrinsic-size queries. Immutable on a
        // built texture, so this is safe.
        priv.intrinsic_width = @intCast(texture.getWidth());
        priv.intrinsic_height = @intCast(texture.getHeight());

        if (prev) |p| p.as(gobject.Object).unref();
    }

    /// Park a direct-import frame from a *borrowed* fd — the platform
    /// `present` contract (the fd is valid only for the call). `dup()`s
    /// so it outlives the call (the texture's destroy notify closes the
    /// dup), then parks. Returns false if the dup failed. Shared by the
    /// Vulkan and OpenGL present callbacks. `dmabuf_fd` must be >= 0.
    pub fn parkBorrowedDirect(
        self: *DmabufPaintable,
        dmabuf_fd: i32,
        drm_format: u32,
        drm_modifier: u64,
        width: u32,
        height: u32,
        stride: u32,
    ) bool {
        const owned_fd = std.posix.dup(dmabuf_fd) catch |err| {
            log.warn("present: dup(dmabuf_fd) failed: {s}", .{@errorName(err)});
            return false;
        };
        self.parkDirect(owned_fd, drm_format, drm_modifier, width, height, stride);
        return true;
    }

    /// Park a direct-import frame (renderer thread or, on resize, the
    /// GUI thread). Takes ownership of `fd` (already a `dup()`).
    /// Releases any previously-parked-but-undrained frame.
    pub fn parkDirect(
        self: *DmabufPaintable,
        fd: i32,
        drm_format: u32,
        drm_modifier: u64,
        width: u32,
        height: u32,
        stride: u32,
    ) void {
        self.park(.{ .direct = .{
            .fd = fd,
            .drm_format = drm_format,
            .drm_modifier = drm_modifier,
            .width = width,
            .height = height,
            .stride = stride,
        } });
    }

    /// Park a legacy CPU-copy frame. Takes ownership of one strong
    /// ref on `bytes`. Releases any previously-parked frame.
    pub fn parkLegacy(
        self: *DmabufPaintable,
        bytes: *glib.Bytes,
        width: u32,
        height: u32,
        stride: u32,
    ) void {
        self.park(.{ .legacy = .{
            .bytes = bytes,
            .width = width,
            .height = height,
            .stride = stride,
        } });
    }

    fn park(self: *DmabufPaintable, frame: Pending) void {
        const priv = privateOf(self);

        priv.pending_mutex.lock();
        const old = priv.pending;
        priv.pending = frame;
        priv.has_presented = true;
        // Start the frame-clock tick exactly once per animation
        // burst: if one is already live (active or arming), this
        // park just refreshes `pending` for the next tick.
        const need_arm = !priv.tick_live and !priv.stopped;
        if (need_arm) priv.tick_live = true;
        priv.pending_mutex.unlock();

        // Release a superseded frame outside the lock.
        if (old) |o| o.deinit();

        // Arm the tick on the GUI thread. `idleAddOnce` is thread-safe
        // (posts to the default main context); the actual tick runs
        // paced by the frame clock thereafter. Hold a ref across the
        // hop, dropped in the arm callback.
        if (need_arm) {
            _ = self.as(gobject.Object).ref();
            _ = glib.idleAddOnce(armTickIdle, self);
        }
    }

    /// One-shot GUI-thread callback that starts the frame-clock tick
    /// if it isn't already running. Drops the ref taken in `park`.
    fn armTickIdle(ud: ?*anyopaque) callconv(.c) void {
        const self: *DmabufPaintable = @ptrCast(@alignCast(ud orelse return));
        defer self.as(gobject.Object).unref();

        const priv = privateOf(self);

        // Torn down between the park and now: do nothing (the widget may
        // already be freed). `stop()` cleared `tick_live`.
        {
            priv.pending_mutex.lock();
            const stopped = priv.stopped;
            priv.pending_mutex.unlock();
            if (stopped) return;
        }

        // No driver widget yet, or already ticking: nothing to do.
        // If we can't arm, clear `tick_live` so a later park retries.
        const picture = priv.picture orelse {
            priv.pending_mutex.lock();
            priv.tick_live = false;
            priv.pending_mutex.unlock();
            return;
        };
        if (priv.tick_id != 0) return;

        priv.idle_ticks = 0;
        // Keep ourselves alive for the lifetime of the tick callback;
        // the destroy notify drops this ref when the tick is removed.
        _ = self.as(gobject.Object).ref();
        priv.tick_id = picture.addTickCallback(&tickCallback, self, &tickDestroyNotify);
    }

    /// Frame-clock tick (GUI thread): install the newest parked frame,
    /// if any, and request a repaint. Disarms after `tick_idle_limit`
    /// empty ticks so an idle terminal stops waking the frame clock.
    fn tickCallback(
        _: *gtk.Widget,
        _: *gdk.FrameClock,
        ud: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *DmabufPaintable = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        const priv = privateOf(self);

        if (self.drainPending()) {
            priv.idle_ticks = 0;
            if (priv.picture) |p| p.queueDraw();
            return @intFromBool(glib.SOURCE_CONTINUE);
        }

        priv.idle_ticks +|= 1;
        if (priv.idle_ticks < tick_idle_limit)
            return @intFromBool(glib.SOURCE_CONTINUE);

        // Disarm. Re-check `pending` under the lock first: a park
        // racing this tick may have just stashed a frame after our
        // `drainPending` above but before this point — keep ticking so
        // it isn't stranded until the next park. Otherwise clear
        // `tick_live` (so the next park re-arms) and `tick_id` (so
        // `armTickIdle` knows we stopped); the destroy notify drops the
        // tick's ref after we return.
        priv.pending_mutex.lock();
        if (priv.pending != null) {
            priv.pending_mutex.unlock();
            priv.idle_ticks = 0;
            return @intFromBool(glib.SOURCE_CONTINUE);
        }
        priv.tick_live = false;
        priv.pending_mutex.unlock();
        priv.tick_id = 0;
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    /// Destroy notify for the tick callback: drops the ref taken in
    /// `armTickIdle` when GTK removes the tick (our disarm, or widget
    /// disposal).
    fn tickDestroyNotify(ud: ?*anyopaque) callconv(.c) void {
        const self: *DmabufPaintable = @ptrCast(@alignCast(ud orelse return));
        self.as(gobject.Object).unref();
    }

    /// Build the newest parked frame's `GdkTexture` and install it.
    /// Returns true if a frame was installed, false if nothing was
    /// pending (or it was dropped). GUI-thread only. Used by the tick
    /// callback and, synchronously, by the resize path.
    pub fn drainPending(self: *DmabufPaintable) bool {
        const priv = privateOf(self);

        priv.pending_mutex.lock();
        const frame = priv.pending;
        priv.pending = null;
        priv.pending_mutex.unlock();

        return switch (frame orelse return false) {
            .direct => |d| self.installDirect(d),
            .legacy => |l| self.installLegacy(l),
        };
    }

    /// True once at least one frame has been parked. The resize path
    /// uses this to avoid driving a synchronous draw before the
    /// renderer thread has produced its first frame.
    pub fn hasPresented(self: *DmabufPaintable) bool {
        const priv = privateOf(self);
        priv.pending_mutex.lock();
        defer priv.pending_mutex.unlock();
        return priv.has_presented;
    }

    fn installDirect(
        self: *DmabufPaintable,
        d: @FieldType(Pending, "direct"),
    ) bool {
        const display = gdk.Display.getDefault() orelse {
            log.warn("drain: no default display; dropping frame", .{});
            std.posix.close(d.fd);
            return false;
        };

        const builder = gdk.DmabufTextureBuilder.new();
        defer builder.unref();
        builder.setDisplay(display);
        builder.setWidth(d.width);
        builder.setHeight(d.height);
        builder.setFourcc(d.drm_format);
        builder.setModifier(d.drm_modifier);
        builder.setNPlanes(1);
        builder.setFd(0, d.fd);
        builder.setStride(0, d.stride);
        builder.setOffset(0, 0);
        // Renderer outputs premultiplied alpha — see the
        // `VK_FORMAT_B8G8R8A8_SRGB` comment in
        // `vulkan/Target.zig::initTarget`.
        builder.setPremultiplied(@intFromBool(true));

        var gerr: ?*glib.Error = null;
        const tex = builder.build(
            &fdDestroyNotify,
            @ptrFromInt(@as(usize, @intCast(d.fd))),
            &gerr,
        );
        if (tex == null) {
            const msg = if (gerr) |e| (if (e.f_message) |m| std.mem.sliceTo(m, 0) else "(no message)") else "(no error)";
            log.warn("drain: GdkDmabufTexture build failed: {s}", .{msg});
            if (gerr) |e| e.free();
            // The destroy notify did NOT fire on build failure —
            // close the dup'd fd ourselves to avoid a leak.
            std.posix.close(d.fd);
            return false;
        }

        self.installTexture(tex.?);
        tex.?.as(gobject.Object).unref();
        return true;
    }

    fn installLegacy(
        self: *DmabufPaintable,
        l: @FieldType(Pending, "legacy"),
    ) bool {
        defer l.bytes.unref();

        const tex = gdk.MemoryTexture.new(
            @intCast(l.width),
            @intCast(l.height),
            .b8g8r8a8_premultiplied,
            l.bytes,
            l.stride,
        );

        self.installTexture(tex.as(gdk.Texture));
        tex.as(gobject.Object).unref();
        return true;
    }

    /// glib.DestroyNotify trampoline that closes the dup'd dmabuf fd
    /// when GDK drops the last ref on the texture built around it.
    /// `data` is the fd cast to a pointer (never deref'd as one).
    fn fdDestroyNotify(data: ?*anyopaque) callconv(.c) void {
        const fd: i32 = @intCast(@intFromPtr(data));
        if (fd >= 0) std.posix.close(fd);
    }

    fn init(self: *DmabufPaintable, _: *Class) callconv(.c) void {
        const priv = privateOf(self);
        priv.* = .{};
    }

    fn finalize(obj: *gobject.Object) callconv(.c) void {
        const self: *DmabufPaintable = gobject.ext.cast(DmabufPaintable, obj) orelse unreachable;
        const priv = privateOf(self);

        // Release a parked-but-undrained frame (closes its fd / drops
        // its pixel-copy ref). A drain idle may still be queued with a
        // ref on us, so by construction finalize only runs after it
        // has fired and dropped that ref — `pending` here is whatever
        // the last drain left, normally null.
        priv.pending_mutex.lock();
        const pending = priv.pending;
        priv.pending = null;
        priv.pending_mutex.unlock();
        if (pending) |p| p.deinit();

        if (priv.texture) |t| {
            t.as(gobject.Object).unref();
            priv.texture = null;
        }

        gobject.Object.virtual_methods.finalize.call(class_parent, obj);
    }

    fn classInit(class: *Class) callconv(.c) void {
        const object_class: *gobject.Object.Class = @ptrCast(@alignCast(class));
        gobject.Object.virtual_methods.finalize.implement(object_class, &finalize);
    }

    // ---- Paintable interface vtable ---------------------------------

    fn paintableIfaceInit(iface: *gdk.Paintable.Iface) callconv(.c) void {
        iface.f_snapshot = &paintableSnapshot;
        iface.f_get_flags = &paintableGetFlags;
        iface.f_get_intrinsic_width = &paintableGetIntrinsicWidth;
        iface.f_get_intrinsic_height = &paintableGetIntrinsicHeight;
        // f_get_current_image and f_get_intrinsic_aspect_ratio
        // use the interface defaults; for our use case (live
        // dmabuf stream, no static-snapshot semantics) the
        // default get_current_image returning self is acceptable.
    }

    fn paintableSnapshot(
        paintable: *gdk.Paintable,
        snapshot: *gdk.Snapshot,
        width: f64,
        height: f64,
    ) callconv(.c) void {
        const self: *DmabufPaintable = gobject.ext.cast(DmabufPaintable, paintable) orelse return;
        const priv = privateOf(self);

        // Lock-free read of the texture pointer. The setter swaps
        // atomically and bumps the refcount before installing, so
        // a non-null read here is guaranteed to point at a still-
        // -live texture as long as we don't yield the GUI thread
        // between this load and the appendTexture below.
        const texture = @atomicLoad(?*gdk.Texture, &priv.texture, .acquire) orelse return;

        // gdk.Snapshot is the parent class of gtk.Snapshot. The
        // texture-append helper is on gtk.Snapshot; the cast is
        // safe because every Paintable.snapshot call from GTK
        // hands us a gtk.Snapshot underneath the gdk.Snapshot
        // type erasure.
        const gtk_snapshot: *gtk.Snapshot = @ptrCast(snapshot);
        const bounds: graphene.Rect = .{
            .f_origin = .{ .f_x = 0, .f_y = 0 },
            .f_size = .{ .f_width = @floatCast(width), .f_height = @floatCast(height) },
        };
        gtk_snapshot.appendTexture(texture, &bounds);
    }

    fn paintableGetFlags(_: *gdk.Paintable) callconv(.c) gdk.PaintableFlags {
        // The texture changes per frame and so does the size
        // (resize), so neither STATIC_CONTENTS nor STATIC_SIZE
        // applies. Default-zero PaintableFlags = "fully dynamic"
        // which is what we want.
        return .{};
    }

    fn paintableGetIntrinsicWidth(paintable: *gdk.Paintable) callconv(.c) c_int {
        const self: *DmabufPaintable = gobject.ext.cast(DmabufPaintable, paintable) orelse return 0;
        return privateOf(self).intrinsic_width;
    }

    fn paintableGetIntrinsicHeight(paintable: *gdk.Paintable) callconv(.c) c_int {
        const self: *DmabufPaintable = gobject.ext.cast(DmabufPaintable, paintable) orelse return 0;
        return privateOf(self).intrinsic_height;
    }

    // ---- helpers ----------------------------------------------------

    fn privateOf(self: *DmabufPaintable) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    pub fn as(self: *DmabufPaintable, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }
};

comptime {
    // Shared by both GTK dmabuf present paths (Vulkan + OpenGL-dmabuf).
    // Both are gated on the Vulkan backend being compiled in (GTK/Linux),
    // so that's the condition under which this is importable.
    if (!@import("../../renderer.zig").compiledIn(.vulkan)) {
        @compileError("DmabufPaintable.zig may only be imported when a GTK dmabuf present backend is compiled in (gated on Vulkan)");
    }
}
