#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

// (The atexit hook to ghastty_glslang_finalize_process that used
// to live here was removed: now that build-time SPV precompile
// is in place, the runtime libghostty no longer calls the glslang
// shim at all for built-ins, so the shim's symbols get DCE'd out
// of libghostty.so. The cosmetic FinalizeProcess+popAll cleanup
// also didn't reduce heaptrack's reported leak in practice, so
// the call wasn't pulling its weight anyway.)

#include <QApplication>
#include <QCoreApplication>
#include <QIcon>
#include <QSocketNotifier>
#include <QSurfaceFormat>
#include <QTimer>

#include "app/GhosttyApp.h"
#include "config/Config.h"
#include "dbus/Activation.h"
#include "GlobalShortcuts.h"
#include "MainWindow.h"
#include "Util.h"
#include "os/Systemd.h"
#include "ghostty.h"

// True when any argv entry starts with `+` — i.e. the user invoked a
// libghostty CLI action (`+show-config`, `+list-fonts`, `+version`, …).
// We detect early so the CLI path can run without paying the cost of
// constructing a QApplication (which opens a Wayland connection
// only to exit).
static bool isCliActionInvocation(int argc, char **argv) {
  for (int i = 1; i < argc; ++i) {
    if (argv[i] && argv[i][0] == '+') return true;
  }
  return false;
}

// Default-disable MangoHud for this process. The Vulkan implicit
// layer hooks every vkQueueSubmit / vkAcquireNextImage / etc. to
// render its own overlay, which on this branch's animated-shader
// + multi-pane workload added ~25% extra main-thread CPU at idle
// (measured against a baseline of ~10% for the Wayland-buffer
// cache path). For a terminal, that's a steep tax on a feature
// users typically associate with games. A system-wide MANGOHUD=1
// (common in `~/.profile` for users who want the HUD on games) is
// explicitly OVERRIDDEN here — the user is invoking ghastty, not
// a game, and we don't want them to silently pay 25% extra CPU.
//
// Two layers of MangoHud's loading model:
//   - VK_LOADER_LAYERS_DISABLE: Vulkan loader skips the layer
//     entirely (no interception overhead).
//   - DISABLE_MANGOHUD: belt-and-suspenders if the loader didn't
//     honor the env var (older loaders) or another runtime force-
//     loaded the layer through a different path.
//
// Escape hatch: GHASTTY_ALLOW_OVERLAY=1 skips the guard entirely
// so a user who genuinely wants MangoHud on the terminal (e.g.
// debugging the renderer with the HUD's frame-time graph) can
// opt back in without removing the layer JSON system-wide.
//
// setenv overwrite=1 throughout: the whole point is to override a
// pre-existing MANGOHUD=1 / DISABLE_MANGOHUD=0 / etc.
static void defaultDisableMangoHud() {
  if (const char *opt = ::getenv("GHASTTY_ALLOW_OVERLAY");
      opt && opt[0] == '1') return;
  ::setenv("MANGOHUD", "0", 1);
  ::setenv("DISABLE_MANGOHUD", "1", 1);
  ::setenv("VK_LOADER_LAYERS_DISABLE", "*MANGOHUD*", 1);
}

// Reload the configuration on SIGUSR2 — parity with the GTK apprt
// (application.zig handleSigusr2) and the documented Linux flow
// `systemctl --user reload app-ghastty@<id>.service`, which sends SIGUSR2 to
// the main process. The Qt apprt previously installed no handler, so SIGUSR2
// hit the default disposition and TERMINATED ghastty instead of reloading.
//
// A Unix signal handler runs in an async, mostly-unsafe context, so it must not
// touch Qt directly. Standard self-pipe trick: the handler only write()s a byte
// (async-signal-safe); a QSocketNotifier turns that into a normal main-thread
// callback that runs the real, app-scoped reload (all windows).
namespace {
int g_reloadPipe[2] = {-1, -1};

void onSigusr2(int) {
  const char b = 1;
  const ssize_t n = ::write(g_reloadPipe[1], &b, 1);
  (void)n;  // nothing safe to do on failure inside a signal handler
}

void installReloadSignalHandler(QObject *parent) {
  if (::pipe(g_reloadPipe) != 0) return;
  for (const int fd : g_reloadPipe) {
    // Non-blocking so the handler's write() and the drain read() never block;
    // CLOEXEC so the self-pipe doesn't leak into spawned shells/ptys.
    ::fcntl(fd, F_SETFL, ::fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    ::fcntl(fd, F_SETFD, ::fcntl(fd, F_GETFD, 0) | FD_CLOEXEC);
  }

  auto *notifier =
      new QSocketNotifier(g_reloadPipe[0], QSocketNotifier::Read, parent);
  QObject::connect(notifier, &QSocketNotifier::activated, parent, []() {
    char buf[16];
    while (::read(g_reloadPipe[0], buf, sizeof(buf)) > 0) {
    }  // drain coalesced signals
    MainWindow::reloadConfigGlobal();
  });

  struct sigaction sa = {};
  sa.sa_handler = onSigusr2;
  ::sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  ::sigaction(SIGUSR2, &sa, nullptr);
}
}  // namespace

// Derive what a launch wants from argv: the working directory
// (--working-directory=) and/or the command to run (-e ...). These are the
// pieces a single-instance secondary forwards to the running primary so
// "open terminal here" and `ghastty -e cmd` open the right window. Everything
// else (full config parsing) is left to libghostty in the primary.
static dbus::LaunchIntent buildLaunchIntent(int argc, char **argv) {
  dbus::LaunchIntent intent;
  for (int i = 1; i < argc; ++i) {
    const char *a = argv[i];
    if (!a) continue;
    if (std::strncmp(a, "--working-directory=", 20) == 0) {
      intent.workingDirectory = a + 20;
    } else if (std::strcmp(a, "-e") == 0) {
      // Everything after -e is the command. Shell-quote each token (shared
      // Util::shellQuote) so the `/bin/sh -c` that libghostty uses preserves
      // argument boundaries (e.g. `-e vim "a b"`).
      QString cmd;
      for (int j = i + 1; j < argc; ++j) {
        if (!argv[j]) continue;
        if (!cmd.isEmpty()) cmd += QLatin1Char(' ');
        cmd += shellQuote(QString::fromLocal8Bit(argv[j]));
      }
      intent.command = cmd.toUtf8();
      break;
    }
  }
  return intent;
}

// Resolve single-instance mode exactly like the GTK apprt's
// `gtk-single-instance` config (see Config.zig gtk-single-instance docs +
// finalize, and probableCliEnvironment). libghostty built with
// `-Dapp-runtime=none` does NOT resolve `detect` (that only runs for the gtk
// runtime), so we reproduce the heuristic here:
//   - true  -> single instance
//   - false -> separate process per launch
//   - detect -> single instance UNLESS this looks like a CLI launch, i.e.
//               TERM_PROGRAM is non-empty (launched from a graphical terminal,
//               wants a dedicated instance) or any CLI arguments were given
//               (custom config must not be inherited from a running instance).
// Requires the config to already be loaded (GhosttyApp::ensureInitialized).
//
// `had_cli_args` MUST be computed from the original arg count, BEFORE
// QApplication strips its own options (-style, -platform, …). GTK's heuristic
// counts the raw argv (`std.os.argv.len > 1`); counting the post-strip argc
// would let a Qt-only flag silently flip the mode.
static bool resolveSingleInstance(bool had_cli_args) {
  const QString v = config::string("gtk-single-instance");
  if (v == QLatin1String("true")) return true;
  if (v == QLatin1String("false")) return false;

  // detect (the default; also the fallback for any unexpected value).
  const char *term_program = ::getenv("TERM_PROGRAM");
  const bool probable_cli =
      (term_program && term_program[0] != '\0') || had_cli_args;
  return !probable_cli;
}

int main(int argc, char **argv) {
  // Strip our private D-Bus-activation marker (injected by the dbus.service
  // Exec) before anything else parses argv — Qt and libghostty must never see
  // it. Records that we were activation-launched (see startedByActivation()).
  argc = dbus::consumeActivationFlag(argc, argv);

  // Snapshot whether the user passed any CLI args NOW — before QApplication's
  // ctor strips its own options from argv. Drives the `gtk-single-instance`
  // detect heuristic (see resolveSingleInstance).
  const bool had_cli_args = argc > 1;

  // Set the env BEFORE Qt's QApplication ctor (which can probe
  // GL/Vulkan via QPA) and before the CLI action path (since
  // libghostty action handlers may also touch the renderer).
  defaultDisableMangoHud();

  // (Build-time SPV precompile means the runtime libghostty no
  // longer invokes glslang for built-in shaders, so the per-
  // thread TPoolAllocator pages we used to leak from first-
  // surface init don't exist on the Vulkan variant anymore. No
  // atexit cleanup needed.)

  // CLI action fast path: skip Qt entirely. ghostty_init parses argv
  // for the `+action`; ghostty_cli_try_action runs it and exits the
  // process. If something fails (unknown action, multiple actions),
  // ghostty_init returns non-zero and we surface the same help hint
  // macOS does.
  if (isCliActionInvocation(argc, argv)) {
    if (ghostty_init(static_cast<uintptr_t>(argc), argv) != GHOSTTY_SUCCESS) {
      std::fprintf(
          stderr,
          "Ghastty failed to initialize! If you're executing Ghastty from\n"
          "the command line then this is usually because an invalid action\n"
          "or multiple actions were specified. Actions start with the `+`\n"
          "character.\n\n"
          "View all available actions by running `ghastty +help`.\n");
      return 1;
    }
    ghostty_cli_try_action();
    // ghostty_cli_try_action exits the process when an action ran; if
    // it returned, no `+action` was actually parseable from argv —
    // bail out rather than fall through to the GUI with leftover
    // junk in argv.
    std::fprintf(stderr, "[ghastty] no CLI action ran; aborting\n");
    return 1;
  }

  // Use the display's true fractional scale rather than rounding it up
  // (Wayland otherwise reports e.g. 2.0 for a 1.2x display, which scales
  // the terminal up).
  QGuiApplication::setHighDpiScaleFactorRoundingPolicy(
      Qt::HighDpiScaleFactorRoundingPolicy::PassThrough);

  // Multiple GL surfaces compose reliably with a shared GL context.
  QApplication::setAttribute(Qt::AA_ShareOpenGLContexts);

  // Ghostty's OpenGL renderer requires at least OpenGL 4.3 core.
  QSurfaceFormat fmt;
  fmt.setRenderableType(QSurfaceFormat::OpenGL);
  fmt.setProfile(QSurfaceFormat::CoreProfile);
  fmt.setVersion(4, 3);
  fmt.setAlphaBufferSize(8);  // allow a translucent terminal background
  QSurfaceFormat::setDefaultFormat(fmt);

  QApplication app(argc, argv);

  // QSettings storage path keys: applicationName + organizationName.
  // Used by the inspector window's geometry autosave (and any future
  // QSettings-backed UI state) — the keys go to
  // ~/.config/ghastty/ghastty.conf. We pass the same string to both
  // because we don't run a multi-app suite under a parent
  // organization.
  QCoreApplication::setApplicationName(QStringLiteral("ghastty"));
  QCoreApplication::setOrganizationName(QStringLiteral("ghastty"));

  // Match the installed com.ghastty.ghastty.desktop: this becomes the Wayland
  // app-id so the compositor associates the window with the desktop entry —
  // taskbar icon, launcher identity. It MUST equal the desktop file basename
  // and the D-Bus bus name (dbus::kAppId) for window↔launcher association and
  // DBusActivatable to work; see qt/dist/com.ghastty.ghastty.* and
  // qt/src/dbus/Activation.h.
  QGuiApplication::setDesktopFileName(QString::fromLatin1(dbus::kAppId));

  // The window icon, embedded so it works even running from the build tree
  // (when the desktop entry / icon theme are not yet installed).
  QGuiApplication::setWindowIcon(QIcon(QStringLiteral(":/ghastty.svg")));

  // We keep the user's system widget style rather than forcing Fusion.
  // Some styles dim and blur translucent windows, which masks the
  // terminal's own background-opacity: Kvantum themes do this when
  // `blurring`/`reduce_window_opacity` are set. The fix belongs in the
  // style's config, not here — for Kvantum, add "ghostty" to the
  // theme's `opaque` app list (the same opt-out video players use).

  // ghostty_init must run *after* QApplication: QApplication strips its
  // own options (e.g. -style) out of argv in place, and libghostty later
  // re-scans that array for CLI config — scanning the pre-strip array
  // would walk past its end into freed/null entries. The CLI-action
  // fast path above already initialised libghostty for `+action`
  // invocations and exited; everything reaching here is a GUI launch.
  if (ghostty_init(static_cast<uintptr_t>(argc), argv) != GHOSTTY_SUCCESS) {
    std::fprintf(stderr,
                 "[ghastty] ghostty_init failed; check `ghastty +help`\n");
    return 1;
  }

  // Build the libghostty app + load config now so the single-instance decision
  // can read `gtk-single-instance`. Idempotent; later newWindow() calls reuse
  // it. (A D-Bus-activated primary that skips self-open relies on this so its
  // Activate/Open handler has a ready app.)
  if (!GhosttyApp::instance().ensureInitialized()) {
    std::fprintf(stderr, "[ghastty] initialization failed\n");
    return 1;
  }

  // Single-instance + D-Bus activation (parity with GApplication on GTK).
  // When single-instance is enabled we own the session-bus name
  // com.ghastty.ghastty and export org.freedesktop.Application; a second
  // launch forwards its intent to the running instance and exits instead of
  // spawning a duplicate. Honors `gtk-single-instance` just like GTK.
  bool selfOpenInitialWindow = true;
  if (resolveSingleInstance(had_cli_args)) {
    switch (dbus::acquire(buildLaunchIntent(argc, argv))) {
      case dbus::Role::Secondary:
        // Already forwarded to the primary; nothing more to do.
        return 0;
      case dbus::Role::Primary:
        // When started BY activation, don't self-open here (that would double
        // up): per the org.freedesktop.Application contract the activating
        // launcher delivers exactly one activation message for this launch —
        // Activate when there are no files, or Open when there are — and our
        // handler opens the first window in response. This mirrors
        // GApplication emitting `activate` once; unlike GApplication we rely
        // on the launcher honoring that one-message contract rather than
        // coalescing internally. A direct/Exec launch self-opens below.
        if (dbus::startedByActivation()) {
          selfOpenInitialWindow = false;
          // The activation-delivered window is an explicit user request, so it
          // must always map — spend the `initial-window` bootstrap gate now so
          // it isn't suppressed under `initial-window=false`.
          MainWindow::markInitialWindowConsumed();
        }
        break;
      case dbus::Role::Standalone:
        break;  // no session bus; behave like the old multi-process app
    }
  }

  // The Vulkan host is intentionally NOT bootstrapped here: doing it
  // before any window is mapped on Wayland can interact badly with
  // Qt's Wayland integration (the VkInstance starts grabbing display
  // resources before Qt has finished its own connection setup, and
  // on some compositor + driver combos the result is a process that
  // runs but never actually displays a window). It's brought up
  // lazily on the first surface that needs it — see
  // `GhosttySurface.cpp`.

  // initial-window: when false, start headless (no window mapped at
  // launch). Combined with quit-after-last-window-closed=false this
  // is how a user runs ghastty as a daemon for the global quick-
  // terminal shortcut. The first MainWindow::newWindow internally
  // checks the config and skips show() — so the libghostty app +
  // config still get built, but no QWindow ever appears.
  //
  // selfOpenInitialWindow is false only when we were D-Bus-activated: the
  // app + config are bootstrapped lazily by the first newWindow() the
  // incoming Activate/Open handler runs once the event loop starts.
  if (selfOpenInitialWindow && !MainWindow::newWindow(nullptr)) {
    std::fprintf(stderr, "[ghastty] window initialization failed\n");
    return 1;
  }

  // Register global shortcuts via the XDG portal so the quick terminal
  // can be toggled while Ghostty is unfocused. Keys are assigned by the
  // desktop (KDE System Settings -> Shortcuts).
  GlobalShortcuts globalShortcuts;
  QObject::connect(&globalShortcuts, &GlobalShortcuts::activated,
                   [](const QString &id) {
                     if (id == QLatin1String("toggle-quick-terminal"))
                       GhosttyApp::instance().toggleQuickTerminal();
                     else if (id == QLatin1String("toggle-visibility"))
                       GhosttyApp::instance().toggleVisibility();
                   });

  // Reload config on SIGUSR2 so `systemctl --user reload` (and matugen's
  // theme regen) recolors every open window live, no restart. See above.
  installReloadSignalHandler(&app);

  // Safety net for the D-Bus-activated path: we declined to self-open above
  // expecting the activating launcher to deliver an Activate/Open that maps
  // the first window. A conforming launcher always does, immediately once the
  // loop runs. But if none ever arrives — e.g. the internal
  // --ghastty-dbus-activated flag was passed by hand with no activating
  // client — open a window after a short grace period so we never sit
  // windowless and unresponsive. Gated on activationHandled() (not window
  // count) so deliberately closing the activation window doesn't reopen one.
  if (!selfOpenInitialWindow) {
    QTimer::singleShot(1500, &app, [] {
      if (!dbus::activationHandled()) MainWindow::newWindow(nullptr);
    });
  }

  // Tell systemd we finished starting up. Required for Type=notify units: if a
  // user runs ghastty under a hand-written systemd user unit (e.g. the
  // `app-ghastty@<id>.service` the SIGUSR2 reload flow targets), systemd waits
  // for this notify. No-op when NOTIFY_SOCKET is unset, which includes the
  // shipped D-Bus *session* activation service (it has no systemd unit).
  systemd::notifyReady();

  return app.exec();
}
