#pragma once

#include <QByteArray>

// Optional per-surface overrides applied only to the FIRST (parentless)
// surface of a freshly opened window. Used by the D-Bus activation /
// single-instance path so "open terminal here" (working directory) and `-e`
// (command) take effect for that one window without mutating the
// process-global app config. Empty fields mean "inherit the app config
// default" — matching libghostty's surface-config semantics where a null
// working_directory/command means "use config".
struct SurfaceInit {
  QByteArray workingDirectory;
  QByteArray command;

  bool empty() const { return workingDirectory.isEmpty() && command.isEmpty(); }
};
