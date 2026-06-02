//! `GdkPaintable` that holds the latest dmabuf-backed `GdkTexture`
//! the Vulkan renderer handed back through `cbPresent`. One per
//! GTK Surface, attached to the surface's `present_picture` widget
//! (see `class/surface.zig`).
//!
//! Threading. `setTexture` is called from libghostty's renderer
//! thread; the Paintable's `f_snapshot` vfunc runs on the GUI
//! thread (via the GtkPicture that owns us). The handoff is an
//! atomic pointer swap on the inner texture slot, plus a
//! `gdk_paintable_invalidate_contents` call that GTK marshals to
//! the GUI thread internally. We don't need a lock: the texture
//! refcount is the only shared mutable state, and `g_object_ref`
//! / `g_object_unref` are atomic by contract.
//!
//! Lifetime. The paintable holds a strong ref on its current
//! texture. `setTexture(null)` drops that ref, freeing the
//! underlying `VkDeviceMemory` (via the destroy notify on the fd
//! the texture was built around).

const std = @import("std");
const gdk = @import("gdk");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gtk = @import("gtk");

const log = std.log.scoped(.gtk_vulkan_paintable);

pub const DmabufPaintable = extern struct {
    parent_instance: Parent,
    pub const Parent = gobject.Object;

    /// The Paintable interface is installed in the class init via
    /// `gobject.ext.implement(gdk.Paintable, ...)`. The vtable
    /// (`paintableIfaceInit` below) populates `f_snapshot` and the
    /// `f_get_intrinsic_*` size hints. All other vfuncs use the
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

        var offset: c_int = 0;
    };

    /// Construct a fresh `DmabufPaintable`. Returns a strong ref —
    /// caller takes ownership.
    pub fn new() *DmabufPaintable {
        return gobject.ext.newInstance(DmabufPaintable, .{});
    }

    /// Replace the displayed texture. Drops the previous texture's
    /// strong ref (potentially freeing it, which cascades to the
    /// fd destroy notify and ultimately the renderer's
    /// `VkDeviceMemory`). `texture` may be null to clear.
    ///
    /// Safe to call from any thread. Schedules a redraw via
    /// `gdk.Paintable.invalidateContents` — that function is
    /// documented as thread-safe (it queues an idle on the GUI
    /// thread internally).
    pub fn setTexture(self: *DmabufPaintable, texture: ?*gdk.Texture) void {
        const priv = privateOf(self);

        // Take a ref on the new texture before swapping so the old
        // ref count drop happens last (avoids freeing memory the
        // GUI thread might still be mid-snapshot on).
        if (texture) |t| _ = t.as(gobject.Object).ref();

        const prev = @atomicRmw(?*gdk.Texture, &priv.texture, .Xchg, texture, .acq_rel);

        if (texture) |t| {
            // Cache the size for future intrinsic-size queries.
            // Width/height are immutable on a built texture, so
            // reading off-thread is safe.
            priv.intrinsic_width = @intCast(t.getWidth());
            priv.intrinsic_height = @intCast(t.getHeight());
        } else {
            priv.intrinsic_width = 0;
            priv.intrinsic_height = 0;
        }

        if (prev) |p| p.as(gobject.Object).unref();

        // Tell GTK the contents changed. `invalidateContents`
        // queues a redraw via the Paintable's installed listeners
        // (each GtkPicture that owns this Paintable as its
        // paintable property). Documented as safe from any thread.
        gdk.Paintable.invalidateContents(self.as(gdk.Paintable));
    }

    fn init(self: *DmabufPaintable, _: *Class) callconv(.c) void {
        const priv = privateOf(self);
        priv.* = .{};
    }

    fn finalize(obj: *gobject.Object) callconv(.c) void {
        const self: *DmabufPaintable = gobject.ext.cast(DmabufPaintable, obj) orelse unreachable;
        const priv = privateOf(self);
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
    if (@import("../../../build_config.zig").renderer != .vulkan) {
        @compileError("DmabufPaintable.zig may only be imported on -Drenderer=vulkan builds");
    }
}
