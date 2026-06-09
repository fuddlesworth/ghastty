#pragma once

#include <QLabel>

class QTimer;
class QPropertyAnimation;
class QGraphicsOpacityEffect;

// A transient, self-dismissing message shown near the bottom of its
// parent window — the Qt analogue of GTK/libadwaita's AdwToast. Used
// for lightweight feedback like "Copied to clipboard" or "Configuration
// reloaded".
//
// Parented to the MainWindow so it floats above the tab/terminal content
// rather than being confined to one split pane. The terminal renders into
// a Wayland subsurface placed *below* the Qt surface (it shows through the
// transparent terminal region), so an opaque Qt widget painted over that
// region — exactly like GhosttySurface's m_exitOverlay / m_keySeqOverlay —
// occludes the subsurface and appears on top. The pill never takes
// mouse/keyboard focus, so it can't steal input from the terminal.
class Toast : public QLabel {
  Q_OBJECT

public:
  explicit Toast(QWidget *parent);

  // Show `text` for ~3s (matching GTK's adw.Toast setTimeout(3)), then
  // fade out. A second call replaces the current message and restarts the
  // timer rather than queueing — the latest action is what the user cares
  // about.
  void post(const QString &text);

protected:
  // Watches the parent for resize so the pill stays bottom-centered.
  bool eventFilter(QObject *obj, QEvent *event) override;
  // Paints the themed rounded pill behind the (palette-coloured) text.
  // Done by hand rather than via a stylesheet derived from the palette:
  // that recurses fatally (setStyleSheet posts a PaletteChange, which
  // would re-derive the stylesheet, which posts another PaletteChange…).
  // Painting reads the palette live, so it also tracks light↔dark theme
  // switches for free without any change-event handling.
  void paintEvent(QPaintEvent *event) override;

private:
  void reposition();
  void fadeOut();

  QTimer *m_timer;
  QGraphicsOpacityEffect *m_opacity;
  QPropertyAnimation *m_fade;
};
