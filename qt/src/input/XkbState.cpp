#include "XkbState.h"

#include <xkbcommon/xkbcommon.h>

#include "../XkbTracker.h"

XkbState &XkbState::instance() {
  static XkbState self;
  return self;
}

XkbState::~XkbState() {
  // Run on process exit when the static is destroyed. The OS would
  // reclaim regardless, but explicit teardown silences leak checkers
  // and documents the ownership chain.
  if (m_query) xkb_state_unref(m_query);
  if (m_unshifted) xkb_state_unref(m_unshifted);
  if (m_keymap) xkb_keymap_unref(m_keymap);
  if (m_fallbackKeymap) xkb_keymap_unref(m_fallbackKeymap);
}

namespace {

// Maps an xkb keysym to the ghostty key enum. This mirrors the GTK
// apprt's keyFromKeyval table (src/apprt/gtk/key.zig): XKB keysyms are
// numerically identical to X11/GDK keysyms, so the entries match GTK's
// one-for-one. The core decides whether to honor this over the physical
// keycode via Key.shouldBeRemappable, so we can map everything here
// (including writing-system keys) and let the core arbitrate.
struct SymKey {
  xkb_keysym_t sym;
  ghostty_input_key_e key;
};
constexpr SymKey kKeymap[] = {
    {XKB_KEY_a, GHOSTTY_KEY_A}, {XKB_KEY_b, GHOSTTY_KEY_B},
    {XKB_KEY_c, GHOSTTY_KEY_C}, {XKB_KEY_d, GHOSTTY_KEY_D},
    {XKB_KEY_e, GHOSTTY_KEY_E}, {XKB_KEY_f, GHOSTTY_KEY_F},
    {XKB_KEY_g, GHOSTTY_KEY_G}, {XKB_KEY_h, GHOSTTY_KEY_H},
    {XKB_KEY_i, GHOSTTY_KEY_I}, {XKB_KEY_j, GHOSTTY_KEY_J},
    {XKB_KEY_k, GHOSTTY_KEY_K}, {XKB_KEY_l, GHOSTTY_KEY_L},
    {XKB_KEY_m, GHOSTTY_KEY_M}, {XKB_KEY_n, GHOSTTY_KEY_N},
    {XKB_KEY_o, GHOSTTY_KEY_O}, {XKB_KEY_p, GHOSTTY_KEY_P},
    {XKB_KEY_q, GHOSTTY_KEY_Q}, {XKB_KEY_r, GHOSTTY_KEY_R},
    {XKB_KEY_s, GHOSTTY_KEY_S}, {XKB_KEY_t, GHOSTTY_KEY_T},
    {XKB_KEY_u, GHOSTTY_KEY_U}, {XKB_KEY_v, GHOSTTY_KEY_V},
    {XKB_KEY_w, GHOSTTY_KEY_W}, {XKB_KEY_x, GHOSTTY_KEY_X},
    {XKB_KEY_y, GHOSTTY_KEY_Y}, {XKB_KEY_z, GHOSTTY_KEY_Z},

    {XKB_KEY_0, GHOSTTY_KEY_DIGIT_0}, {XKB_KEY_1, GHOSTTY_KEY_DIGIT_1},
    {XKB_KEY_2, GHOSTTY_KEY_DIGIT_2}, {XKB_KEY_3, GHOSTTY_KEY_DIGIT_3},
    {XKB_KEY_4, GHOSTTY_KEY_DIGIT_4}, {XKB_KEY_5, GHOSTTY_KEY_DIGIT_5},
    {XKB_KEY_6, GHOSTTY_KEY_DIGIT_6}, {XKB_KEY_7, GHOSTTY_KEY_DIGIT_7},
    {XKB_KEY_8, GHOSTTY_KEY_DIGIT_8}, {XKB_KEY_9, GHOSTTY_KEY_DIGIT_9},

    {XKB_KEY_semicolon, GHOSTTY_KEY_SEMICOLON},
    {XKB_KEY_space, GHOSTTY_KEY_SPACE},
    {XKB_KEY_apostrophe, GHOSTTY_KEY_QUOTE},
    {XKB_KEY_comma, GHOSTTY_KEY_COMMA},
    {XKB_KEY_grave, GHOSTTY_KEY_BACKQUOTE},
    {XKB_KEY_period, GHOSTTY_KEY_PERIOD},
    {XKB_KEY_slash, GHOSTTY_KEY_SLASH},
    {XKB_KEY_minus, GHOSTTY_KEY_MINUS},
    {XKB_KEY_equal, GHOSTTY_KEY_EQUAL},
    {XKB_KEY_bracketleft, GHOSTTY_KEY_BRACKET_LEFT},
    {XKB_KEY_bracketright, GHOSTTY_KEY_BRACKET_RIGHT},
    {XKB_KEY_backslash, GHOSTTY_KEY_BACKSLASH},

    {XKB_KEY_Up, GHOSTTY_KEY_ARROW_UP},
    {XKB_KEY_Down, GHOSTTY_KEY_ARROW_DOWN},
    {XKB_KEY_Right, GHOSTTY_KEY_ARROW_RIGHT},
    {XKB_KEY_Left, GHOSTTY_KEY_ARROW_LEFT},
    {XKB_KEY_Home, GHOSTTY_KEY_HOME},
    {XKB_KEY_End, GHOSTTY_KEY_END},
    {XKB_KEY_Insert, GHOSTTY_KEY_INSERT},
    {XKB_KEY_Delete, GHOSTTY_KEY_DELETE},
    {XKB_KEY_Caps_Lock, GHOSTTY_KEY_CAPS_LOCK},
    {XKB_KEY_Scroll_Lock, GHOSTTY_KEY_SCROLL_LOCK},
    {XKB_KEY_Num_Lock, GHOSTTY_KEY_NUM_LOCK},
    {XKB_KEY_Page_Up, GHOSTTY_KEY_PAGE_UP},
    {XKB_KEY_Page_Down, GHOSTTY_KEY_PAGE_DOWN},
    {XKB_KEY_Escape, GHOSTTY_KEY_ESCAPE},
    {XKB_KEY_Return, GHOSTTY_KEY_ENTER},
    {XKB_KEY_Tab, GHOSTTY_KEY_TAB},
    {XKB_KEY_ISO_Left_Tab, GHOSTTY_KEY_TAB},
    {XKB_KEY_BackSpace, GHOSTTY_KEY_BACKSPACE},
    {XKB_KEY_Print, GHOSTTY_KEY_PRINT_SCREEN},
    {XKB_KEY_Pause, GHOSTTY_KEY_PAUSE},
    {XKB_KEY_Menu, GHOSTTY_KEY_CONTEXT_MENU},

    {XKB_KEY_F1, GHOSTTY_KEY_F1},   {XKB_KEY_F2, GHOSTTY_KEY_F2},
    {XKB_KEY_F3, GHOSTTY_KEY_F3},   {XKB_KEY_F4, GHOSTTY_KEY_F4},
    {XKB_KEY_F5, GHOSTTY_KEY_F5},   {XKB_KEY_F6, GHOSTTY_KEY_F6},
    {XKB_KEY_F7, GHOSTTY_KEY_F7},   {XKB_KEY_F8, GHOSTTY_KEY_F8},
    {XKB_KEY_F9, GHOSTTY_KEY_F9},   {XKB_KEY_F10, GHOSTTY_KEY_F10},
    {XKB_KEY_F11, GHOSTTY_KEY_F11}, {XKB_KEY_F12, GHOSTTY_KEY_F12},
    {XKB_KEY_F13, GHOSTTY_KEY_F13}, {XKB_KEY_F14, GHOSTTY_KEY_F14},
    {XKB_KEY_F15, GHOSTTY_KEY_F15}, {XKB_KEY_F16, GHOSTTY_KEY_F16},
    {XKB_KEY_F17, GHOSTTY_KEY_F17}, {XKB_KEY_F18, GHOSTTY_KEY_F18},
    {XKB_KEY_F19, GHOSTTY_KEY_F19}, {XKB_KEY_F20, GHOSTTY_KEY_F20},
    {XKB_KEY_F21, GHOSTTY_KEY_F21}, {XKB_KEY_F22, GHOSTTY_KEY_F22},
    {XKB_KEY_F23, GHOSTTY_KEY_F23}, {XKB_KEY_F24, GHOSTTY_KEY_F24},
    {XKB_KEY_F25, GHOSTTY_KEY_F25},

    {XKB_KEY_KP_0, GHOSTTY_KEY_NUMPAD_0},
    {XKB_KEY_KP_1, GHOSTTY_KEY_NUMPAD_1},
    {XKB_KEY_KP_2, GHOSTTY_KEY_NUMPAD_2},
    {XKB_KEY_KP_3, GHOSTTY_KEY_NUMPAD_3},
    {XKB_KEY_KP_4, GHOSTTY_KEY_NUMPAD_4},
    {XKB_KEY_KP_5, GHOSTTY_KEY_NUMPAD_5},
    {XKB_KEY_KP_6, GHOSTTY_KEY_NUMPAD_6},
    {XKB_KEY_KP_7, GHOSTTY_KEY_NUMPAD_7},
    {XKB_KEY_KP_8, GHOSTTY_KEY_NUMPAD_8},
    {XKB_KEY_KP_9, GHOSTTY_KEY_NUMPAD_9},
    {XKB_KEY_KP_Decimal, GHOSTTY_KEY_NUMPAD_DECIMAL},
    {XKB_KEY_KP_Divide, GHOSTTY_KEY_NUMPAD_DIVIDE},
    {XKB_KEY_KP_Multiply, GHOSTTY_KEY_NUMPAD_MULTIPLY},
    {XKB_KEY_KP_Subtract, GHOSTTY_KEY_NUMPAD_SUBTRACT},
    {XKB_KEY_KP_Add, GHOSTTY_KEY_NUMPAD_ADD},
    {XKB_KEY_KP_Enter, GHOSTTY_KEY_NUMPAD_ENTER},
    {XKB_KEY_KP_Equal, GHOSTTY_KEY_NUMPAD_EQUAL},
    {XKB_KEY_KP_Separator, GHOSTTY_KEY_NUMPAD_SEPARATOR},
    {XKB_KEY_KP_Left, GHOSTTY_KEY_NUMPAD_LEFT},
    {XKB_KEY_KP_Right, GHOSTTY_KEY_NUMPAD_RIGHT},
    {XKB_KEY_KP_Up, GHOSTTY_KEY_NUMPAD_UP},
    {XKB_KEY_KP_Down, GHOSTTY_KEY_NUMPAD_DOWN},
    {XKB_KEY_KP_Page_Up, GHOSTTY_KEY_NUMPAD_PAGE_UP},
    {XKB_KEY_KP_Page_Down, GHOSTTY_KEY_NUMPAD_PAGE_DOWN},
    {XKB_KEY_KP_Home, GHOSTTY_KEY_NUMPAD_HOME},
    {XKB_KEY_KP_End, GHOSTTY_KEY_NUMPAD_END},
    {XKB_KEY_KP_Insert, GHOSTTY_KEY_NUMPAD_INSERT},
    {XKB_KEY_KP_Delete, GHOSTTY_KEY_NUMPAD_DELETE},
    {XKB_KEY_KP_Begin, GHOSTTY_KEY_NUMPAD_BEGIN},

    {XKB_KEY_XF86Copy, GHOSTTY_KEY_COPY},
    {XKB_KEY_XF86Cut, GHOSTTY_KEY_CUT},
    {XKB_KEY_XF86Paste, GHOSTTY_KEY_PASTE},

    {XKB_KEY_Shift_L, GHOSTTY_KEY_SHIFT_LEFT},
    {XKB_KEY_Control_L, GHOSTTY_KEY_CONTROL_LEFT},
    {XKB_KEY_Alt_L, GHOSTTY_KEY_ALT_LEFT},
    {XKB_KEY_Super_L, GHOSTTY_KEY_META_LEFT},
    {XKB_KEY_Shift_R, GHOSTTY_KEY_SHIFT_RIGHT},
    {XKB_KEY_Control_R, GHOSTTY_KEY_CONTROL_RIGHT},
    {XKB_KEY_Alt_R, GHOSTTY_KEY_ALT_RIGHT},
    {XKB_KEY_Super_R, GHOSTTY_KEY_META_RIGHT},
};

}  // namespace

ghostty_input_key_e XkbState::keyForKeysym(uint32_t sym) const {
  if (sym == XKB_KEY_NoSymbol || sym == 0) return GHOSTTY_KEY_UNIDENTIFIED;
  for (const auto &e : kKeymap)
    if (e.sym == sym) return e.key;
  return GHOSTTY_KEY_UNIDENTIFIED;
}

ghostty_input_key_e XkbState::keyForKeycode(uint32_t keycode) const {
  syncFromTracker();
  if (!m_unshifted) return GHOSTTY_KEY_UNIDENTIFIED;
  // Base (level-0) keysym for this physical key under the live keymap.
  // This is the post-remap identity an XKB user-remap (caps->escape)
  // surfaces as the remapped keysym. Used as a fallback when the event
  // carried no effective keysym (see GhosttySurface::sendKey).
  return keyForKeysym(xkb_state_key_get_one_sym(m_unshifted, keycode));
}

uint32_t XkbState::unshiftedCodepoint(uint32_t keycode) const {
  syncFromTracker();
  if (!m_unshifted) return 0;
  const xkb_keysym_t sym =
      xkb_state_key_get_one_sym(m_unshifted, keycode);
  if (sym == XKB_KEY_NoSymbol) return 0;
  return xkb_keysym_to_utf32(sym);
}

ghostty_input_mods_e XkbState::sideBitsForKeycode(uint32_t keycode) const {
  syncFromTracker();
  if (!m_unshifted) return GHOSTTY_MODS_NONE;
  const xkb_keysym_t sym =
      xkb_state_key_get_one_sym(m_unshifted, keycode);
  int r = GHOSTTY_MODS_NONE;
  switch (sym) {
    case XKB_KEY_Shift_R: r |= GHOSTTY_MODS_SHIFT_RIGHT; break;
    case XKB_KEY_Control_R: r |= GHOSTTY_MODS_CTRL_RIGHT; break;
    // Both Alt_R and ISO_Level3_Shift (AltGr) are right-Alt physically.
    case XKB_KEY_Alt_R:
    case XKB_KEY_ISO_Level3_Shift: r |= GHOSTTY_MODS_ALT_RIGHT; break;
    case XKB_KEY_Super_R:
    case XKB_KEY_Hyper_R:
    case XKB_KEY_Meta_R: r |= GHOSTTY_MODS_SUPER_RIGHT; break;
    default: break;
  }
  return static_cast<ghostty_input_mods_e>(r);
}

ghostty_input_mods_e XkbState::consumedMods(uint32_t keycode,
                                            ghostty_input_mods_e mods) const {
  syncFromTracker();
  if (!m_query) return GHOSTTY_MODS_NONE;
  xkb_mod_mask_t depressed = 0;
  if ((mods & GHOSTTY_MODS_SHIFT) && m_idxShift != XKB_MOD_INVALID)
    depressed |= (1u << m_idxShift);
  if ((mods & GHOSTTY_MODS_CTRL) && m_idxCtrl != XKB_MOD_INVALID)
    depressed |= (1u << m_idxCtrl);
  if ((mods & GHOSTTY_MODS_ALT) && m_idxAlt != XKB_MOD_INVALID)
    depressed |= (1u << m_idxAlt);
  if ((mods & GHOSTTY_MODS_SUPER) && m_idxSuper != XKB_MOD_INVALID)
    depressed |= (1u << m_idxSuper);
  // Use the live group from the tracker so a layout switch (e.g.
  // us↔ru) takes effect immediately.
  XkbTracker *t = XkbTracker::instance();
  const uint32_t group = t ? t->activeGroup() : 0;
  xkb_state_update_mask(m_query, depressed, 0, 0, 0, 0, group);
  const xkb_mod_mask_t consumed = xkb_state_key_get_consumed_mods2(
      m_query, keycode, XKB_CONSUMED_MODE_XKB);
  // Reset so the next query starts from no-mods.
  xkb_state_update_mask(m_query, 0, 0, 0, 0, 0, group);
  int r = GHOSTTY_MODS_NONE;
  if (m_idxShift != XKB_MOD_INVALID && (consumed & (1u << m_idxShift)))
    r |= GHOSTTY_MODS_SHIFT;
  if (m_idxCtrl != XKB_MOD_INVALID && (consumed & (1u << m_idxCtrl)))
    r |= GHOSTTY_MODS_CTRL;
  if (m_idxAlt != XKB_MOD_INVALID && (consumed & (1u << m_idxAlt)))
    r |= GHOSTTY_MODS_ALT;
  if (m_idxSuper != XKB_MOD_INVALID && (consumed & (1u << m_idxSuper)))
    r |= GHOSTTY_MODS_SUPER;
  return static_cast<ghostty_input_mods_e>(r);
}

void XkbState::syncFromTracker() const {
  XkbTracker *t = XkbTracker::instance();
  xkb_keymap *liveKm = t ? t->keymap() : nullptr;
  xkb_keymap *km = liveKm ? liveKm : m_fallbackKeymap;

  if (!km && t && t->ctx()) {
    // Compositor hasn't sent a keymap yet (early startup). Build a
    // throwaway from XKB defaults so the first key event isn't
    // dropped; it will be replaced on the next syncFromTracker
    // call once the tracker has the live keymap.
    m_fallbackKeymap = xkb_keymap_new_from_names(
        t->ctx(), nullptr, XKB_KEYMAP_COMPILE_NO_FLAGS);
    km = m_fallbackKeymap;
  }
  if (!km || km == m_keymap) {
    // Already synced (or no keymap available at all).
    // Update the live group on m_unshifted so the level-0 lookup
    // honors the active layout, even when the keymap pointer
    // hasn't changed.
    if (m_unshifted && t) {
      xkb_state_update_mask(m_unshifted, 0, 0, 0, 0, 0, t->activeGroup());
    }
    return;
  }

  // The live keymap was rebuilt by the tracker (or we're picking
  // up the first one). Drop our derived states and rebuild. Take
  // an extra ref on the keymap while it's our cached identity so
  // the xkb allocator can't free it and reuse the same address
  // for a different keymap (the ABA hazard the previous comment
  // hand-waved away).
  if (m_unshifted) xkb_state_unref(m_unshifted);
  if (m_query) xkb_state_unref(m_query);
  if (m_keymap) xkb_keymap_unref(m_keymap);
  m_keymap = xkb_keymap_ref(km);
  m_unshifted = xkb_state_new(km);
  m_query = xkb_state_new(km);
  m_idxShift = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_SHIFT);
  m_idxCtrl = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_CTRL);
  m_idxAlt = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_ALT);
  m_idxSuper = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_LOGO);
  if (t)
    xkb_state_update_mask(m_unshifted, 0, 0, 0, 0, 0, t->activeGroup());
}
