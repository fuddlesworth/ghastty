#include "Toast.h"

#include <QColor>
#include <QEvent>
#include <QGraphicsOpacityEffect>
#include <QPainter>
#include <QPalette>
#include <QPen>
#include <QPropertyAnimation>
#include <QRectF>
#include <QTimer>

namespace {
constexpr int kVisibleMs = 3000;   // matches GTK adw.Toast setTimeout(3)
constexpr int kFadeMs = 200;       // in/out fade duration
constexpr int kBottomMargin = 24;  // gap from the window's bottom edge
constexpr qreal kRadius = 12.0;    // pill corner radius
}  // namespace

Toast::Toast(QWidget *parent) : QLabel(parent) {
  // Passive overlay: never grab the pointer or keyboard from the terminal.
  setAttribute(Qt::WA_TransparentForMouseEvents);
  setFocusPolicy(Qt::NoFocus);
  setTextInteractionFlags(Qt::NoTextInteraction);
  setAlignment(Qt::AlignCenter);
  // Inner padding for the pill; the rounded background is drawn in
  // paintEvent. QLabel renders its text in the WindowText palette role,
  // so the text colour tracks the active theme automatically.
  setContentsMargins(16, 8, 16, 8);

  // Drives the in/out fade. A child widget can't use windowOpacity (that's
  // top-level only), so animate a graphics opacity effect instead.
  m_opacity = new QGraphicsOpacityEffect(this);
  m_opacity->setOpacity(0.0);
  setGraphicsEffect(m_opacity);

  m_fade = new QPropertyAnimation(m_opacity, "opacity", this);
  m_fade->setDuration(kFadeMs);
  connect(m_fade, &QPropertyAnimation::finished, this, [this]() {
    // Hide once fully faded out so we stop occluding the subsurface.
    if (m_opacity->opacity() <= 0.01) hide();
  });

  m_timer = new QTimer(this);
  m_timer->setSingleShot(true);
  connect(m_timer, &QTimer::timeout, this, &Toast::fadeOut);

  if (parent) parent->installEventFilter(this);
  hide();
}

void Toast::paintEvent(QPaintEvent *event) {
  // Themed rounded pill behind the text. Window / Mid are the same roles
  // SearchBar's themed panel paints with, so the toast matches the rest
  // of the Qt chrome on both light and dark themes. The area outside the
  // radius is left unpainted (transparent), so the terminal shows through
  // the rounded corners.
  QPainter p(this);
  p.setRenderHint(QPainter::Antialiasing);
  const QPalette pal = palette();
  p.setBrush(pal.color(QPalette::Active, QPalette::Window));
  p.setPen(QPen(pal.color(QPalette::Active, QPalette::Mid), 1));
  const QRectF r = QRectF(rect()).adjusted(0.5, 0.5, -0.5, -0.5);
  p.drawRoundedRect(r, kRadius, kRadius);
  p.end();
  // Let QLabel draw the text on top of our background.
  QLabel::paintEvent(event);
}

void Toast::post(const QString &text) {
  const bool wasVisible = isVisible() && m_opacity->opacity() > 0.01;
  setText(text);
  reposition();

  m_fade->stop();
  if (wasVisible) {
    // Replacing a live toast: keep it solid and just restart the timer.
    m_opacity->setOpacity(1.0);
  } else {
    show();
    raise();
    m_fade->setStartValue(0.0);
    m_fade->setEndValue(1.0);
    m_fade->start();
  }
  m_timer->start(kVisibleMs);
}

void Toast::fadeOut() {
  m_fade->stop();
  m_fade->setStartValue(m_opacity->opacity());
  m_fade->setEndValue(0.0);
  m_fade->start();
}

void Toast::reposition() {
  QWidget *p = parentWidget();
  if (!p) return;
  adjustSize();
  const int x = (p->width() - width()) / 2;
  const int y = p->height() - height() - kBottomMargin;
  move(qMax(0, x), qMax(0, y));
}

bool Toast::eventFilter(QObject *obj, QEvent *event) {
  if (obj == parentWidget() && event->type() == QEvent::Resize && isVisible())
    reposition();
  return QLabel::eventFilter(obj, event);
}
