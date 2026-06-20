#include "Activation.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <QByteArray>
#include <QDBusAbstractAdaptor>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QFileInfo>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>

#include "../MainWindow.h"

namespace dbus {
namespace {

// Set when we detect (or are told via the private flag) that this process was
// started by D-Bus / desktop activation.
bool g_activated = false;

// Private platform_data keys we use to carry "open here" / `-e` intent across
// the bus from a forwarding secondary to the primary. Namespaced with "x-" so
// they can't collide with the well-known platform_data keys
// (desktop-startup-id, activation-token) that launchers set.
constexpr char kKeyWorkingDirectory[] = "x-ghastty-working-directory";
constexpr char kKeyCommand[] = "x-ghastty-command";

// Build the per-window override for a new window from an Activate/ActivateAction
// platform_data map (the inverse of forward()'s encoding).
SurfaceInit initFromPlatformData(const QVariantMap &platform_data) {
  SurfaceInit init;
  const auto wd = platform_data.value(QString::fromLatin1(kKeyWorkingDirectory));
  if (wd.isValid()) init.workingDirectory = wd.toString().toUtf8();
  const auto cmd = platform_data.value(QString::fromLatin1(kKeyCommand));
  if (cmd.isValid()) init.command = cmd.toString().toUtf8();
  return init;
}

// Open one window honoring an optional working dir / command override.
void openWindow(const SurfaceInit &init) {
  if (init.empty())
    MainWindow::newWindow(nullptr);
  else
    MainWindow::newWindow(nullptr, init);
}

// org.freedesktop.Application — the standard single-instance/activation
// interface. GApplication exports this automatically; we do it by hand. All
// slots run on the main thread (QtDBus dispatches through the event loop), so
// they may touch the GUI directly.
class AppAdaptor : public QDBusAbstractAdaptor {
  Q_OBJECT
  Q_CLASSINFO("D-Bus Interface", "org.freedesktop.Application")

 public:
  explicit AppAdaptor(QObject *parent) : QDBusAbstractAdaptor(parent) {}

 public slots:
  // The user launched/activated the app. Like GTK's `activate` handler
  // (application.zig), this always opens a new window. Our forwarding
  // secondaries piggyback working-dir/command in platform_data.
  void Activate(const QVariantMap &platform_data) {
    openWindow(initFromPlatformData(platform_data));
  }

  // Open the given URIs. For a terminal we interpret each LOCAL location as a
  // place to open a window at: a directory becomes the working directory; a
  // file uses its containing directory. Non-local URIs (http://, ssh://, …)
  // have no meaningful working directory, so we just open a plain window for
  // them rather than resolving the raw URI string against our own CWD.
  void Open(const QStringList &uris, const QVariantMap &platform_data) {
    Q_UNUSED(platform_data);
    if (uris.isEmpty()) {
      openWindow(SurfaceInit{});
      return;
    }
    for (const QString &uri : uris) {
      const QUrl url(uri);
      if (!url.isLocalFile()) {
        openWindow(SurfaceInit{});
        continue;
      }
      QFileInfo info(url.toLocalFile());
      const QString dir = info.isDir() ? info.absoluteFilePath()
                                       : info.absolutePath();
      SurfaceInit init;
      if (!dir.isEmpty()) init.workingDirectory = dir.toUtf8();
      openWindow(init);
    }
  }

  // Invoke a named desktop action (the `Actions=` entries in the desktop
  // file). We expose "new-window"; everything else is ignored.
  void ActivateAction(const QString &action_name, const QVariantList &parameter,
                      const QVariantMap &platform_data) {
    Q_UNUSED(parameter);
    if (action_name == QLatin1String("new-window"))
      openWindow(initFromPlatformData(platform_data));
    else
      std::fprintf(stderr, "[ghastty] ignoring unknown D-Bus action: %s\n",
                   action_name.toUtf8().constData());
  }
};

// Forward this launch's intent to the running primary instance. We always call
// Activate (matching a plain re-launch / taskbar activation = new window) and
// ride any working-dir/command override in platform_data — the primary's
// Activate slot decodes it. Returns true if the primary acknowledged; false on
// any D-Bus error (e.g. the owner is wedged), so the caller can fall back to
// opening a window itself rather than silently exiting with no window.
bool forward(const LaunchIntent &intent) {
  QVariantMap platform_data;
  if (!intent.workingDirectory.isEmpty())
    platform_data.insert(QString::fromLatin1(kKeyWorkingDirectory),
                         QString::fromUtf8(intent.workingDirectory));
  if (!intent.command.isEmpty())
    platform_data.insert(QString::fromLatin1(kKeyCommand),
                         QString::fromUtf8(intent.command));

  QDBusMessage msg = QDBusMessage::createMethodCall(
      QString::fromLatin1(kAppId), QString::fromLatin1(kObjectPath),
      QStringLiteral("org.freedesktop.Application"),
      QStringLiteral("Activate"));
  msg << QVariant::fromValue(platform_data);

  // Bounded timeout so a hung primary doesn't block the launch for the default
  // ~25s; on failure we fall back to a standalone window (see acquire).
  const QDBusMessage reply =
      QDBusConnection::sessionBus().call(msg, QDBus::Block, 3000);
  if (reply.type() == QDBusMessage::ErrorMessage) {
    std::fprintf(stderr,
                 "[ghastty] failed to forward to running instance: %s\n",
                 reply.errorMessage().toUtf8().constData());
    return false;
  }
  return true;
}

}  // namespace

bool startedByActivation() {
  if (g_activated) return true;
  // dbus-daemon sets these for services it activates directly.
  const char *t = ::getenv("DBUS_STARTER_BUS_TYPE");
  return t != nullptr && t[0] != '\0';
}

int consumeActivationFlag(int argc, char **argv) {
  int out = 0;
  for (int i = 0; i < argc; ++i) {
    if (argv[i] && std::strcmp(argv[i], "--ghastty-dbus-activated") == 0) {
      g_activated = true;
      continue;  // drop it
    }
    argv[out++] = argv[i];
  }
  argv[out] = nullptr;
  return out;
}

Role acquire(const LaunchIntent &intent) {
  QDBusConnection bus = QDBusConnection::sessionBus();
  if (!bus.isConnected()) return Role::Standalone;

  // registerService succeeds only for the first instance to claim the name.
  if (!bus.registerService(QString::fromLatin1(kAppId))) {
    // A primary already owns the name: hand off our intent and exit. If the
    // hand-off fails (primary wedged/unreachable), fall back to Standalone so
    // the caller still opens a window rather than vanishing silently.
    return forward(intent) ? Role::Secondary : Role::Standalone;
  }

  // We are the primary: export org.freedesktop.Application. The service object
  // and its adaptor live for the whole process (intentionally never freed).
  auto *service = new QObject;
  new AppAdaptor(service);
  if (!bus.registerObject(QString::fromLatin1(kObjectPath), service,
                          QDBusConnection::ExportAdaptors)) {
    std::fprintf(stderr,
                 "[ghastty] failed to export org.freedesktop.Application; "
                 "single-instance/activation disabled\n");
  }
  return Role::Primary;
}

}  // namespace dbus

#include "Activation.moc"
