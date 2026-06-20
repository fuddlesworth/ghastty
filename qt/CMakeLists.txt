cmake_minimum_required(VERSION 3.16)
# C is needed for the wayland-scanner-generated protocol code.
project(ghastty LANGUAGES CXX C)

# Ghastty: a Qt6 frontend for Ghostty that embeds libghostty through its
# C API. The renderer (OpenGL or Vulkan) is selected at RUNTIME — both
# paths are compiled and GhosttySurface picks one via ghostty_set_renderer
# (see its ctor). On the OpenGL path libghostty draws into a private
# QOpenGLContext FBO that is either exported zero-copy as a dmabuf
# (EglDmabufTarget → wl_subsurface) or read back into a QImage; on the
# Vulkan path frames come back as dmabuf fds (VK_KHR_external_memory_fd)
# presented via a wl_subsurface. Terminal pixels reach the screen via a
# subsurface (zero-copy) with the QWidget kept translucent so chrome
# composites on top. OpenGL draws on the GUI thread (the embedded apprt's
# mustDrawFromAppThread() is true for OpenGL).
#
# Build libghostty first, from the repo root. Use ReleaseFast: a Debug
# build of libghostty leaves the whole terminal core unoptimized and
# makes rendering and surface creation noticeably sluggish.
#
#   zig build -Dapp-runtime=none -Doptimize=ReleaseFast
#
# Then build, run, and (optionally) install this app:
#
#   cmake -S qt -B qt/build && cmake --build qt/build
#   ./qt/build/ghastty
#   cmake --install qt/build --prefix ~/.local

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

include(GNUInstallDirs)

find_package(Qt6 REQUIRED COMPONENTS Gui Widgets OpenGL DBus
  Multimedia Svg WaylandClient)
# WindowBlur + XkbTracker use qpa/qplatformnativeinterface.h to reach
# the wl_display / wl_surface / wl_seat for native compositor calls
# (blur, layer-shell screen pinning, raw wl_keyboard listeners). The
# Qt-internal GuiPrivate module is tied to a specific
# Qt build, but every consumer of these headers ends up here — there
# is no public alternative. Suppress the cosmetic
# `_qt_internal_show_private_module_warning` so the build is silent
# unless something genuinely fails. Detect the component when
# present; some distros ship the headers without the matching
# CMake config (older Debian) and we fall back to hand-wiring the
# include dir below.
set(QT_NO_PRIVATE_MODULE_WARNING ON)
find_package(Qt6 QUIET OPTIONAL_COMPONENTS GuiPrivate WaylandClientPrivate)

# LayerShellQt: the quick terminal is a wlr-layer-shell dropdown window.
find_package(LayerShellQt REQUIRED)

# KWin background-blur is applied through the native compositor via
# the org_kde_kwin_blur Wayland protocol. Qt6::GuiPrivate gives the
# QPA native-handle accessors.
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
# libEGL is needed by the OpenGL path's `EglDmabufTarget`, which uses
# EGL_MESA_image_dma_buf_export to export an FBO-backed texture as a
# dmabuf. With runtime renderer selection the OpenGL path is always
# compiled, so EGL is now unconditionally REQUIRED (see the
# `pkg_check_modules(EGL REQUIRED ...)` below). The
# Vulkan path gets dmabufs straight from `VK_KHR_external_memory_fd` and
# never calls into EGL.
# libxkbcommon: derive the unshifted Unicode codepoint for a key event
# from its XKB keycode, so libghostty's kitty encoder finds an entry for
# punctuation keys (Qt's ev->key() reports the SHIFTED symbol, e.g.
# Qt::Key_Colon for Shift+;).
pkg_check_modules(XKBCOMMON REQUIRED IMPORTED_TARGET xkbcommon)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)

# `ghastty_wayland_protocol(<basename> <header_var> <code_var>)` —
# Generates `<basename>-client-protocol.h` + `<basename>-protocol.c`
# in `CMAKE_CURRENT_BINARY_DIR` from `protocols/<basename>.xml` via
# `wayland-scanner`. Sets `<header_var>` and `<code_var>` in the
# caller's scope to the generated paths so the caller can hand them
# to `add_executable`'s source list.
#
# Each `add_custom_command` is independent — the `private-code`
# output `#include`s the `client-header` output, but CMake creates
# the dependency at target-source-list time when both files appear
# in `add_executable`. Mirrors the pre-collapse pattern (two custom
# commands per protocol) — only the boilerplate is gone.
function(ghastty_wayland_protocol basename header_var code_var)
  set(xml "${CMAKE_CURRENT_SOURCE_DIR}/protocols/${basename}.xml")
  set(hdr "${CMAKE_CURRENT_BINARY_DIR}/${basename}-client-protocol.h")
  set(src "${CMAKE_CURRENT_BINARY_DIR}/${basename}-protocol.c")
  add_custom_command(OUTPUT "${hdr}"
    COMMAND "${WAYLAND_SCANNER}" client-header "${xml}" "${hdr}"
    DEPENDS "${xml}" VERBATIM)
  add_custom_command(OUTPUT "${src}"
    COMMAND "${WAYLAND_SCANNER}" private-code "${xml}" "${src}"
    DEPENDS "${xml}" VERBATIM)
  set("${header_var}" "${hdr}" PARENT_SCOPE)
  set("${code_var}" "${src}" PARENT_SCOPE)
endfunction()

# Per-protocol notes:
#   - `blur` (`org_kde_kwin_blur`)             — KWin background-blur.
#   - `linux-dmabuf-v1`                        — Vulkan present path:
#       wrap libghostty's dmabuf fd in a `wl_buffer` for the
#       wayland::SubsurfacePresenter's `wl_surface`.
#   - `viewporter` (`wp_viewporter`)           — destination size in
#       surface-local coords; decouples the buffer's pixel dimensions
#       from how big the subsurface appears on screen (fractional
#       scaling).
#   - `fractional-scale-v1` (`wp_fractional_scale_v1`)
#       — compositor reports per-surface fractional scale (120ths).
#       Used as the authoritative scale for buffer sizing, avoiding
#       any sync lag with Qt's `devicePixelRatioF()` cache.
ghastty_wayland_protocol(blur                 BLUR_HEADER       BLUR_CODE)
ghastty_wayland_protocol(linux-dmabuf-v1      DMABUF_HEADER     DMABUF_CODE)
ghastty_wayland_protocol(viewporter           VIEWPORTER_HEADER VIEWPORTER_CODE)
ghastty_wayland_protocol(fractional-scale-v1  FRACSCALE_HEADER  FRACSCALE_CODE)
#   - `alpha-modifier-v1` (`wp_alpha_modifier_v1`)
#       — compositor-side per-surface alpha multiplier. QtWayland has no
#       built-in setWindowOpacity equivalent (the QPA plugin warns
#       "This plugin does not support setting window opacity" on every
#       call), so QuickTerminal's fade-in/out drives this protocol
#       directly. Supported on KWin, wlroots ≥0.17, Hyprland; NOT yet
#       on mutter/GNOME.
ghastty_wayland_protocol(alpha-modifier-v1    ALPHAMOD_HEADER   ALPHAMOD_CODE)

# libghostty is built out-of-tree by Zig.
get_filename_component(GHOSTTY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(GHOSTTY_LIB_DIR "${GHOSTTY_ROOT}/zig-out/lib")
set(GHOSTTY_SO "${GHOSTTY_LIB_DIR}/ghostty-internal.so")

# GHASTTY_VARIANT is OBSOLETE. The renderer is now selected at RUNTIME
# (see GhosttySurface's ghostty_set_renderer wiring); both render paths
# are always compiled and the linked libghostty must contain both
# backends (`zig build -Dapp-runtime=none` on Linux). This cache var no
# longer affects the build — it's retained only so existing
# `-DGHASTTY_VARIANT=...` invocations don't error. The validation below
# keeps rejecting typos for those callers.
set(GHASTTY_VARIANT "opengl" CACHE STRING
    "Obsolete (renderer is selected at runtime); retained for back-compat")
set_property(CACHE GHASTTY_VARIANT PROPERTY STRINGS opengl vulkan)
if(NOT GHASTTY_VARIANT STREQUAL "opengl" AND
   NOT GHASTTY_VARIANT STREQUAL "vulkan")
  message(FATAL_ERROR
    "GHASTTY_VARIANT='${GHASTTY_VARIANT}' is invalid; "
    "must be 'opengl' or 'vulkan'.")
endif()

# The renderer (OpenGL vs Vulkan) is now selected at RUNTIME: both code
# paths are compiled in and `GhosttySurface` picks per the libghostty
# `renderer` config plus a Vulkan-availability probe, calling
# `ghostty_set_renderer()` so the core constructs the matching backend.
# This requires a libghostty that compiles both backends (Linux
# `zig build -Dapp-runtime=none`). GHASTTY_VARIANT is retained only so
# existing `-DGHASTTY_VARIANT=...` invocations don't error; it no longer
# affects the build.

# libEGL (opengl/EglDmabufTarget.cpp's zero-copy export) is now always
# required since the OpenGL path is always compiled.
pkg_check_modules(EGL REQUIRED IMPORTED_TARGET egl)

if(NOT EXISTS "${GHOSTTY_SO}")
  message(FATAL_ERROR
    "libghostty not found at ${GHOSTTY_SO}\n"
    "Build it first from the repo root: zig build -Dapp-runtime=none")
endif()

# The .so's SONAME is libghostty.so but it is installed as
# ghostty-internal.so. Create a symlink in the build tree (NOT in the
# Zig output dir, which is the source tree from CMake's perspective)
# so the loader finds it under the SONAME the binary links against.
set(GHOSTTY_LINK_DIR "${CMAKE_CURRENT_BINARY_DIR}/lib")
set(GHOSTTY_LINK_SO "${GHOSTTY_LINK_DIR}/libghostty.so")
add_custom_command(OUTPUT "${GHOSTTY_LINK_SO}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${GHOSTTY_LINK_DIR}"
  COMMAND "${CMAKE_COMMAND}" -E create_symlink
    "${GHOSTTY_SO}" "${GHOSTTY_LINK_SO}"
  DEPENDS "${GHOSTTY_SO}" VERBATIM)
add_custom_target(ghostty_link DEPENDS "${GHOSTTY_LINK_SO}")

add_executable(ghastty
  src/main.cpp
  src/actions/ActionDispatcher.cpp
  src/actions/ChromeActions.cpp
  src/actions/InputActions.cpp
  src/actions/SplitActions.cpp
  src/actions/SystemActions.cpp
  src/actions/TabActions.cpp
  src/actions/WindowActions.cpp
  src/app/GhosttyApp.cpp
  src/bell/BellPlayer.cpp
  src/config/Config.cpp
  src/CommandPalette.cpp
  src/GhosttySurface.cpp
  src/GlobalShortcuts.cpp
  src/InspectorWindow.cpp
  src/input/XkbState.cpp
  src/MainWindow.cpp
  src/os/Systemd.cpp
  src/dbus/Activation.cpp
  src/OverlayScrollbar.cpp
  src/quickterm/QuickTerminal.cpp
  src/SearchBar.cpp
  src/TabWidget.cpp
  src/Toast.cpp
  src/undo/UndoStack.cpp
  src/Util.cpp
  src/wayland/AlphaModifier.cpp
  src/wayland/SubsurfacePresenter.cpp
  src/WindowBlur.cpp
  src/XkbTracker.cpp
  "${BLUR_CODE}"
  "${BLUR_HEADER}"
  "${DMABUF_CODE}"
  "${DMABUF_HEADER}"
  "${VIEWPORTER_CODE}"
  "${VIEWPORTER_HEADER}"
  "${FRACSCALE_CODE}"
  "${FRACSCALE_HEADER}"
  "${ALPHAMOD_CODE}"
  "${ALPHAMOD_HEADER}"
)

# Both render paths are compiled now (runtime selection): the Vulkan
# host glue and the OpenGL EGL-dmabuf target. GhosttySurface picks
# between them per frame on `m_useVulkan`.
target_sources(ghastty PRIVATE
  src/vulkan/Host.cpp
  src/opengl/EglDmabufTarget.cpp)

# Embed the app icon so it is available even running from the build tree.
qt_add_resources(ghastty "appicon"
  PREFIX "/"
  BASE dist
  FILES dist/ghastty.svg)

target_include_directories(ghastty PRIVATE
  "${GHOSTTY_ROOT}/include"
  "${CMAKE_CURRENT_BINARY_DIR}"  # generated blur-client-protocol.h
)

add_dependencies(ghastty ghostty_link)

target_link_libraries(ghastty PRIVATE
  Qt6::Gui
  Qt6::Widgets
  Qt6::OpenGL
  Qt6::DBus
  Qt6::Multimedia
  Qt6::Svg
  PkgConfig::WAYLAND_CLIENT
  PkgConfig::XKBCOMMON
  LayerShellQt::Interface
  "${GHOSTTY_LINK_SO}"
)

# Both render paths are compiled, so link both loaders: libEGL for the
# OpenGL EGL-dmabuf export and libvulkan for the Vulkan host glue.
# Runtime renderer selection means a host needs both available (the
# Vulkan path degrades gracefully if the loader/driver can't bring up a
# device — GhosttySurface then falls back to OpenGL).
target_link_libraries(ghastty PRIVATE PkgConfig::EGL vulkan)

# Hook up the private QPA headers (see find_package above).
#
# Qt6::WaylandClientPrivate gives us QtWaylandClient::QWaylandWindow,
# which we cast the QPA platform window to in GhosttySurface to call
# `commit()` directly — that forces a parent wl_surface commit at the
# moment our subsurface state is ready, instead of waiting on Qt's
# backing-store flush which never fires for our translucent widget.
if(TARGET Qt6::WaylandClientPrivate)
  target_link_libraries(ghastty PRIVATE Qt6::WaylandClientPrivate)
endif()
if(TARGET Qt6::GuiPrivate)
  target_link_libraries(ghastty PRIVATE Qt6::GuiPrivate)
else()
  # Debian fallback: locate qplatformnativeinterface.h and add its
  # parent dir as a private include (the header lives at
  # <prefix>/QtGui/<version>/QtGui/qpa/qplatformnativeinterface.h, so we
  # add the dir containing the `qpa` subfolder).
  # Multi-arch Debian uses ${CMAKE_LIBRARY_ARCHITECTURE} (e.g.
  # aarch64-linux-gnu) for include and lib subdirs. Hardcoding a list
  # missed armhf/riscv64; deriving from the toolchain handles every
  # arch the Qt 6 packages support.
  find_path(QT_QPA_INCLUDE_DIR
    NAMES qpa/qplatformnativeinterface.h
    HINTS
      "${Qt6Gui_PRIVATE_INCLUDE_DIRS}"
      "${Qt6_DIR}/../../../include/${CMAKE_LIBRARY_ARCHITECTURE}/qt6/QtGui/${Qt6_VERSION}/QtGui"
      "${Qt6_DIR}/../../../include/qt6/QtGui/${Qt6_VERSION}/QtGui"
    PATH_SUFFIXES
      "qt6/QtGui/${Qt6_VERSION}/QtGui"
  )
  if(NOT QT_QPA_INCLUDE_DIR)
    message(FATAL_ERROR
      "Qt6 private QPA headers not found.\n"
      "Install qt6-base-private-dev (Debian/Ubuntu) or the equivalent "
      "Qt 6 private headers package.")
  endif()
  message(STATUS "Using Qt private include dir: ${QT_QPA_INCLUDE_DIR}")
  target_include_directories(ghastty PRIVATE "${QT_QPA_INCLUDE_DIR}")
endif()

# RPATH:
# - Build tree: libghostty.so lives in our build dir (a symlink to the
#   actual zig-out artifact), and the .so's NEEDED entries also point
#   into zig-out/lib for transitive deps.
# - Installed: libghostty.so lives next to the binary ($ORIGIN/../lib).
# One runtime-selectable binary now (no compile-time variants): a single
# `ghastty` + `libghostty.so` containing both backends.
set_target_properties(ghastty PROPERTIES
  BUILD_RPATH "${GHOSTTY_LINK_DIR};${GHOSTTY_LIB_DIR}"
  INSTALL_RPATH "$ORIGIN/../${CMAKE_INSTALL_LIBDIR}"
)

# --- install ---------------------------------------------------------
install(TARGETS ghastty RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")

# libghostty.so the binary links against (SONAME is libghostty.so).
install(FILES "${GHOSTTY_SO}"
  DESTINATION "${CMAKE_INSTALL_LIBDIR}"
  RENAME libghostty.so)

# Desktop entry. Its basename MUST equal the D-Bus app id (com.ghastty.ghastty)
# for window↔launcher association and DBusActivatable to work.
install(FILES dist/com.ghastty.ghastty.desktop
  DESTINATION "${CMAKE_INSTALL_DATADIR}/applications")

# The custom scalable app icon, named after the app id so the desktop entry's
# Icon=com.ghastty.ghastty and the Wayland app-id resolve to it.
install(FILES dist/ghastty.svg
  DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps"
  RENAME com.ghastty.ghastty.svg)

# AppStream metainfo so software centers list the app.
install(FILES dist/com.ghastty.ghastty.metainfo.xml
  DESTINATION "${CMAKE_INSTALL_DATADIR}/metainfo")

# KDE Dolphin "Open Ghastty Here" service menu (right-click in a folder).
# Installed under the app id, matching upstream's servicemenu naming.
install(FILES dist/ghastty_dolphin.desktop
  DESTINATION "${CMAKE_INSTALL_DATADIR}/kio/servicemenus"
  RENAME com.ghastty.ghastty.desktop)

# D-Bus session service file so the bus can activate us on demand
# (DBusActivatable). The Exec needs the installed binary's absolute path.
set(GHASTTY_EXEC "${CMAKE_INSTALL_FULL_BINDIR}/ghastty")
configure_file(dist/com.ghastty.ghastty.service.in
  "${CMAKE_CURRENT_BINARY_DIR}/com.ghastty.ghastty.service" @ONLY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/com.ghastty.ghastty.service"
  DESTINATION "${CMAKE_INSTALL_DATADIR}/dbus-1/services")
