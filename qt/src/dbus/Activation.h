#pragma once

#include <QByteArray>

// D-Bus activation + single-instance, the Qt-native equivalent of what GTK
// gets for free from GApplication (see src/apprt/gtk/class/application.zig and
// src/apprt/gtk/ipc/DBus.zig).
//
// On the session bus we own the well-known name `com.ghastty.ghastty` and
// export the standard `org.freedesktop.Application` interface
// (Activate / Open / ActivateAction) at `/com/ghastty/ghastty`. That is what
// makes `DBusActivatable=true` in the desktop file work and what lets a second
// launch forward its intent to the already-running instance instead of
// spawning a duplicate process.
//
// The identity strings here MUST match the installed desktop file basename
// and the dbus.service `Name=` (see qt/dist/com.ghastty.ghastty.*).
namespace dbus {

inline constexpr char kAppId[] = "com.ghastty.ghastty";
inline constexpr char kObjectPath[] = "/com/ghastty/ghastty";

// What a launch wants to do, derived from argv: open a window, optionally in a
// specific working directory and/or running a specific command (`-e`).
struct LaunchIntent {
  QByteArray workingDirectory;  // from --working-directory=
  QByteArray command;           // from -e ...
};

enum class Role {
  // We own the bus name and have exported org.freedesktop.Application. This
  // process is the real instance and should run its event loop.
  Primary,
  // Another instance already owns the name; we forwarded `intent` to it and
  // the caller should exit immediately without opening any window.
  Secondary,
  // No usable session bus — single-instance/activation is unavailable. The
  // caller should run normally (open a window) but without any IPC.
  Standalone,
};

// True if this process was started by D-Bus/desktop activation rather than a
// direct/Exec launch. Such a process must NOT self-open a window: the
// activating launcher will deliver exactly one Activate/Open call, mirroring
// GApplication's "remote-activated once" semantics. Detected via the private
// flag injected by the dbus.service Exec and, as a fallback, the
// DBUS_STARTER_BUS_TYPE env var dbus-daemon sets for activated services.
bool startedByActivation();

// Strip the private `--ghastty-dbus-activated` token from argv in place (so
// libghostty never sees it) and remember that we were activated. Call before
// ghostty_init. Returns the possibly-reduced argc.
int consumeActivationFlag(int argc, char **argv);

// Acquire the bus name and, on success, export org.freedesktop.Application.
// On Secondary, forwards `intent` to the running primary before returning.
Role acquire(const LaunchIntent &intent);

}  // namespace dbus
