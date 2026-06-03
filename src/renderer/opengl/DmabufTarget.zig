//! A dmabuf-backed render target for the OpenGL backend.
//!
//! Mirrors the Qt frontend's `EglDmabufTarget`: allocate a GL texture,
//! wrap it as an `EGLImage`, export that image's memory as a Linux
//! dmabuf via `EGL_MESA_image_dma_buf_export`, and attach the texture
//! to a framebuffer libghostty can blit the finished frame into. The
//! exported fd + fourcc + modifier + stride are then handed to the host
//! (`OpenGLPlatform.present`) for zero-copy display — the analog of the
//! Vulkan backend's dmabuf `VkImage` export.
//!
//! This is the GPU→GPU path: instead of GTK importing a `GtkGLArea`
//! texture into its GSK compositor (a GL→Vulkan interop on modern GTK),
//! the host shows the dmabuf directly via `GdkDmabufTexture`.
//!
//! Single-plane LINEAR only — `eglExportDMABUFImageMESA` can report a
//! multi-plane or offset layout we don't handle, and we reject those so
//! the caller can fall back to its own compositing path.

const Self = @This();

const std = @import("std");
const gl = @import("opengl");
const egl = @import("egl.zig");

const log = std.log.scoped(.opengl);

pub const Error = error{
    /// `EGL_MESA_image_dma_buf_export` (or a prerequisite) is missing,
    /// or the export produced a layout we don't support. The caller
    /// should fall back to non-dmabuf presentation.
    DmabufExportUnsupported,
    /// A GL or EGL object couldn't be created.
    GLObjectFailed,
};

/// EGL function table + display. Stored by value (a small POD of fn
/// pointers) so this target doesn't alias into the backend's
/// `egl_dispatch` optional payload.
dispatch: egl.Dispatch,
display: egl.Display,

/// The EGLImage wrapping `texture` (owned; destroyed in deinit).
image: egl.Image,

/// The GL texture the renderer's final frame lands in (owned).
texture: gl.c.GLuint,

/// FBO with `texture` as color attachment 0 — the blit destination.
framebuffer: gl.c.GLuint,

/// Exported dmabuf descriptor (owned; closed in deinit).
fd: std.posix.fd_t,
drm_format: u32,
drm_modifier: u64,
stride: u32,

width: u32,
height: u32,

pub fn init(
    dispatch: egl.Dispatch,
    display: egl.Display,
    context: egl.Context,
    width: u32,
    height: u32,
) Error!Self {
    if (width == 0 or height == 0) return error.GLObjectFailed;

    // 1. Allocate the GL texture the renderer will draw into.
    var tex: gl.c.GLuint = 0;
    gl.glad.context.GenTextures.?(1, &tex);
    if (tex == 0) return error.GLObjectFailed;
    errdefer gl.glad.context.DeleteTextures.?(1, &tex);

    gl.glad.context.BindTexture.?(gl.c.GL_TEXTURE_2D, tex);
    gl.glad.context.TexImage2D.?(
        gl.c.GL_TEXTURE_2D,
        0,
        gl.c.GL_RGBA8,
        @intCast(width),
        @intCast(height),
        0,
        gl.c.GL_RGBA,
        gl.c.GL_UNSIGNED_BYTE,
        null,
    );
    // No mipmaps; clamp so the compositor sampling the dmabuf is well-defined.
    gl.glad.context.TexParameteri.?(gl.c.GL_TEXTURE_2D, gl.c.GL_TEXTURE_MIN_FILTER, gl.c.GL_LINEAR);
    gl.glad.context.TexParameteri.?(gl.c.GL_TEXTURE_2D, gl.c.GL_TEXTURE_MAG_FILTER, gl.c.GL_LINEAR);
    gl.glad.context.BindTexture.?(gl.c.GL_TEXTURE_2D, 0);

    // 2. Wrap the texture as an EGLImage.
    const attribs = [_]egl.Int{egl.NONE};
    const image = dispatch.createImage(
        display,
        context,
        egl.GL_TEXTURE_2D_KHR,
        @ptrFromInt(@as(usize, tex)),
        &attribs,
    ) orelse {
        log.warn("eglCreateImageKHR failed; falling back from dmabuf export", .{});
        return error.DmabufExportUnsupported;
    };
    errdefer _ = dispatch.destroyImage(display, image);

    // 3. Query the export layout: fourcc, plane count, modifier.
    var fourcc: c_int = 0;
    var num_planes: c_int = 0;
    // EGL_MESA_image_dma_buf_export writes one modifier per plane into this
    // array. We only support single-plane exports, but the driver fills
    // `num_planes` entries *before* we can check the count, so size the
    // buffer to the DRM plane maximum (4) to avoid a stack overflow if a
    // driver reports a multi-plane layout. We read only plane 0's modifier,
    // after validating num_planes == 1.
    var modifiers = [_]u64{ 0, 0, 0, 0 };
    if (dispatch.exportQuery(display, image, &fourcc, &num_planes, &modifiers[0]) != egl.TRUE) {
        log.warn("eglExportDMABUFImageQueryMESA failed", .{});
        return error.DmabufExportUnsupported;
    }
    if (num_planes != 1) {
        log.warn("dmabuf export reported {d} planes; only single-plane is supported", .{num_planes});
        return error.DmabufExportUnsupported;
    }

    // 4. Export the dmabuf fd + stride + offset for plane 0.
    var fd: c_int = -1;
    var stride: egl.Int = 0;
    var offset: egl.Int = 0;
    if (dispatch.exportImage(display, image, &fd, &stride, &offset) != egl.TRUE or fd < 0) {
        log.warn("eglExportDMABUFImageMESA failed", .{});
        return error.DmabufExportUnsupported;
    }
    errdefer std.posix.close(fd);
    if (offset != 0) {
        log.warn("dmabuf export reported non-zero offset {d}; unsupported", .{offset});
        return error.DmabufExportUnsupported;
    }
    if (stride <= 0) {
        // A driver bug if it happens after a TRUE export, but `@intCast`
        // below would panic on a negative value — reject defensively.
        log.warn("dmabuf export reported non-positive stride {d}; unsupported", .{stride});
        return error.DmabufExportUnsupported;
    }

    // 5. Attach the texture to an FBO — the renderer's blit destination.
    var fbo: gl.c.GLuint = 0;
    gl.glad.context.GenFramebuffers.?(1, &fbo);
    if (fbo == 0) return error.GLObjectFailed;
    errdefer gl.glad.context.DeleteFramebuffers.?(1, &fbo);

    gl.glad.context.BindFramebuffer.?(gl.c.GL_FRAMEBUFFER, fbo);
    gl.glad.context.FramebufferTexture2D.?(
        gl.c.GL_FRAMEBUFFER,
        gl.c.GL_COLOR_ATTACHMENT0,
        gl.c.GL_TEXTURE_2D,
        tex,
        0,
    );
    const status = gl.glad.context.CheckFramebufferStatus.?(gl.c.GL_FRAMEBUFFER);
    gl.glad.context.BindFramebuffer.?(gl.c.GL_FRAMEBUFFER, 0);
    if (status != gl.c.GL_FRAMEBUFFER_COMPLETE) {
        log.warn("dmabuf FBO incomplete: status=0x{x}", .{status});
        return error.GLObjectFailed;
    }

    return .{
        .dispatch = dispatch,
        .display = display,
        .image = image,
        .texture = tex,
        .framebuffer = fbo,
        .fd = fd,
        .drm_format = @bitCast(fourcc),
        .drm_modifier = modifiers[0],
        .stride = @intCast(stride),
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: *Self) void {
    gl.glad.context.DeleteFramebuffers.?(1, &self.framebuffer);
    gl.glad.context.DeleteTextures.?(1, &self.texture);
    _ = self.dispatch.destroyImage(self.display, self.image);
    std.posix.close(self.fd);
    self.* = undefined;
}
