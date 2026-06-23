// Wayland subsurface presenter for `GhosttySurface`.
//
// Owns one `wl_subsurface` parented to the `GhosttySurface`'s native
// `wl_surface`, plus the `zwp_linux_dmabuf_v1` machinery for wrapping
// libghostty's dmabuf fds in `wl_buffer`s and attaching them to that
// subsurface. The compositor scans the buffers out directly — no
// mmap, no memcpy, no QImage, no QPainter blit on the present path.
//
// The process-wide compositor modifier registry that used to share
// this header now lives in `DmabufRegistry.h`. The implementations
// share `globalState()` machinery in `SubsurfacePresenter.cpp` but
// the API surfaces are disjoint: presenter is per-widget, registry
// is process-wide and read-only.
//
// Wayland-only by project decision (the Qt frontend is Wayland-only;
// see `feedback-qt-no-x11` memory). If the host isn't on a Wayland
// QPA platform or the compositor lacks the required globals,
// `tryCreate` returns nullptr — the caller decides whether that's a
// fatal error.

#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <unordered_map>

struct wl_buffer;
struct wl_callback;
struct wl_display;
struct wl_subsurface;
struct wl_surface;
struct zwp_linux_dmabuf_v1;
struct wp_viewport;
struct wp_fractional_scale_v1;
class QWindow;

namespace wayland {

class SubsurfacePresenter {
public:
  // Build a subsurface parented to `topLevel`'s native `wl_surface`,
  // and bind the linux-dmabuf-v1 global on the same display. Pass
  // the TOP-LEVEL QWindow (e.g. `widget->window()->windowHandle()`)
  // — NOT a per-widget native QWindow. We attach all panes/splits
  // as siblings under the top-level surface and position each with
  // `setPosition`, instead of giving each pane its own QWindow
  // (which Qt's QSplitter-embedded child widgets don't handle
  // cleanly: "QWidgetWindow must be a top level window" warning,
  // and the result renders black).
  //
  // Returns nullptr if any prerequisite is missing (non-Wayland QPA,
  // null `wl_display`, `wl_subcompositor` unbindable,
  // `zwp_linux_dmabuf_v1` unbindable, etc.).
  static std::unique_ptr<SubsurfacePresenter> tryCreate(QWindow *topLevel);

  ~SubsurfacePresenter();

  // Hand a dmabuf-backed frame to the compositor: wrap the fd in a
  // `wl_buffer` via `zwp_linux_buffer_params_v1.create_immed`, attach
  // to the subsurface, damage, commit. MUST be called on the Qt GUI
  // thread (the thread that owns the wl_display dispatch); the
  // renderer thread should marshal frames through a Qt-side queue.
  //
  // libghostty owns the fd; this method does not close it. The
  // wayland client library duplicates the fd kernel-side via
  // SCM_RIGHTS, so the compositor's reference survives even after
  // libghostty reuses or closes its handle.
  //
  // `dest_width` / `dest_height` are the size of the subsurface in
  // PARENT surface-local coordinates (i.e. logical pixels). For
  // integer scales they match the buffer dimensions divided by the
  // scale; for fractional scales they're independent (set via
  // wp_viewport.set_destination, which decouples buffer dimensions
  // from surface area).
  // `y_invert` requests the compositor flip the buffer vertically
  // when sampling. The OpenGL renderer's coordinate convention is
  // bottom-left origin (Y up), but Wayland/DRM samples top-down —
  // without the flag, GL frames render upside-down. Vulkan
  // rasterizes Y-down by default and passes false.
  void presentDmabuf(int fd, uint32_t drm_format, uint64_t drm_modifier,
                     uint32_t width, uint32_t height, uint32_t stride,
                     int dest_width, int dest_height,
                     bool y_invert = false);

  // Compositor-preferred fractional scale for this surface, in
  // units of 1/120 (e.g. 144 = 1.2, 180 = 1.5, 240 = 2.0). Returns
  // 120 (= 1.0) until the compositor sends its first
  // wp_fractional_scale_v1.preferred_scale event for our surface.
  //
  // Currently INFORMATIONAL only: GhosttySurface uses Qt's
  // devicePixelRatioF() for buffer sizing (which Qt derives from
  // the same protocol on Wayland), so the two values agree at
  // steady state. Exposed for diagnostics + a future direct-
  // protocol path that bypasses Qt's DPR cache lag during a
  // screen-change race.
  uint32_t preferredScale120() const { return m_preferredScale120; }

  // Update the subsurface position in parent-surface-local coords.
  // For panes inside splits / tabs, position is the GhosttySurface
  // widget's offset within the top-level (`mapTo(window(),
  // QPoint(0,0))`). wl_subsurface.set_position is double-buffered
  // on the *parent* surface — caller must trigger a parent commit
  // (Qt's QtWaylandClient::QWaylandWindow::commit()) for the new
  // position to apply. No-op if the position hasn't changed.
  void setPosition(int x, int y);

  // Detach the currently-attached buffer so the subsurface becomes
  // invisible. Called when the owning GhosttySurface hides (tab
  // switch) so the inactive pane's pixels don't ghost on top of
  // whatever the active tab is showing in the same on-screen
  // region. The next presentDmabuf call re-attaches a buffer and
  // the subsurface becomes visible again.
  void hide();

  // Register a callback fired (on the GUI thread, via Wayland event
  // queue dispatch) when the compositor signals it's ready for the
  // next frame on this subsurface. Lets the caller pace presents at
  // the compositor's refresh rate instead of unconditionally
  // committing every renderer frame.
  //
  // The callback fires AT MOST ONCE per `presentDmabuf` /
  // `reattachCached` call — the underlying `wl_surface.frame`
  // request is single-shot per commit. After the callback fires,
  // the next present's commit will register a new frame_callback.
  using OnFrameReady = std::function<void()>;
  void setOnFrameReady(OnFrameReady cb) { m_onFrameReady = std::move(cb); }

  // Register a callback fired (on the GUI thread, via Wayland event
  // queue dispatch) when the renderer is safe to reuse a rotated-away
  // dma-buf again — i.e. the compositor has released the buffer that
  // the most recent present replaced. This is the release-gate that
  // prevents the renderer from redrawing a buffer the compositor is
  // still scanning out (flicker on the zero-copy path).
  //
  // It fires once per present: either immediately at commit time when
  // that present replaced no earlier buffer (nothing to wait for — e.g.
  // the very first frame), or later from wl_buffer.release when the
  // replaced buffer is freed. It also fires on every early-return /
  // dropped-frame path so a parked renderer is never left waiting on a
  // release that will not come.
  using OnBufferReusable = std::function<void()>;
  void setOnBufferReusable(OnBufferReusable cb) {
    m_onBufferReusable = std::move(cb);
  }

  // wl_buffer::release dispatch from the file-scope listener. Public so
  // the C-style listener can route to it via the listener `data`
  // pointer (the presenter). Resolves the release-gate when the
  // released buffer is the one the last present replaced.
  void onBufferReleased(wl_buffer *buffer);

  // Flush the underlying wl_display to push any queued requests
  // to the compositor. Useful after a forceParentCommit on the
  // Qt side (which queues a parent wl_surface.commit but doesn't
  // wl_display_flush), so the combined "child commit + parent
  // commit" reach the compositor in one shot rather than racing
  // Qt's next event-loop flush.
  void flushDisplay();

  // Re-attach + commit the most recently cached wl_buffer, if any.
  // Called from `QEvent::Show` so a tab-switch / re-show sees the
  // last frame immediately rather than a transparent area while
  // the renderer thread spins up its first new frame. Without this,
  // the parent surface paints through (WA_TranslucentBackground)
  // and the user sees a flash of whatever is behind the window.
  // Returns true if a cached buffer was actually re-attached;
  // false if the cache was empty (first show — caller is
  // responsible for the new-tab flash mitigation if needed).
  bool reattachCached();

  // Called from the wp_fractional_scale_v1.preferred_scale event.
  // Public so the C-style listener struct at file scope in the .cpp
  // can name it; not part of the API for other call sites.
  static void onPreferredScale(void *data, wp_fractional_scale_v1 *,
                                uint32_t scale);

  // wl_callback::done dispatch from the file-scope listener. Public
  // for the same reason as onPreferredScale: C-style Wayland
  // listeners need a static-callable entry point and we route the
  // result back into the owning presenter via the listener's `data`
  // pointer. Destroys the callback proxy, clears m_frameCallback,
  // and invokes m_onFrameReady if set. Not part of the API for
  // other call sites.
  void onFrameCallbackDone(wl_callback *cb);

  SubsurfacePresenter(const SubsurfacePresenter &) = delete;
  SubsurfacePresenter &operator=(const SubsurfacePresenter &) = delete;

private:
  SubsurfacePresenter(wl_display *display, wl_surface *child,
                      wl_subsurface *sub, zwp_linux_dmabuf_v1 *dmabuf,
                      wp_viewport *viewport,
                      wp_fractional_scale_v1 *frac_scale);

  wl_display *m_display;
  wl_surface *m_childSurface;
  wl_subsurface *m_subsurface;
  zwp_linux_dmabuf_v1 *m_dmabuf;
  wp_viewport *m_viewport;
  wp_fractional_scale_v1 *m_fractionalScale;
  uint32_t m_preferredScale120 = 120; // default: 1.0×
  int m_lastDestWidth = 0;
  int m_lastDestHeight = 0;
  int m_lastX = 0;
  int m_lastY = 0;

  // Pending wl_surface.frame callback for compositor-paced presents.
  // Null between frame_done and the next presentDmabuf commit. Non-
  // null between presentDmabuf and frame_done. Single-shot — the
  // done handler destroys it and clears the field, then invokes
  // `m_onFrameReady` if set.
  wl_callback *m_frameCallback = nullptr;
  OnFrameReady m_onFrameReady;

  // Release-gate state. m_awaitingReleaseOf is the wl_buffer that the
  // most recent present replaced and whose wl_buffer.release we're
  // waiting for before firing m_onBufferReusable; null when nothing is
  // pending. Only one can be outstanding at a time because the renderer
  // is single-frame-in-flight (fence-paced) and paced to the
  // compositor, so each present replaces exactly the previous frame's
  // buffer.
  OnBufferReusable m_onBufferReusable;
  wl_buffer *m_awaitingReleaseOf = nullptr;

  // wl_buffer cache keyed by dma-buf identity (kernel inode of the
  // anon_inode backing the dma-buf, unique per Target regardless of
  // fd-number reuse). Cache hits skip the create_immed round-trip +
  // compositor-side dmabuf import that dominated GUI-thread CPU at
  // 125 FPS.
  //
  // Why a MAP and not a single slot: with double-buffering the
  // renderer rotates between `swap_chain_count` Targets (distinct
  // inodes) frame to frame, so several wl_buffers are live at once —
  // each created once and reattached when the rotation cycles back to
  // it. A single slot would miss every frame and destroy a buffer the
  // compositor may still be scanning out, defeating the purpose.
  //
  // We can't key on the caller's fd value because GhosttySurface dups
  // the fd on the renderer thread (to outlive libghostty's close — see
  // 22713b0d3) so the value is fresh per frame. Inode identity is
  // stable across our dup AND across libghostty's close → reopen
  // cycles, so it matches Target identity exactly.
  //
  // The map only stores the wl_buffer; the compositor SCM_RIGHTS-dup'd
  // the fd into its own address space at create_immed time, so the
  // entry doesn't need our fd to outlive the call. The caller owns +
  // closes its own dup. Entries from a previous Target generation (a
  // resize changes the shape and mints new inodes) are purged in
  // presentDmabuf when a present arrives with a different shape, so the
  // map stays bounded at `swap_chain_count` entries.
  struct CachedBuffer {
    wl_buffer *buffer = nullptr;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t stride = 0;
    uint32_t format = 0;
    uint64_t modifier = 0;
    bool yInvert = false;
  };
  std::unordered_map<unsigned long, CachedBuffer> m_buffers;

  // Fallback for the (effectively impossible on Linux) case where
  // fstat on the dma-buf fd fails so we have no inode to key on. We
  // can't track such a buffer for reuse, so we hold exactly one and
  // destroy it when the next uncacheable frame replaces it (by which
  // point the compositor has long released it) or at teardown.
  wl_buffer *m_uncachedBuffer = nullptr;

  // The most recently attached wl_buffer + its extent, for
  // reattachCached() after a hide/show (re-show the last frame rather
  // than a transparent gap). Points into m_buffers (or equals
  // m_uncachedBuffer); nulled if that buffer is destroyed.
  wl_buffer *m_lastPresentedBuffer = nullptr;
  uint32_t m_lastPresentedWidth = 0;
  uint32_t m_lastPresentedHeight = 0;
};

} // namespace wayland
