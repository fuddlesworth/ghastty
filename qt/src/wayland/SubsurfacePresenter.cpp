#include "SubsurfacePresenter.h"
#include "DmabufRegistry.h"

#include <algorithm>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <sys/stat.h>  // ::fstat — wl_buffer cache identity via st_ino
#include <unordered_map>
#include <vector>

#include <QGuiApplication>
#include <QLatin1String>
#include <QScopeGuard>
#include <QWindow>
#include <qpa/qplatformnativeinterface.h>

#include <wayland-client.h>

#include "fractional-scale-v1-client-protocol.h"
#include "linux-dmabuf-v1-client-protocol.h"
#include "viewporter-client-protocol.h"

namespace wayland {

namespace {

// Process-wide bindings for the Wayland globals the presenter needs,
// plus the (format → modifiers) table the compositor advertises via
// zwp_linux_dmabuf_v1's format/modifier events. Populated once by
// `discoverGlobals` on the GUI thread; subsequent reads from the
// renderer thread are safe because the table is never mutated after
// the initial discovery completes.
struct PresenterGlobals {
  wl_compositor *compositor = nullptr;
  wl_subcompositor *subcompositor = nullptr;
  zwp_linux_dmabuf_v1 *dmabuf = nullptr;
  wp_viewporter *viewporter = nullptr;
  wp_fractional_scale_manager_v1 *fractionalScale = nullptr;
  std::unordered_map<uint32_t, std::vector<uint64_t>> modifiers;
  bool searched = false;
};

PresenterGlobals &globalState() {
  static PresenterGlobals g;
  return g;
}

// Pre-v4 dmabuf format event. We ignore it: v3 also fires `modifier`
// events for every (format, modifier) tuple including LINEAR — the
// `format` event is legacy from v1/v2 when modifiers didn't exist.
void dmabufFormat(void *, zwp_linux_dmabuf_v1 *, uint32_t /*format*/) {}

// `modifier` event: compositor advertises one (format, modifier) it
// can scan out. Fires once per pair during the bind roundtrip; we
// stash them all in the per-format vector. Only fires from inside
// `discoverGlobals` because we keep the dmabuf proxy on a private
// queue that's never dispatched after discovery — see the queue-
// retention comment in `discoverGlobals`. That guarantee is what
// lets the renderer thread read `globals.modifiers` without a
// lock, and is also why we don't bother deduping (one bind round
// only fires each pair once).
void dmabufModifier(void *data, zwp_linux_dmabuf_v1 *, uint32_t format,
                    uint32_t modifier_hi, uint32_t modifier_lo) {
  auto *g = static_cast<PresenterGlobals *>(data);
  const uint64_t modifier =
      (static_cast<uint64_t>(modifier_hi) << 32) | modifier_lo;
  g->modifiers[format].push_back(modifier);
}

const zwp_linux_dmabuf_v1_listener kDmabufListener = {
    dmabufFormat,
    dmabufModifier,
};

void registryGlobal(void *data, wl_registry *registry, uint32_t name,
                    const char *interface, uint32_t version) {
  auto *g = static_cast<PresenterGlobals *>(data);
  if (std::strcmp(interface, wl_compositor_interface.name) == 0) {
    // Bind wl_compositor at version 3+ so child wl_surfaces we
    // create support `set_buffer_scale` (added in v3, used by the
    // presenter on HiDPI displays). Cap at v6 (the highest we've
    // tested against); if the compositor advertises less, take
    // what we get and `presentDmabuf` will skip the buffer_scale
    // call on those compositors.
    const uint32_t v = std::min<uint32_t>(version, 6u);
    g->compositor = static_cast<wl_compositor *>(
        wl_registry_bind(registry, name, &wl_compositor_interface, v));
  } else if (std::strcmp(interface, wl_subcompositor_interface.name) == 0) {
    g->subcompositor = static_cast<wl_subcompositor *>(
        wl_registry_bind(registry, name, &wl_subcompositor_interface, 1));
  } else if (std::strcmp(interface, zwp_linux_dmabuf_v1_interface.name) == 0) {
    // We want at least v3 for `create_immed` (synchronous wl_buffer
    // creation — v1/v2 have only the async `create` + `created`/
    // `failed` dance). A compositor that only advertises v1/v2
    // can't satisfy our protocol assumptions; binding at v3 against
    // such a compositor would protocol-error and tear down the
    // entire wl_display. Skip the bind in that case so the
    // legacy QImage fallback engages cleanly.
    if (version < 3) {
      std::fprintf(stderr,
                   "[ghastty] wayland: linux-dmabuf-v1 advertised at "
                   "version %u; need >= 3 for create_immed, falling back "
                   "to QImage path\n",
                   version);
    } else {
      // Cap at v3 — v4 adds the dynamic format/modifier feedback
      // dance which we don't consume.
      const uint32_t v = std::min<uint32_t>(version, 3u);
      g->dmabuf = static_cast<zwp_linux_dmabuf_v1 *>(wl_registry_bind(
          registry, name, &zwp_linux_dmabuf_v1_interface, v));
      // Add the listener immediately so the modifier events queued
      // by the bind get delivered when the dispatch loop continues.
      zwp_linux_dmabuf_v1_add_listener(g->dmabuf, &kDmabufListener, g);
    }
  } else if (std::strcmp(interface, wp_viewporter_interface.name) == 0) {
    g->viewporter = static_cast<wp_viewporter *>(
        wl_registry_bind(registry, name, &wp_viewporter_interface, 1));
  } else if (std::strcmp(
                 interface, wp_fractional_scale_manager_v1_interface.name) == 0) {
    g->fractionalScale = static_cast<wp_fractional_scale_manager_v1 *>(
        wl_registry_bind(registry, name,
                         &wp_fractional_scale_manager_v1_interface, 1));
  }
}
void registryGlobalRemove(void *, wl_registry *, uint32_t) {}

const wl_registry_listener kRegistryListener = {
    registryGlobal,
    registryGlobalRemove,
};

PresenterGlobals *discoverGlobals(wl_display *display) {
  PresenterGlobals &globals = globalState();
  if (globals.searched) return &globals;
  globals.searched = true;

  wl_event_queue *queue = wl_display_create_queue(display);
  wl_registry *registry = wl_display_get_registry(display);
  wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(registry), queue);
  wl_registry_add_listener(registry, &kRegistryListener, &globals);
  // Roundtrip 1: bind compositor/subcompositor/dmabuf. Inside the
  // registry callback we attach the dmabuf listener immediately, so
  // any format/modifier events that arrive in the same dispatch
  // pass fire on it. A negative return means the wl_display
  // disconnected mid-startup; subsequent tryCreate calls fall
  // through to the QImage path (g->compositor etc. stay null).
  if (wl_display_roundtrip_queue(display, queue) < 0) {
    std::fprintf(stderr,
                 "[ghastty] wayland: discoverGlobals roundtrip 1 failed; "
                 "subsurface present path disabled\n");
  }
  wl_registry_destroy(registry);
  // Roundtrip 2: belt-and-suspenders for any compositor that defers
  // the modifier events past the bind reply (most don't, but some
  // batch them). After this returns the modifier table is fully
  // populated and frozen for the process lifetime.
  if (globals.dmabuf && wl_display_roundtrip_queue(display, queue) < 0) {
    std::fprintf(stderr,
                 "[ghastty] wayland: discoverGlobals roundtrip 2 failed; "
                 "modifier table is incomplete — disabling dmabuf path\n");
    // Drop whatever modifier entries we did get. A partially-
    // populated table is dangerous: presentDmabuf would treat it
    // as authoritative, hand a "supported" modifier to the
    // compositor that the compositor may actually not accept, and
    // the resulting `invalid_format` is a FATAL protocol error
    // that kills the entire wl_display. Falling back to QImage
    // path (modifiers map empty → tryCreate's checks fail / the
    // Vulkan renderer drops to legacy_copy mode) is much safer.
    globals.modifiers.clear();
    globals.dmabuf = nullptr;
  }

  std::size_t total_mods = 0;
  for (const auto &kv : globals.modifiers) total_mods += kv.second.size();
  std::fprintf(stderr,
               "[ghastty] wayland: discovered %zu dmabuf (format,modifier) "
               "pairs across %zu formats\n",
               total_mods, globals.modifiers.size());

  // Move the bound proxies back to the default queue so Qt's main
  // dispatch drives subsequent events on them, then drop the private
  // queue. (Same lifecycle dance as `blurManager`.)
  //
  // EXCEPT the dmabuf proxy: its listener mutates `globals.modifiers`
  // on every `modifier` event, and the renderer thread reads that
  // map from `supportedDmabufModifiers` without locking. If we
  // moved the proxy back to the default queue, a compositor
  // restart / hot-plug fires more `modifier` events that would
  // race the reader. Keep the proxy on `queue` and intentionally
  // never dispatch that queue again — the events queue up
  // harmlessly and are reaped at proxy destruction. The map is
  // genuinely frozen post-discovery now.
  if (globals.compositor)
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(globals.compositor),
                       nullptr);
  if (globals.subcompositor)
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(globals.subcompositor),
                       nullptr);
  if (globals.viewporter)
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(globals.viewporter),
                       nullptr);
  if (globals.fractionalScale)
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(globals.fractionalScale),
                       nullptr);
  // We deliberately leak `queue` (and leave globals.dmabuf attached
  // to it) for the process lifetime — it has no resources beyond a
  // small kernel-side buffer and going away would put dmabuf events
  // back on the default queue.

  return &globals;
}

wl_display *acquireWaylandDisplay() {
  if (!QGuiApplication::platformName().startsWith(QLatin1String("wayland")))
    return nullptr;
  QPlatformNativeInterface *native = QGuiApplication::platformNativeInterface();
  if (!native) return nullptr;
  return static_cast<wl_display *>(
      native->nativeResourceForIntegration("wl_display"));
}

// wl_buffer::release listener: the compositor is done sampling the
// buffer for any committed surface state, so libghostty's renderer is
// free to draw into the underlying dma-buf again. We KEEP the wl_buffer
// alive across releases — each Target's wl_buffer is cached by inode in
// m_buffers and re-attached when the double-buffer rotation cycles back
// to it. Buffers are destroyed only when (a) a resize retires the
// Target generation (presentDmabuf purges the stale-shape entries) or
// (b) the presenter is destroyed.
//
// The underlying dma-buf memory is owned by libghostty; we never close
// that fd here (the SCM_RIGHTS transfer in zwp_linux_buffer_params.add
// gave the compositor its own reference, independent of our wl_buffer).
//
// Increment 2 acts on release to gate buffer reuse: route to the owning
// presenter, which resolves the release-gate when the released buffer is
// the one the most recent present replaced. A compositor holding a
// buffer on a hardware plane therefore can never have it overwritten
// mid-scanout — the renderer blocks (host side) until this fires.
void bufferRelease(void *data, wl_buffer *buffer) {
  if (auto *p = static_cast<wayland::SubsurfacePresenter *>(data))
    p->onBufferReleased(buffer);
}
const wl_buffer_listener kBufferListener = {
    bufferRelease,
};

// wl_callback::done listener for compositor-paced presents. Single-
// shot per callback — the proxy is destroyed here and the
// presenter's m_frameCallback field is cleared so the next present
// knows to register a fresh one. After cleanup, invoke the
// presenter's onFrameReady hook (set by GhosttySurface to pump the
// next pending frame).
void frameCallbackDone(void *data, wl_callback *cb, uint32_t /*time*/) {
  auto *p = static_cast<wayland::SubsurfacePresenter *>(data);
  // Defensive: if the listener fires after the proxy was destroyed
  // by ~SubsurfacePresenter (Wayland guarantees no events on a
  // destroyed proxy, so this shouldn't happen, but if a future
  // refactor destroys the presenter before flushing the queue we'd
  // rather no-op than UAF).
  if (!p) {
    wl_callback_destroy(cb);
    return;
  }
  p->onFrameCallbackDone(cb);
}
const wl_callback_listener kFrameCallbackListener = {
    frameCallbackDone,
};

} // namespace

void primeDmabufModifierRegistry() {
  if (wl_display *display = acquireWaylandDisplay()) {
    (void)discoverGlobals(display);
  }
}

std::size_t supportedDmabufModifiers(std::uint32_t drm_format,
                                     std::uint64_t *out,
                                     std::size_t capacity) {
  const PresenterGlobals &g = globalState();
  if (!g.searched) return 0;
  auto it = g.modifiers.find(drm_format);
  if (it == g.modifiers.end()) return 0;
  const std::size_t available = it->second.size();
  if (out == nullptr || capacity == 0) return available;
  const std::size_t copied = std::min(available, capacity);
  std::memcpy(out, it->second.data(), copied * sizeof(std::uint64_t));
  return copied;
}

std::unique_ptr<SubsurfacePresenter>
SubsurfacePresenter::tryCreate(QWindow *topLevel) {
  if (!topLevel) return nullptr;

  if (!QGuiApplication::platformName().startsWith(QLatin1String("wayland"))) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: not on Wayland QPA\n");
    return nullptr;
  }

  QPlatformNativeInterface *native = QGuiApplication::platformNativeInterface();
  if (!native) return nullptr;

  auto *display = static_cast<wl_display *>(
      native->nativeResourceForIntegration("wl_display"));
  auto *parentSurface = static_cast<wl_surface *>(
      native->nativeResourceForWindow("surface", topLevel));
  if (!display || !parentSurface) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: missing wl_display or "
                 "parent wl_surface (display=%p surface=%p)\n",
                 static_cast<void *>(display),
                 static_cast<void *>(parentSurface));
    return nullptr;
  }

  PresenterGlobals *g = discoverGlobals(display);
  if (!g->compositor || !g->subcompositor || !g->dmabuf || !g->viewporter) {
    std::fprintf(
        stderr,
        "[ghastty] SubsurfacePresenter: compositor missing required globals "
        "(compositor=%p subcompositor=%p dmabuf=%p viewporter=%p)\n",
        static_cast<void *>(g->compositor),
        static_cast<void *>(g->subcompositor), static_cast<void *>(g->dmabuf),
        static_cast<void *>(g->viewporter));
    return nullptr;
  }
  // wp_fractional_scale_manager_v1 is optional — if missing we
  // assume integer scale 1.0 and let wp_viewport.set_destination
  // still do its job. Most modern compositors support it.

  wl_surface *child = wl_compositor_create_surface(g->compositor);
  if (!child) return nullptr;

  wl_subsurface *sub =
      wl_subcompositor_get_subsurface(g->subcompositor, child, parentSurface);
  if (!sub) {
    wl_surface_destroy(child);
    return nullptr;
  }

  // Sync mode (the wl_subsurface default): wl_surface.commit on
  // the child caches state until the parent commits, at which point
  // both apply atomically. This is what guarantees lockstep resize
  // behavior — parent grows to the new size and our matching
  // new-size buffer apply in the same compositor frame, no gap.
  //
  // Sync mode requires the parent to commit for our state to
  // apply. Qt's backing-store flush doesn't fire for our
  // translucent QWidget (paintEvent produces no damage), so
  // GhosttySurface forces the parent commit explicitly via
  // QtWaylandClient::QWaylandWindow::commit() (Qt6::WaylandClient-
  // Private) after every child commit + viewport update. See
  // `forceParentCommit` in GhosttySurface.cpp.
  //
  // The earlier desync-mode attempt avoided the Qt-private
  // dependency but couldn't deliver lockstep resize because the
  // two surfaces commit independently in that mode.

  // Initial subsurface position: (0,0) in parent-surface coords.
  // GhosttySurface immediately calls setPosition after tryCreate
  // returns with the pane's real offset within the top-level (and
  // updates it on every moveEvent / resizeEvent).
  wl_subsurface_set_position(sub, 0, 0);

  // Stack the subsurface BELOW the parent so Qt's child widgets
  // (SearchBar, overlays, scrollbar, exit/health/link/resize hints)
  // remain visible — they're painted into the parent's backing
  // store, and Wayland's default subsurface stacking is *above*
  // parent which would hide all of them. With place_below the
  // parent QWidget renders on top; WA_TranslucentBackground means
  // the terminal area of the parent is transparent so the
  // subsurface shows through, while the chrome painted by
  // paintEvent stays visible on top.
  wl_subsurface_place_below(sub, parentSurface);

  // Set an empty input region so pointer/touch events fall through
  // to the parent surface (Qt's QWindow). The default input region
  // is the whole attached buffer, which would mean our subsurface
  // captures every click in the terminal area — Qt's QWidget would
  // never see contextMenuEvent (right-click menu), mouse press/
  // release, or any other pointer event in the terminal. wl_region
  // with no add_rectangle calls = empty = "no input." The region
  // can be destroyed immediately after set_input_region; the
  // compositor copies its state into the surface's pending state.
  wl_region *empty = wl_compositor_create_region(g->compositor);
  if (empty) {
    wl_surface_set_input_region(child, empty);
    wl_region_destroy(empty);
  }

  // wp_viewport: per-surface object that lets us tell the compositor
  // the destination size in surface-local coords, independent of
  // the buffer's pixel dimensions. With fractional scaling we
  // render at, say, 960x720 device pixels into an 800x600 surface
  // area, and the viewport handles the mapping.
  wp_viewport *viewport =
      wp_viewporter_get_viewport(g->viewporter, child);
  if (!viewport) {
    wl_subsurface_destroy(sub);
    wl_surface_destroy(child);
    return nullptr;
  }

  // wp_fractional_scale_v1: subscribe to the compositor's
  // per-surface preferred scale. Optional — if the global is
  // missing we stick with default 120 (= 1.0×).
  wp_fractional_scale_v1 *frac_scale = nullptr;
  if (g->fractionalScale) {
    frac_scale = wp_fractional_scale_manager_v1_get_fractional_scale(
        g->fractionalScale, child);
  }

  wl_display_flush(display);
  if (int err = wl_display_get_error(display); err != 0) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: wl_display error %d after "
                 "subsurface creation\n",
                 err);
    if (frac_scale) wp_fractional_scale_v1_destroy(frac_scale);
    wp_viewport_destroy(viewport);
    wl_subsurface_destroy(sub);
    wl_surface_destroy(child);
    return nullptr;
  }

  std::fprintf(stderr,
               "[ghastty] SubsurfacePresenter: ready (parent=%p child=%p "
               "sub=%p dmabuf=%p viewport=%p frac_scale=%p)\n",
               static_cast<void *>(parentSurface), static_cast<void *>(child),
               static_cast<void *>(sub), static_cast<void *>(g->dmabuf),
               static_cast<void *>(viewport),
               static_cast<void *>(frac_scale));

  return std::unique_ptr<SubsurfacePresenter>(new SubsurfacePresenter(
      display, child, sub, g->dmabuf, viewport, frac_scale));
}

const wp_fractional_scale_v1_listener kFractionalScaleListener = {
    SubsurfacePresenter::onPreferredScale,
};

void SubsurfacePresenter::onPreferredScale(void *data,
                                            wp_fractional_scale_v1 *,
                                            uint32_t scale) {
  auto *self = static_cast<SubsurfacePresenter *>(data);
  if (scale == 0) return; // guard against compositor bugs
  if (scale != self->m_preferredScale120) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: preferred scale %u/120 = "
                 "%.3f\n",
                 scale, static_cast<double>(scale) / 120.0);
    self->m_preferredScale120 = scale;
  }
}

SubsurfacePresenter::SubsurfacePresenter(wl_display *display, wl_surface *child,
                                         wl_subsurface *sub,
                                         zwp_linux_dmabuf_v1 *dmabuf,
                                         wp_viewport *viewport,
                                         wp_fractional_scale_v1 *frac_scale)
    : m_display(display),
      m_childSurface(child),
      m_subsurface(sub),
      m_dmabuf(dmabuf),
      m_viewport(viewport),
      m_fractionalScale(frac_scale) {
  if (m_fractionalScale) {
    wp_fractional_scale_v1_add_listener(m_fractionalScale,
                                         &kFractionalScaleListener, this);
  }
}

SubsurfacePresenter::~SubsurfacePresenter() {
  // Destroy the pending frame callback first: subsequent dispatches
  // of the wl_event_queue won't deliver its done event (Wayland
  // guarantees no events on a destroyed proxy), so the dangling
  // `this` pointer in the listener data can't fire.
  if (m_frameCallback) {
    wl_callback_destroy(m_frameCallback);
    m_frameCallback = nullptr;
  }
  // Destroy all cached wl_buffers BEFORE the child surface — a buffer
  // may still be attached. wl_buffer_destroy is safe whether or not the
  // compositor has released it (Wayland guarantees no further events on
  // a destroyed proxy).
  for (auto &entry : m_buffers) {
    if (entry.second.buffer) wl_buffer_destroy(entry.second.buffer);
  }
  m_buffers.clear();
  if (m_uncachedBuffer) {
    wl_buffer_destroy(m_uncachedBuffer);
    m_uncachedBuffer = nullptr;
  }
  m_lastPresentedBuffer = nullptr;
  m_awaitingReleaseOf = nullptr;
  if (m_fractionalScale) wp_fractional_scale_v1_destroy(m_fractionalScale);
  if (m_viewport) wp_viewport_destroy(m_viewport);
  if (m_subsurface) wl_subsurface_destroy(m_subsurface);
  if (m_childSurface) wl_surface_destroy(m_childSurface);
  if (m_display) wl_display_flush(m_display);
}

void SubsurfacePresenter::onFrameCallbackDone(wl_callback *cb) {
  // The single-shot wl_callback is now spent. Destroy the proxy and
  // clear our slot so the next present registers a fresh callback.
  // Guard against the rare cb-mismatch case (shouldn't happen — the
  // listener data routes to exactly this presenter and we only ever
  // have one outstanding callback — but be defensive against future
  // refactors).
  if (cb == m_frameCallback) m_frameCallback = nullptr;
  wl_callback_destroy(cb);
  // Notify the consumer (e.g. GhosttySurface) that the compositor
  // is ready for the next frame. The callback runs on the same
  // thread that pumps Wayland events (the Qt GUI thread), so it can
  // touch GUI-thread state directly.
  if (m_onFrameReady) m_onFrameReady();
}

void SubsurfacePresenter::onBufferReleased(wl_buffer *buffer) {
  // Runs on the Qt GUI thread (Wayland event dispatch). Resolve the
  // release-gate only for the buffer the most recent present replaced —
  // ignoring releases of other (older) buffers makes the gate robust
  // against release/commit timing skew: a stale release can never wake
  // the renderer early to redraw a buffer still on screen.
  if (buffer && buffer == m_awaitingReleaseOf) {
    m_awaitingReleaseOf = nullptr;
    if (m_onBufferReusable) m_onBufferReusable();
  }
}

void SubsurfacePresenter::presentDmabuf(int fd, uint32_t drm_format,
                                        uint64_t drm_modifier, uint32_t width,
                                        uint32_t height, uint32_t stride,
                                        int dest_width, int dest_height,
                                        bool y_invert) {
  // Release-gate bookkeeping. By default the gate (letting the renderer
  // reuse a rotated-away dma-buf) opens when this call returns. If this
  // present commits a frame that REPLACES an earlier on-screen buffer,
  // we instead defer the gate to that buffer's wl_buffer.release (via
  // m_awaitingReleaseOf) so the renderer can't redraw a buffer the
  // compositor is still scanning out. On every early-return / dropped-
  // frame / first-frame path the guard opens the gate now, so a parked
  // renderer is never left waiting on a release that will not come.
  // `replaced` (whatever buffer this commit supersedes) is captured just
  // before the attach below, AFTER the stale-generation purge — so if a
  // resize purged the old on-screen buffer, we don't end up waiting on a
  // release for a buffer we already destroyed.
  bool gate_deferred = false;
  const auto gate = qScopeGuard([&] {
    if (!gate_deferred && m_onBufferReusable) m_onBufferReusable();
  });

  if (fd < 0 || !m_dmabuf || !m_childSurface || !m_viewport) return;
  if (dest_width <= 0) dest_width = 1;
  if (dest_height <= 0) dest_height = 1;

  // System-boundary input validation. width/height/stride flow in
  // from libghostty's renderer thread and are about to be passed
  // verbatim to the compositor. linux-dmabuf-v1 protocol errors
  // (`invalid_dimensions`, `invalid_format`, etc.) are FATAL — they
  // tear down the entire wl_display, killing every window in the
  // process. We MUST reject malformed inputs locally rather than
  // letting the compositor do it.
  //
  // Specifically reject: zero dimensions or stride, or any value
  // that would silently flip negative when cast to int32_t at the
  // create_immed call below (the wayland C API takes signed ints
  // for dimensions; uint32_t >= 2^31 wraps to negative).
  constexpr uint32_t kMaxDim = static_cast<uint32_t>(INT32_MAX);
  if (width == 0 || height == 0 || stride == 0 ||
      width > kMaxDim || height > kMaxDim || stride > kMaxDim) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: rejecting dmabuf with "
                 "out-of-range dimensions (w=%u h=%u stride=%u)\n",
                 width, height, stride);
    return;
  }
  // Stride sanity: must be at least 4 bytes per pixel for
  // 32-bit ARGB/XRGB/etc. — the only formats this presenter
  // currently advertises support for. Tighter than the protocol's
  // minimum but matches what the compositor will accept on attach.
  if (stride < static_cast<uint64_t>(width) * 4) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: rejecting dmabuf with "
                 "stride=%u too small for width=%u (need >= %llu)\n",
                 stride, width,
                 static_cast<unsigned long long>(static_cast<uint64_t>(width) * 4));
    return;
  }

  // Validate the (format, modifier) pair against the compositor's
  // advertised list before handing it to `create_immed`. If the
  // pair isn't on the list, the compositor will reject the
  // subsequent `create_immed` with `invalid_format` — a FATAL
  // protocol error that kills the entire wl_display, taking down
  // every window in the process. Better to drop this single frame
  // than to take down the app.
  {
    const PresenterGlobals &g = globalState();
    const auto it = g.modifiers.find(drm_format);
    bool ok = false;
    if (it != g.modifiers.end()) {
      for (const uint64_t m : it->second) {
        if (m == drm_modifier) { ok = true; break; }
      }
    }
    if (!ok) {
      std::fprintf(stderr,
                   "[ghastty] SubsurfacePresenter: refusing dmabuf "
                   "(fourcc=0x%08x mod=0x%llx) — compositor doesn't "
                   "advertise this (format, modifier) pair\n",
                   drm_format,
                   static_cast<unsigned long long>(drm_modifier));
      return;
    }
  }

  // Wrap libghostty's borrowed fd in a wl_buffer, cached per dma-buf
  // identity (kernel inode) — see m_buffers in the header for the full
  // rationale. fstat the fd to get the anon_inode that uniquely
  // identifies the dma-buf object; it's stable across the dup that
  // GhosttySurface did before parking, and changes only when libghostty
  // allocates a new Target.
  struct stat st;
  unsigned long inode = 0;
  if (::fstat(fd, &st) == 0) inode = static_cast<unsigned long>(st.st_ino);

  // Purge entries from a previous Target generation. A resize deinits
  // every Target and exports new fds (new inodes) with a new shape;
  // their wl_buffers are now backed by freed memory and must go. Within
  // a single generation all buffers share one shape, so a shape
  // mismatch against this present marks the stale generation.
  for (auto it = m_buffers.begin(); it != m_buffers.end();) {
    const CachedBuffer &c = it->second;
    const bool same_shape = c.width == width && c.height == height &&
                            c.stride == stride && c.format == drm_format &&
                            c.modifier == drm_modifier && c.yInvert == y_invert;
    if (same_shape) {
      ++it;
      continue;
    }
    if (c.buffer == m_lastPresentedBuffer) m_lastPresentedBuffer = nullptr;
    if (c.buffer == m_awaitingReleaseOf) m_awaitingReleaseOf = nullptr;
    if (c.buffer) wl_buffer_destroy(c.buffer);
    it = m_buffers.erase(it);
  }

  wl_buffer *buffer = nullptr;
  const auto hit = (inode != 0) ? m_buffers.find(inode) : m_buffers.end();
  if (hit != m_buffers.end()) {
    // Cache hit: same Target (inode), same shape (guaranteed by the
    // purge above). Reattach the existing wl_buffer.
    buffer = hit->second.buffer;
  } else {
    zwp_linux_buffer_params_v1 *params =
        zwp_linux_dmabuf_v1_create_params(m_dmabuf);
    if (!params) return;
    zwp_linux_buffer_params_v1_add(params, fd, /*plane_idx*/ 0,
                                   /*offset*/ 0, stride,
                                   static_cast<uint32_t>(drm_modifier >> 32),
                                   static_cast<uint32_t>(drm_modifier & 0xFFFFFFFFu));
    const uint32_t buffer_flags =
        y_invert ? ZWP_LINUX_BUFFER_PARAMS_V1_FLAGS_Y_INVERT : 0;
    buffer = zwp_linux_buffer_params_v1_create_immed(
        params, static_cast<int32_t>(width), static_cast<int32_t>(height),
        drm_format, buffer_flags);
    zwp_linux_buffer_params_v1_destroy(params);
    if (!buffer) {
      // Surface the wl_display error code if the failure was a
      // protocol-fatal error (compositor rejected the buffer with
      // `invalid_format` / `invalid_dimensions` / etc., which kills
      // the wl_display). Without this, every subsequent presentDmabuf
      // call silently no-ops on the dead display and the cause stays
      // hidden until something else logs the disconnection.
      const int wl_err = wl_display_get_error(m_display);
      std::fprintf(stderr,
                   "[ghastty] SubsurfacePresenter: create_immed returned null "
                   "(fd=%d %ux%u fmt=0x%x mod=0x%llx wl_display_error=%d)\n",
                   fd, width, height, drm_format,
                   static_cast<unsigned long long>(drm_modifier), wl_err);
      return;
    }
    // Attach the release listener. The data pointer is the presenter so
    // onBufferReleased can resolve the release-gate (Increment 2).
    wl_buffer_add_listener(buffer, &kBufferListener, this);
    if (inode != 0) {
      m_buffers.emplace(inode, CachedBuffer{buffer, width, height, stride,
                                            drm_format, drm_modifier, y_invert});
    } else {
      // No inode to key on (fstat failed — effectively impossible for a
      // live anon_inode dma-buf fd on Linux). We can't track this buffer
      // for reuse, so hold exactly one fallback and destroy the previous
      // one (the compositor is done with it ≥1 frame later) to avoid an
      // unbounded leak on a pathological host.
      if (m_uncachedBuffer) {
        if (m_uncachedBuffer == m_lastPresentedBuffer)
          m_lastPresentedBuffer = nullptr;
        if (m_uncachedBuffer == m_awaitingReleaseOf)
          m_awaitingReleaseOf = nullptr;
        wl_buffer_destroy(m_uncachedBuffer);
      }
      m_uncachedBuffer = buffer;
    }
  }

  // Tell the compositor the destination size in surface-local
  // coordinates. With fractional scaling this is the logical pixel
  // size (e.g. 800x600) while the buffer is at device pixels (e.g.
  // 960x720 for 1.2× DPR). wp_viewport handles the mapping;
  // wl_surface.set_buffer_scale is intentionally NOT used here
  // because (a) it only supports integer scales, and (b) when
  // wp_fractional_scale_v1 is active the protocol forbids using
  // set_buffer_scale to anything other than 1.
  if (dest_width != m_lastDestWidth || dest_height != m_lastDestHeight) {
    wp_viewport_set_destination(m_viewport, dest_width, dest_height);
    m_lastDestWidth = dest_width;
    m_lastDestHeight = dest_height;
  }

  wl_surface_attach(m_childSurface, buffer, 0, 0);
  // Capture the buffer this commit supersedes (post-purge, so it's null
  // if a resize already destroyed it) before overwriting the field.
  wl_buffer *const replaced = m_lastPresentedBuffer;
  // Remember the buffer we're showing so a hide/show can re-attach it
  // (reattachCached) instead of leaving a transparent gap.
  m_lastPresentedBuffer = buffer;
  m_lastPresentedWidth = width;
  m_lastPresentedHeight = height;
  // If this commit supersedes a different buffer, hold the release-gate
  // closed until the compositor releases that buffer (handled in
  // onBufferReleased). Reattaching the SAME buffer (replaced == buffer)
  // frees nothing, so the guard opens the gate immediately instead.
  if (replaced && replaced != buffer) {
    m_awaitingReleaseOf = replaced;
    gate_deferred = true;
  }
  // Damage the full buffer extent — terminals tend to update large
  // dirty rects anyway (cursor blink, scroll, repaint) so a precise
  // damage region wouldn't save much, and `damage_buffer` (vs
  // `damage`) uses buffer coordinates so it's resolution-correct.
  wl_surface_damage_buffer(m_childSurface, 0, 0, static_cast<int32_t>(width),
                           static_cast<int32_t>(height));
  // Register a wl_surface.frame callback BEFORE the commit so the
  // compositor knows we want to be paced. Only request a new one if
  // none is outstanding — re-requesting before the prior fires would
  // leak callbacks. The done handler clears m_frameCallback, so the
  // next call here will register fresh.
  if (!m_frameCallback) {
    m_frameCallback = wl_surface_frame(m_childSurface);
    if (m_frameCallback) {
      wl_callback_add_listener(m_frameCallback, &kFrameCallbackListener,
                               this);
    }
  }
  wl_surface_commit(m_childSurface);

  wl_display_flush(m_display);
  if (int err = wl_display_get_error(m_display); err != 0) {
    std::fprintf(
        stderr,
        "[ghastty] SubsurfacePresenter: wl_display error %d after present\n",
        err);
  }
}

void SubsurfacePresenter::setPosition(int x, int y) {
  if (!m_subsurface) return;
  if (x == m_lastX && y == m_lastY) return;
  wl_subsurface_set_position(m_subsurface, x, y);
  m_lastX = x;
  m_lastY = y;
  // Position is double-buffered on the parent surface — the caller
  // must trigger a parent commit (forceParentCommit on the GhosttySurface
  // side) for the change to land. We flush so the request is on the
  // wire when that happens.
  wl_display_flush(m_display);
}

void SubsurfacePresenter::hide() {
  if (!m_childSurface) return;
  // Attach NULL = no buffer. After commit + parent commit, the
  // subsurface contributes nothing to the compositor's frame.
  // Caller is responsible for forceParentCommit on its side.
  wl_surface_attach(m_childSurface, nullptr, 0, 0);
  wl_surface_commit(m_childSurface);
  wl_display_flush(m_display);
}

void SubsurfacePresenter::flushDisplay() {
  if (m_display) wl_display_flush(m_display);
}

bool SubsurfacePresenter::reattachCached() {
  if (!m_childSurface || !m_lastPresentedBuffer) return false;
  // Re-show whatever we had attached before `hide()`. The cached
  // wl_buffer survives across hide/show because the release
  // listener no-ops (see `bufferRelease`). The dmabuf backing the
  // buffer is still alive — libghostty owns the underlying
  // VkDeviceMemory until the next Target.deinit (resize), and
  // dma-buf kernel ref-counting keeps the pages pinned regardless
  // of our client-side state.
  //
  // The content may be one frame stale (whatever was rendered just
  // before Hide), but that's better than a transparent gap while
  // the renderer thread spins up its first new frame after Show —
  // the parent surface has WA_TranslucentBackground, so without a
  // re-attach the user sees through to whatever is behind the
  // window. The renderer's next frame overwrites this within
  // DRAW_INTERVAL.
  wl_surface_attach(m_childSurface, m_lastPresentedBuffer, 0, 0);
  wl_surface_damage_buffer(m_childSurface, 0, 0,
                           static_cast<int32_t>(m_lastPresentedWidth),
                           static_cast<int32_t>(m_lastPresentedHeight));
  // Register a frame callback so the consumer's pacing state machine
  // gets a "compositor is ready" event after this re-attach too —
  // otherwise a tab switch could leave m_compositorReady stuck false
  // (a stale frame callback from the pre-Hide commit may have been
  // discarded by the compositor on the NULL attach).
  if (!m_frameCallback) {
    m_frameCallback = wl_surface_frame(m_childSurface);
    if (m_frameCallback) {
      wl_callback_add_listener(m_frameCallback, &kFrameCallbackListener,
                               this);
    }
  }
  wl_surface_commit(m_childSurface);
  wl_display_flush(m_display);
  return true;
}

} // namespace wayland
