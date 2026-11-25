// Screens for a 480 x 480 AMOLED. Black is the background everywhere: on this kind of panel black pixels are off.
//
// The rules the request screen keeps, whatever the computer sends:
//   - what is asked is shown whole, or it cannot be allowed here;
//   - "deny" is a tap, "allow" is a finger held on the button for a full second;
//   - one answer per request;
//   - the keys on the side never answer anything.
#include "ui.h"
#include "hw.h"
#include "link.h"
#include "state.h"
#include "board.h"
#include "screens.h"
#include "sound.h"
#include <Preferences.h>
#include <U8g2lib.h>

#define RGB(r, g, b) (uint16_t)((((r) & 0xF8) << 8) | (((g) & 0xFC) << 3) | ((b) >> 3))
static const uint16_t BLACK = 0x0000;
static const uint16_t WHITE = 0xFFFF;
static const uint16_t GREY = RGB(139, 149, 167);
static const uint16_t DIM = RGB(58, 67, 84);
static const uint16_t TRACK = RGB(28, 34, 48);
static const uint16_t PANEL = RGB(17, 22, 31);
static const uint16_t MINT = RGB(79, 237, 176);
static const uint16_t MINT_BG = RGB(15, 42, 34);
static const uint16_t MINT_FILL = RGB(23, 70, 58);
static const uint16_t AQUA = RGB(66, 194, 255);
static const uint16_t AQUA_BG = RGB(16, 40, 58);
static const uint16_t AMBER = RGB(255, 189, 69);
static const uint16_t AMBER_BG = RGB(43, 33, 16);
static const uint16_t CORAL = RGB(255, 110, 105);
static const uint16_t CORAL_BG = RGB(58, 22, 20);

// Chinese and Latin text; drawn at one or two times its 16-pixel size.
#define FONT_TEXT u8g2_font_wqy16_t_gb2312
// Large digits for the percentage and the clock.
#define FONT_DIGITS u8g2_font_logisoso92_tn
#define FONT_LATIN u8g2_font_helvB24_tr

static const uint32_t HOLD_MS = 1000;         // how long any button must be held: on a screen this small a touch is too easily a mistake
static const uint32_t STALE_MS = 30000;       // no snapshot for this long: the link is taken as dead
static const uint32_t DIM_AFTER_MS = 60000;   // idle and untouched: dim
static const uint32_t OFF_AFTER_MS = 300000;  // then switch the panel off
static const uint32_t LIST_BACK_MS = 20000;   // the list goes back to the main screen by itself

static Arduino_Canvas* g = nullptr;

// Buttons on the request screen. These are where the first screens put them; the redesigned screens have their own
// places (screens.h), taken up at the start of every pass.
static int DENY_X = 34, ALLOW_X = 250, BTN_Y = 330, BTN_W = 196, BTN_H = 110;

// Touch tracking
static bool s_down = false;
static int s_downX = 0, s_downY = 0, s_lastX = 0, s_lastY = 0;
static uint32_t s_downAt = 0;
static bool s_downOnAllow = false;
static bool s_downOnDeny = false;

static bool s_showList = false;
static uint32_t s_listAt = 0;
// The pages, side by side: 0 the renders, 1 the agents and other programs' tasks, 2 the computer itself.
// Only with the redesigned screens and a computer that sends RenderDock's fields; otherwise there is the one page.
static const int PAGES = 3, PAGE_MAC = 2;
static int s_page = 0;
static Overall s_lastRenders = OV_IDLE, s_lastSessions = OV_IDLE;
static uint32_t s_lastMacAt = 0;
static uint32_t s_lastTouchAt = 0;
static uint32_t s_lastContactAt = 0;   // when the touch controller last reported a finger
static uint32_t s_lastDrawAt = 0;
static uint32_t s_lastStateAt = 0;
static char s_lastPrompt[40] = "";
static bool s_lastAllowed = false;     // what was answered, for the confirmation
static uint32_t s_answeredAt = 0;
static bool s_wasConnected = false;
static bool s_debugFeed = false;

void uiDebugFeed(bool on) { s_debugFeed = on; }
#if RD_DEBUG_SERIAL
// What is fed in over USB is made up, and may set the clock to any hour: it makes no sound unless asked to.
static bool s_debugLoud = false;
void uiDebugLoud(bool on) { s_debugLoud = on; }
#endif

#if RD_DEBUG_SERIAL
static Touch s_fakeTouch = {false, 0, 0};
static uint32_t s_fakePasskey = 0;
void uiDebugTouch(bool down, int x, int y) { s_fakeTouch = {down, x, y}; }
void uiDebugPasskey(uint32_t passkey) { s_fakePasskey = passkey; }
static int s_debugPage = -1;
void uiDebugPage(int page) { s_debugPage = page; }
static uint32_t s_holdUntil = 0;
void uiDebugHold(uint32_t ms) { s_holdUntil = ms ? millis() + ms : 0; }
static uint32_t s_drawMicros = 0, s_pushMicros = 0;
void uiDebugTimes(uint32_t& draw, uint32_t& push) {
  draw = s_drawMicros;
  push = s_pushMicros;
}
#endif

// The six digits to show while pairing, or 0 when not pairing.
static uint32_t passkeyToShow() {
#if RD_DEBUG_SERIAL
  if (s_fakePasskey != 0) return s_fakePasskey;
#endif
  return linkPasskey();
}

// MARK: text

// The middle dot used between two pieces of text. The text font has no glyph for it (it would vanish without
// taking any room), so it is drawn by hand: a small disc this many pixels wide per unit of text size.
static const char MIDDOT[] = "\xC2\xB7";
static const int MIDDOT_W = 6;

static int middots(const char* s) {
  int n = 0;
  for (const char* p = strstr(s, MIDDOT); p; p = strstr(p + 2, MIDDOT)) n++;
  return n;
}

// The width of the ink, and (in `bearing`) how far right of the cursor it starts. The large digits start well
// to the right of the cursor, so centring by the cursor alone would put them off centre.
static int textWidth(const char* s, const uint8_t* font, int size, int* bearing = nullptr) {
  g->setFont(font);
  g->setTextSize(size);
  int16_t x1, y1;
  uint16_t w, h;
  g->getTextBounds(s, 0, 0, &x1, &y1, &w, &h);
  if (bearing) *bearing = x1;
  return (int)w + middots(s) * MIDDOT_W * size;
}

// align: -1 left of x, 0 centred on x, 1 right-aligned to x. y is the baseline.
static void text(const char* s, int x, int y, uint16_t color, int size = 2, int align = 0, const uint8_t* font = FONT_TEXT) {
  int bearing = 0;
  int w = textWidth(s, font, size, &bearing);
  int left = align < 0 ? x : (align == 0 ? x - w / 2 : x - w);
  g->setTextColor(color);
  g->setCursor(left - bearing, y);
  const char* p = s;
  for (const char* dot = strstr(p, MIDDOT); dot; dot = strstr(p, MIDDOT)) {
    for (const char* c = p; c < dot; c++) g->write((uint8_t)*c);
    int at = g->getCursorX();
    g->fillCircle(at + MIDDOT_W * size / 2 - 1, y - 5 * size, size, color);
    g->setCursor(at + MIDDOT_W * size, y);
    p = dot + 2;
  }
  g->print(p);
}

// Cuts text to a width, at a character boundary, ending in an ellipsis when cut.
static String fit(const char* s, int maxWidth, int size = 2, const uint8_t* font = FONT_TEXT) {
  String out = s;
  if (textWidth(out.c_str(), font, size) <= maxWidth) return out;
  while (out.length() > 0) {
    int cut = out.length() - 1;
    while (cut > 0 && ((uint8_t)out[cut] & 0xC0) == 0x80) cut--;   // step back over a UTF-8 tail
    out.remove(cut);
    String candidate = out + "…";
    if (textWidth(candidate.c_str(), font, size) <= maxWidth) return candidate;
  }
  return out;
}

// Breaks text into lines of at most maxWidth. Returns how many lines it needs (lines beyond maxLines are not stored).
static int wrap(const char* s, int maxWidth, int size, String* lines, int maxLines) {
  int count = 0;
  String current;
  const char* p = s;
  while (*p) {
    int n = 1;
    while (((uint8_t)p[n] & 0xC0) == 0x80) n++;   // one whole character
    String next = current;
    for (int i = 0; i < n; i++) next += p[i];
    // A closing mark stays with the line it closes, even if that line then runs a little over.
    bool closing = n == 3 && (!strncmp(p, "”", 3) || !strncmp(p, "’", 3) || !strncmp(p, "，", 3) || !strncmp(p, "。", 3)
                              || !strncmp(p, "、", 3) || !strncmp(p, "）", 3) || !strncmp(p, "》", 3) || !strncmp(p, "」", 3));
    int width = textWidth(next.c_str(), FONT_TEXT, size);
    if (current.length() > 0 && (closing ? width > maxWidth + 30 : width > maxWidth)) {
      if (count < maxLines) lines[count] = current;
      count++;
      current = "";
      while (*p == ' ') p++;   // a line does not start with a space
      continue;                // retry this character on the new line
    }
    current = next;
    p += n;
  }
  if (current.length() > 0) {
    if (count < maxLines) lines[count] = current;
    count++;
  }
  return count;
}

static String age(int seconds) {
  if (seconds < 0) return "";
  if (seconds < 60) return String(seconds) + " 秒";
  if (seconds < 3600) return String(seconds / 60) + " 分";
  return String(seconds / 3600) + " 时";
}

static const char* stateWord(const char* s) {
  if (!strcmp(s, "waiting")) return "等你";
  if (!strcmp(s, "working")) return "在干活";
  if (!strcmp(s, "done")) return "刚做完";
  if (!strcmp(s, "error")) return "出错";
  return "";
}

static uint16_t stateColor(const char* s) {
  if (!strcmp(s, "waiting")) return AMBER;
  if (!strcmp(s, "working")) return AQUA;
  if (!strcmp(s, "done")) return MINT;
  if (!strcmp(s, "error")) return CORAL;
  return GREY;
}

// MARK: shapes

// A ring from 12 o'clock, clockwise, for a fraction 0…1.
static void ring(int cx, int cy, int outer, int inner, float fraction, uint16_t color) {
  g->fillArc(cx, cy, outer, inner, 0, 360, TRACK);
  if (fraction <= 0) return;
  float sweep = min(1.0f, fraction) * 360.0f;
  if (sweep >= 359.5f) {
    g->fillArc(cx, cy, outer, inner, 0, 360, color);
  } else if (sweep <= 90) {
    g->fillArc(cx, cy, outer, inner, 270, 270 + sweep, color);
  } else {
    g->fillArc(cx, cy, outer, inner, 270, 360, color);
    g->fillArc(cx, cy, outer, inner, 0, sweep - 90, color);
  }
}

static void chip(int x, int y, int w, const char* label, uint16_t color, uint16_t background) {
  g->fillRoundRect(x, y, w, 34, 17, background);
  text(label, x + w / 2, y + 24, color, 1);
}

static void bottomChips() {
  const State& s = g_state;
  if (!s.extended) return;
  String working = String(s.agentsWorking) + " 在干活";
  String done = String(s.agentsDone) + " 做完";
  bool showWorking = s.agentsWorking > 0, showDone = s.agentsDone > 0;
  if (showWorking && showDone) {
    chip(122, 430, 112, working.c_str(), AQUA, AQUA_BG);
    chip(246, 430, 112, done.c_str(), MINT, MINT_BG);
  } else if (showWorking) {
    chip(184, 430, 112, working.c_str(), AQUA, AQUA_BG);
  } else if (showDone) {
    chip(184, 430, 112, done.c_str(), MINT, MINT_BG);
  }
}

// MARK: screens

static void drawLink() {
  uint32_t passkey = passkeyToShow();
  if (passkey != 0) {
    char digits[8];
    snprintf(digits, sizeof(digits), "%06lu", (unsigned long)(passkey % 1000000));
    text("配对", 240, 120, GREY);
    text(digits, 240, 270, WHITE, 1, 0, FONT_DIGITS);
    text("在电脑上输入这六位数", 240, 350, WHITE);
    return;
  }
  g->drawCircle(240, 170, 60, DIM);
  g->drawCircle(240, 170, 40, DIM);
  g->fillCircle(240, 170, 10, linkConnected() ? AQUA : DIM);
  text(linkConnected() ? "已连上，等电脑发数据" : "等电脑来连", 240, 290, WHITE);
  text(linkName(), 240, 340, GREY, 1, 0, FONT_LATIN);
  if (!linkConnected()) text("在渲染坞的菜单里打开「连接蓝牙小设备」", 240, 400, GREY, 1);
}

static void drawIdle() {
  int hour, minute;
  if (protoClock(hour, minute)) {
    char clock[8];
    snprintf(clock, sizeof(clock), "%02d:%02d", hour, minute);
    text(clock, 240, 270, DIM, 1, 0, FONT_DIGITS);
  }
  text("没有任务", 240, 330, DIM);
}

static void drawWorking() {
  const State& s = g_state;
  bool render = !strcmp(s.topKind, "render") && s.topPercent >= 0;
  if (render) {
    ring(240, 190, 148, 126, s.topPercent / 100.0f, MINT);
    // The number and its sign are centred as one group.
    String number = String(s.topPercent);
    const char* sign = s.topExact ? "%" : "~%";
    int w = textWidth(number.c_str(), FONT_DIGITS, 1);
    int left = 240 - (w + 8 + textWidth(sign, FONT_LATIN, 1)) / 2;
    text(number.c_str(), left, 222, WHITE, 1, -1, FONT_DIGITS);
    text(sign, left + w + 8, 222, GREY, 1, -1, FONT_LATIN);
    if (s.topEta >= 0) text((String("剩约 ") + age(s.topEta)).c_str(), 240, 262, GREY, 1);
    text(fit(s.topName, 400).c_str(), 240, 380, WHITE);
    if (s.jobTitle[0]) {
      String job = String(s.jobTitle);
      if (s.jobTotal > 1) job += String(" · ") + s.jobDone + "/" + s.jobTotal + " 段";
      text(fit(job.c_str(), 400, 1).c_str(), 240, 410, GREY, 1);
    }
  } else if (s.extended) {
    // Nothing renders: the agents have the screen.
    g->fillCircle(240, 170, 96, AQUA_BG);
    text(String(s.agentsWorking).c_str(), 240, 215, AQUA, 1, 0, FONT_DIGITS);
    text("个会话在干活", 240, 320, WHITE);
    if (s.topName[0]) text(fit((String(s.topTool) + " · " + s.topName).c_str(), 400, 1).c_str(), 240, 356, GREY, 1);
  } else {
    // The plain protocol: counts and the computer's own line.
    g->fillCircle(240, 170, 96, AQUA_BG);
    text(String(s.running).c_str(), 240, 215, AQUA, 1, 0, FONT_DIGITS);
    text(fit(s.msg, 400).c_str(), 240, 320, WHITE);
    for (int i = 0; i < min(s.entryCount, 3); i++) text(fit(s.entries[i], 420, 1).c_str(), 240, 360 + i * 26, GREY, 1);
  }
  bottomChips();
}

static void drawWaiting() {
  const State& s = g_state;
  // A slow pulse: the outer ring breathes.
  float phase = (millis() % 2400) / 2400.0f;
  int grow = (int)(10 * (phase < 0.5f ? phase * 2 : (1 - phase) * 2));
  g->fillCircle(240, 170, 96, AMBER_BG);
  g->drawCircle(240, 170, 96, AMBER);
  g->drawCircle(240, 170, 108 + grow, RGB(120, 90, 30));
  // The mark is drawn by hand: the large font has digits only.
  g->fillRoundRect(231, 112, 18, 78, 9, AMBER);
  g->fillCircle(240, 214, 11, AMBER);
  if (s.extended && s.topName[0]) {
    text(fit((String(s.topName) + " 在等你").c_str(), 420).c_str(), 240, 320, WHITE);
    if (s.topTool[0]) text(s.topTool, 240, 354, GREY, 1);
    g->fillRoundRect(96, 376, 288, 40, 20, TRACK);
    text("这一条要在电脑上处理", 240, 403, RGB(201, 209, 222), 1);
  } else {
    text((String(s.waiting) + " 个在等你").c_str(), 240, 320, WHITE);
    text(fit(s.msg, 400, 1).c_str(), 240, 356, GREY, 1);
  }
  bottomChips();
}

static void drawDone(bool failed) {
  const State& s = g_state;
  uint16_t color = failed ? CORAL : MINT;
  g->fillCircle(240, 176, 104, failed ? CORAL_BG : MINT_BG);
  if (failed) {
    for (int i = -4; i <= 4; i++) {
      g->drawLine(196 + i, 132, 284 + i, 220, color);
      g->drawLine(284 + i, 132, 196 + i, 220, color);
    }
  } else {
    for (int i = -5; i <= 5; i++) {
      g->drawLine(192, 180 + i, 226, 214 + i, color);
      g->drawLine(226, 214 + i, 292, 140 + i, color);
    }
  }
  bool render = !strcmp(s.topKind, "render");
  text(failed ? (render ? "渲染失败" : "出错了") : (render ? "渲完了" : "做完了"), 240, 340, WHITE);
  if (s.topName[0]) text(fit((s.topTool[0] ? String(s.topTool) + " · " + s.topName : String(s.topName)).c_str(), 400, 1).c_str(), 240, 376, GREY, 1);
  bottomChips();
}

static void drawList() {
  const State& s = g_state;
  text("现在", 56, 62, GREY, 1, -1);
  String counts;
  if (s.agentsWaiting > 0) counts += String(s.agentsWaiting) + " 等你";
  if (s.agentsWorking > 0) counts += (counts.length() ? " · " : "") + String(s.agentsWorking) + " 在干活";
  text(counts.c_str(), 424, 62, GREY, 1, 1);
  if (s.rowCount == 0) {
    text(s.extended ? "没有在跑的" : fit(s.msg, 400).c_str(), 240, 240, GREY);
    for (int i = 0; !s.extended && i < s.entryCount; i++) text(fit(s.entries[i], 420, 1).c_str(), 240, 280 + i * 26, GREY, 1);
    return;
  }
  for (int i = 0; i < min(s.rowCount, 4); i++) {
    const Row& r = s.rows[i];
    int y = 84 + i * 84;
    bool waiting = !strcmp(r.state, "waiting");
    g->fillRoundRect(34, y, 412, 74, 22, waiting ? AMBER_BG : PANEL);
    String right;
    if (r.percent >= 0) right = String(r.percent) + "%";
    else right = String(stateWord(r.state)) + (r.age >= 0 ? " · " + age(r.age) : "");
    int rightWidth = textWidth(right.c_str(), FONT_TEXT, 1);
    text(fit(r.name, 412 - 56 - rightWidth - 16).c_str(), 58, y + 36, WHITE, 2, -1);
    text(r.tool[0] ? r.tool : "渲染", 58, y + 62, GREY, 1, -1);
    text(right.c_str(), 422, y + 46, r.percent >= 0 ? MINT : stateColor(r.state), 1, 1);
  }
  int more = max(0, s.rowCount - 4);
  String foot;
  if (more > 0) foot = String("还有 ") + more + " 个";
  if (s.agentsIdle > 0) foot += (foot.length() ? " · " : "") + String("另有 ") + s.agentsIdle + " 个空闲";
  if (foot.length()) text(foot.c_str(), 240, 452, DIM, 1);
}

// Whether the whole request fits on the screen. If not, it cannot be allowed here.
static bool hintFits(String* lines, int& count) {
  if (screensReady()) return screenRequestFits();
  // The first screens draw from a bitmap font that leaves out what it does not have. Only plain ASCII is sure
  // to be all there, so nothing else can be allowed on them.
  for (const char* c = g_state.promptHint; *c; c++) if ((uint8_t)*c >= 0x80) return false;
  for (const char* c = g_state.promptTool; *c; c++) if ((uint8_t)*c >= 0x80) return false;
  count = wrap(g_state.promptHint, 400, 2, lines, 3);
  return g_state.promptWhole && count >= 1 && count <= 3 && textWidth(g_state.promptTool, FONT_LATIN, 1) <= 400;
}

static void drawRequest() {
  const State& s = g_state;
  uint32_t now = millis();
  text("要你批准", 240, 62, GREY, 1);
  int toolWidth = textWidth(s.promptTool, FONT_LATIN, 1) + 40;
  g->fillRoundRect(240 - toolWidth / 2, 84, toolWidth, 44, 22, AMBER_BG);
  text(s.promptTool, 240, 116, AMBER, 1, 0, FONT_LATIN);

  String lines[3];
  int count = 0;
  bool whole = hintFits(lines, count);
  if (whole) {
    int top = 204 - (count - 1) * 20;
    for (int i = 0; i < count; i++) text(lines[i].c_str(), 240, top + i * 40, WHITE);
  } else {
    text("内容太长，这里显示不全", 240, 190, WHITE);
    text("要在电脑上处理", 240, 226, GREY, 1);
  }

  // How long is left, when the computer said. The bar only shows it; the computer does the counting.
  if (s.promptLeft > 0) {
    int elapsed = (int)((now - s.promptAt) / 1000);
    int left = max(0, s.promptLeft - elapsed);
    g->fillRoundRect(96, 270, 288, 6, 3, TRACK);
    g->fillRoundRect(96, 270, (int)(288.0f * left / s.promptLeft), 6, 3, AMBER);
    text((String("还等 ") + left + " 秒，到时回到电脑上问").c_str(), 240, 302, GREY, 1);
  }

  if (s.answered) {
    text(s_lastAllowed ? "已允许这一次" : "已拒绝", 240, 396, s_lastAllowed ? MINT : CORAL);
    return;
  }
  g->fillRoundRect(DENY_X, BTN_Y, BTN_W, BTN_H, 34, CORAL_BG);
  if (s_down && s_downOnDeny) {
    int filled = (int)(BTN_W * min(1.0f, (now - s_downAt) / (float)HOLD_MS));
    if (filled > 68) g->fillRoundRect(DENY_X, BTN_Y, filled, BTN_H, 34, RGB(110, 40, 37));
  }
  text("拒绝", DENY_X + BTN_W / 2, BTN_Y + 58, CORAL);
  text("按住一秒", DENY_X + BTN_W / 2, BTN_Y + 90, RGB(191, 140, 137), 1);
  if (whole) {
    g->fillRoundRect(ALLOW_X, BTN_Y, BTN_W, BTN_H, 34, MINT_BG);
    if (s_down && s_downOnAllow) {
      // The button fills from the left while the finger stays on it.
      int filled = (int)(BTN_W * min(1.0f, (now - s_downAt) / (float)HOLD_MS));
      if (filled > 68) g->fillRoundRect(ALLOW_X, BTN_Y, filled, BTN_H, 34, MINT_FILL);
    }
    text("允许这一次", ALLOW_X + BTN_W / 2, BTN_Y + 58, MINT);
    text("按住一秒", ALLOW_X + BTN_W / 2, BTN_Y + 90, RGB(127, 191, 170), 1);
  } else {
    g->fillRoundRect(ALLOW_X, BTN_Y, BTN_W, BTN_H, 34, TRACK);
    text("去电脑上", ALLOW_X + BTN_W / 2, BTN_Y + 68, GREY);
  }
}

// MARK: input

static bool inside(int x, int y, int rx, int ry, int rw, int rh) { return x >= rx && x < rx + rw && y >= ry && y < ry + rh; }

// Nothing can be answered unless the link is encrypted, and nothing while the six digits of a pairing are up:
// what cannot be seen must not be there to be pressed.
static bool answerable() { return (linkSecure() || s_debugFeed) && passkeyToShow() == 0; }
static bool requestOnScreen() { return g_state.prompt && answerable(); }

// A question from another program. A request to approve comes first; a question the user has put aside on this
// device stays away until another one comes. Only the redesigned screens can show one.
static char s_askAside[12] = "";
static bool askOnScreen() {
  return g_state.ask && answerable() && !g_state.prompt && screensReady() && strcmp(s_askAside, g_state.askId) != 0;
}
static int s_downOnChoice = -1;        // the answer the finger went down on and is still holding, or -1
// Which request or question is on the screen, and since when. A hold counts only if it began after that one had
// been up long enough to be seen, and only for the one it began on: a finger already on its way when something
// appeared, or still down when one thing was replaced by another, answers nothing.
static char s_shown[48] = "";
static uint32_t s_shownAt = 0;
static char s_downFor[48] = "";
static const uint32_t SETTLE_MS = 700;
static void whatIsShown(char* into, size_t size) {
  if (requestOnScreen()) snprintf(into, size, "r:%s", g_state.promptId);
  else if (askOnScreen()) snprintf(into, size, "q:%s", g_state.askId);
  else into[0] = 0;
}
static char s_lastAsk[12] = "";
// A notice from another program stays up for a few seconds, or until the screen is touched.
static char s_lastNote[12] = "";
static bool s_noteShowing = false;
static uint32_t s_noteUntil = 0;
static const uint32_t NOTE_MS = 8000;

// What the keys have switched. The first two are kept across restarts.
static bool s_dnd = false;          // do not disturb: no sound, and the screen does not light up for ordinary news
static bool s_mute = false;         // no sound. (There is none yet; the switch is here for when there is.)
static bool s_userOff = false;      // the screen was switched off with the power key
static bool s_screenDark = false;   // the panel is off, for whatever reason
static bool s_swallow = false;      // this touch lit the screen and does nothing else
static bool s_swiped = false;       // this touch has already turned the page
// Something changed: draw now. Without this a change waited for the next regular frame, up to a second away.
static bool s_dirty = true;

// Whether there are pages to turn at all, and turning them.
static bool pagesOn() { return screensReady() && g_state.extended; }
static void turnPage(int by) {
  s_page = (s_page + by + PAGES) % PAGES;
  s_showList = false;
  s_dirty = true;
}
static char s_toast[40] = "";
static uint32_t s_toastUntil = 0;
static Overall s_lastOverall = OV_IDLE;
static uint32_t s_lastPasskey = 0;
static Preferences s_kept;

// A sound, if one may be made now: not when muted or in "do not disturb", and not at night (eleven to eight by
// the clock the computer sets; with no clock yet, it counts as day).
static void ping(Sound sound) {
  if (s_mute || s_dnd) return;
  int hour, minute;
  if (protoClock(hour, minute) && (hour >= 23 || hour < 8)) return;
#if RD_DEBUG_SERIAL
  if (s_debugFeed && !s_debugLoud) {
    Serial.printf("sound %d not played: what is on the screen was fed in over USB (\"feed loud\" to hear it)\n", (int)sound);
    return;
  }
#endif
  soundPlay(sound);
}

static uint32_t s_remindAt = 0;       // when to sound once more for a request nobody has answered
static uint32_t s_workingSince = 0;   // since when things have been going on, as seen from here
static bool s_knowState = false;      // the first snapshot after connecting is where things stand, not news

static void toast(const char* words) {
  strlcpy(s_toast, words, sizeof(s_toast));
  s_toastUntil = millis() + 1800;
  s_dirty = true;
}

static void wake() {
  s_userOff = false;
  s_lastTouchAt = millis();
  s_dirty = true;
}

static void handleTouch() {
  Touch t = hwTouch();
#if RD_DEBUG_SERIAL
  if (s_fakeTouch.down) t = s_fakeTouch;
#endif
  uint32_t now = millis();
  bool asking = askOnScreen();
  char shown[48];
  whatIsShown(shown, sizeof(shown));
  if (strcmp(shown, s_shown) != 0) {
    strlcpy(s_shown, shown, sizeof(s_shown));
    s_shownAt = now;
  }
  // The thing the finger went down on is still the thing on the screen.
  bool same = s_down && shown[0] && !strcmp(shown, s_downFor);
  if (t.down) {
    if (!s_down) {
      s_down = true;
      s_downX = t.x;
      s_downY = t.y;
      s_downAt = now;
      s_swiped = false;
      // A touch on a dark screen lights it, and that is all it does.
      s_swallow = s_screenDark;
      if (s_swallow) wake();
      // A touch on a notice takes the notice away, and that is all it does.
      if (!s_swallow && s_noteShowing && !requestOnScreen() && !asking) {
        s_noteShowing = false;
        s_swallow = true;
      }
      strlcpy(s_downFor, shown, sizeof(s_downFor));
      same = shown[0] != 0;
      bool settled = shown[0] && now - s_shownAt >= SETTLE_MS;
      // An answer is picked by a hold that starts on its button.
      s_downOnChoice = !s_swallow && settled && asking && g_state.askPicked < 0 ? screenAskHit(t.x, t.y, 0) : -1;
      s_dirty = true;
#if RD_DEBUG_SERIAL
      Serial.printf("touch down %d %d\n", t.x, t.y);
#endif
      s_downOnAllow = !s_swallow && settled && requestOnScreen() && inside(t.x, t.y, ALLOW_X, BTN_Y, BTN_W, BTN_H);
      s_downOnDeny = !s_swallow && settled && requestOnScreen() && inside(t.x, t.y, DENY_X, BTN_Y, BTN_W, BTN_H);
    }
    s_lastTouchAt = now;
    s_lastContactAt = now;
    s_lastX = t.x;
    s_lastY = t.y;
    if (s_swallow) return;
    if (s_downOnAllow && !g_state.answered) {
      // The finger has to stay on the button the whole second, and the request has to be the one it went down on.
      if (!same || !requestOnScreen() || !inside(t.x, t.y, ALLOW_X - 12, BTN_Y - 12, BTN_W + 24, BTN_H + 24)) {
        s_downOnAllow = false;
        s_dirty = true;
      } else if (now - s_downAt >= HOLD_MS) {
        String lines[3];
        int count = 0;
        if (hintFits(lines, count)) {
          s_lastAllowed = true;
          s_answeredAt = now;
          protoAnswer(true);
          ping(SOUND_TAP);
        }
        s_downOnAllow = false;
        s_dirty = true;
      }
    }
    // "Deny" is held the same way, the whole second.
    if (s_downOnDeny && !g_state.answered) {
      if (!same || !requestOnScreen() || !inside(t.x, t.y, DENY_X - 12, BTN_Y - 12, BTN_W + 24, BTN_H + 24)) {
        s_downOnDeny = false;
        s_dirty = true;
      } else if (now - s_downAt >= HOLD_MS) {
        s_lastAllowed = false;
        s_answeredAt = now;
        protoAnswer(false);
        ping(SOUND_TAP);
        s_downOnDeny = false;
        s_dirty = true;
      }
    }
    // And so is an answer to a question: the finger stays on the button it went down on, the whole second.
    if (s_downOnChoice >= 0) {
      if (!same || !asking || g_state.askPicked >= 0 || screenAskHit(t.x, t.y, 12) != s_downOnChoice) {
        s_downOnChoice = -1;
        s_dirty = true;
      } else if (now - s_downAt >= HOLD_MS) {
        protoChoose(s_downOnChoice);
        ping(SOUND_TAP);
        s_downOnChoice = -1;
        s_dirty = true;
      }
    }
    // The page turns as soon as the finger has gone far enough, without waiting for it to lift.
    if (!requestOnScreen() && !asking && !s_swiped) {
      int dx = t.x - s_downX, dy = t.y - s_downY;
      if (abs(dy) > 70 && abs(dy) > abs(dx)) {
        s_swiped = true;
        // Up for the list, down to go back. The computer's own page has no list.
        s_showList = dy < 0 && !(pagesOn() && s_page == PAGE_MAC);
        s_listAt = now;
        s_dirty = true;
      } else if (pagesOn() && abs(dx) > 70 && abs(dx) > abs(dy)) {
        s_swiped = true;
        turnPage(dx < 0 ? 1 : -1);   // towards the left for the next page, as a page is pushed away
      }
    }
    return;
  }
  if (!s_down) return;
  // One reading without a finger is not a lift: the controller comes back empty now and then. If it counted, the
  // next reading would be a new touch, and a finger that had been resting there all along could start a hold.
  if ((int32_t)(now - s_lastContactAt) < 80) return;
  s_down = false;
  s_downOnAllow = false;
  s_downOnDeny = false;
  s_downOnChoice = -1;
  s_dirty = true;
  bool swallowed = s_swallow;
  s_swallow = false;
  int dx = s_lastX - s_downX, dy = s_lastY - s_downY;
#if RD_DEBUG_SERIAL
  Serial.printf("touch up %d %d after %lu ms\n", s_lastX, s_lastY, (unsigned long)(now - s_downAt));
#endif
  if (swallowed) return;
  // Lifting the finger answers nothing: every button is held, and a hold that ended early is no answer.
  if (requestOnScreen() || asking) return;
  // A swipe so quick that only its two ends were seen.
  if (!s_swiped && abs(dy) > 70 && abs(dy) > abs(dx)) {
    s_showList = dy < 0 && !(pagesOn() && s_page == PAGE_MAC);
    s_listAt = now;
  } else if (!s_swiped && pagesOn() && abs(dx) > 70 && abs(dx) > abs(dy)) {
    turnPage(dx < 0 ? 1 : -1);
  }
}

static void calibrateStart();

// The keys never answer a request or a question, and while a request is on the screen they do not turn the page
// away from it.
//   power: a press switches the screen off or on; held a second and a half, "do not disturb" on or off
//   KEY3:  a press turns the page; held a second and a half, sound off or on
//   BOOT:  a press goes back to the main screen; held three seconds, it starts measuring the touch
// With a question from another program on the screen, a press of KEY3 or BOOT puts it aside on this device: it
// is not answered, and stays on the computer. With a notice on the screen, the press takes the notice away.
// A press on a dark screen lights it, and that is all it does (the power key included).
static void handleKeys(uint32_t now) {
  KeyEvent event = hwKeyEvent();
  if (event == KEY_NONE) return;
  bool dark = s_screenDark;
#if RD_DEBUG_SERIAL
  static const char* const NAMES[] = {"", "power, short", "power, long", "KEY3, short", "KEY3, long", "BOOT, short", "BOOT, long"};
  Serial.printf("keys: %s%s\n", NAMES[event], dark ? " (the screen was dark)" : "");
#endif
  s_lastTouchAt = now;
  s_dirty = true;
  switch (event) {
    case KEY_POWER_SHORT:
      if (dark) wake();
      else s_userOff = true;
      break;
    case KEY_POWER_LONG:
      s_dnd = !s_dnd;
      s_kept.putBool("dnd", s_dnd);
      wake();
      toast(s_dnd ? "勿扰：开" : "勿扰：关");
      break;
    case KEY_USER_SHORT:
      if (dark) wake();
      else if (askOnScreen()) strlcpy(s_askAside, g_state.askId, sizeof(s_askAside));
      else if (s_noteShowing && !requestOnScreen()) s_noteShowing = false;
      else if (!requestOnScreen() && !(pagesOn() && s_page == PAGE_MAC)) {
        s_showList = !s_showList;
        s_listAt = now;
      }
      break;
    case KEY_USER_LONG:
      s_mute = !s_mute;
      s_kept.putBool("mute", s_mute);
      wake();
      toast(s_mute ? "静音：开" : "静音：关");
      if (!s_mute) ping(SOUND_TAP);
      break;
    case KEY_BOOT_SHORT:
      if (dark) wake();
      else if (askOnScreen()) strlcpy(s_askAside, g_state.askId, sizeof(s_askAside));
      else if (s_noteShowing && !requestOnScreen()) s_noteShowing = false;
      else if (!requestOnScreen()) {
        // Out of the list if it is open; otherwise on to the next page.
        if (s_showList) s_showList = false;
        else if (pagesOn()) turnPage(1);
      }
      break;
    case KEY_BOOT_LONG:
      // Measuring the touch. Not while something waits for an answer or six digits are up, and only with the
      // screens that can say what to do.
      wake();
      if (screensReady() && !requestOnScreen() && !askOnScreen() && passkeyToShow() == 0) calibrateStart();
      break;
    default:
      break;
  }
}

// MARK: measuring the touch

// Where a finger is read is not quite where it aims (hw.h). BOOT held for three seconds starts this: nine crosses,
// a finger held on each, and from the nine pairs of "aimed here, read there" the correction is worked out and kept.
// Any key ends it without changing anything; so does a request or a question arriving, which matter more.
static bool s_cal = false;
static int s_calIndex = 0;
static bool s_calDown = false, s_calTaken = false, s_calDrawn = false;
static uint32_t s_calDownAt = 0, s_calSeenAt = 0;
static long s_calSumX = 0, s_calSumY = 0;
static int s_calCount = 0;
static const int CAL_POINTS = 9;
static const int CAL_AT[3] = {84, 240, 396};
static float s_calReadX[CAL_POINTS], s_calReadY[CAL_POINTS];
static char s_calPrompt[sizeof(g_state.promptId)] = "", s_calAsk[sizeof(g_state.askId)] = "";
// How it went, shown for a few seconds after the last cross. 0: nothing to show.
static uint32_t s_calResultUntil = 0;
static bool s_calKept = false;
static int s_calBefore = 0, s_calAfter = 0;

static void calibrateStart() {
  s_cal = true;
  s_calIndex = 0;
  s_calDown = s_calTaken = s_calDrawn = false;
  s_calResultUntil = 0;
  s_calSeenAt = millis();
  strlcpy(s_calPrompt, g_state.prompt ? g_state.promptId : "", sizeof(s_calPrompt));
  strlcpy(s_calAsk, g_state.ask ? g_state.askId : "", sizeof(s_calAsk));
  s_dirty = true;
#if RD_DEBUG_SERIAL
  Serial.printf("cal start %d\n", CAL_POINTS);
#endif
}

static void calibrateStop(const char* why) {
  s_cal = false;
  s_calResultUntil = 0;
  s_lastTouchAt = millis();
  s_dirty = true;
#if RD_DEBUG_SERIAL
  Serial.printf("cal stopped: %s\n", why);
#else
  (void)why;
#endif
}

#if RD_DEBUG_SERIAL
void uiDebugCalibrate(bool on) {
  if (on) calibrateStart();
  else calibrateStop("asked to");
}
#endif

// One axis: the straight line through the nine pairs (aimed, read) that misses them by the least, squares summed.
// read = scale * aimed + offset.
static bool fitAxis(const float* read, bool across, float& scale, float& offset) {
  float meanAimed = 0, meanRead = 0;
  for (int i = 0; i < CAL_POINTS; i++) {
    meanAimed += CAL_AT[across ? i % 3 : i / 3];
    meanRead += read[i];
  }
  meanAimed /= CAL_POINTS;
  meanRead /= CAL_POINTS;
  float both = 0, spread = 0;
  for (int i = 0; i < CAL_POINTS; i++) {
    float aimed = CAL_AT[across ? i % 3 : i / 3] - meanAimed;
    both += aimed * (read[i] - meanRead);
    spread += aimed * aimed;
  }
  if (spread < 1) return false;
  scale = both / spread;
  offset = meanRead - scale * meanAimed;
  return scale > 0.1f;
}

// All nine are in: work the correction out, and keep it if the nine readings agree with it.
static void calibrateFinish() {
  TouchFix was = hwTouchFix(), fix = was;
  bool kept = fitAxis(s_calReadX, true, fix.scaleX, fix.offsetX) && fitAxis(s_calReadY, false, fix.scaleY, fix.offsetY);
  float before = 0, after = 0, worst = 0;
  if (kept) {
    for (int i = 0; i < CAL_POINTS; i++) {
      float tx = CAL_AT[i % 3], ty = CAL_AT[i / 3];
      before += hypotf((s_calReadX[i] - was.offsetX) / was.scaleX - tx, (s_calReadY[i] - was.offsetY) / was.scaleY - ty);
      float miss = hypotf((s_calReadX[i] - fix.offsetX) / fix.scaleX - tx, (s_calReadY[i] - fix.offsetY) / fix.scaleY - ty);
      after += miss;
      if (miss > worst) worst = miss;
    }
    before /= CAL_POINTS;
    after /= CAL_POINTS;
    // A finger held still on a cross is read to within a few pixels of where the line says. Nine readings that the
    // best line still misses by much more were not nine steady presses on nine crosses: nothing is changed then.
    kept = after <= 10 && worst <= 24 && hwSetTouchFix(fix, true);
  }
  s_cal = false;
  s_calKept = kept;
  s_calBefore = (int)lroundf(before);
  s_calAfter = (int)lroundf(after);
  s_calResultUntil = millis() + 4000;
  if (s_calResultUntil == 0) s_calResultUntil = 1;
  s_calDrawn = false;
#if RD_DEBUG_SERIAL
  Serial.printf("cal done: %s, scale %.4f %.4f offset %.2f %.2f, off by %.1f before, %.1f after, worst %.1f\n", kept ? "kept" : "not kept",
                fix.scaleX, fix.scaleY, fix.offsetX, fix.offsetY, before, after, worst);
#endif
}

// One pass of the measurement. The finger's place is read as often as the loop comes round and nothing shows
// where it was read: a mark under the finger would have the person correct for it.
static void calibrateTick() {
  uint32_t now = millis();
  Touch raw = hwTouchRaw();
#if RD_DEBUG_SERIAL
  if (s_fakeTouch.down) raw = s_fakeTouch;   // a finger from the console, for trying the sequence out
#endif
  KeyEvent key = hwKeyEvent();
  if (!s_cal) {
    // The result stays for a few seconds; a key or a touch takes it away sooner.
    if (key != KEY_NONE || raw.down || (int32_t)(now - s_calResultUntil) >= 0) {
      s_calResultUntil = 0;
      s_lastTouchAt = now;
      s_dirty = true;
      return;
    }
    if (!s_calDrawn) {
      s_calDrawn = true;
      g->fillScreen(BLACK);
      screenCalibrateResult((uint16_t*)g->getFramebuffer(), s_calKept, s_calBefore, s_calAfter);
      hwPush();
    }
    return;
  }
  if (key != KEY_NONE) {
    calibrateStop("a key");
    return;
  }
  if ((g_state.prompt && strcmp(g_state.promptId, s_calPrompt) != 0) || (g_state.ask && strcmp(g_state.askId, s_calAsk) != 0)) {
    calibrateStop("something to answer arrived");
    return;
  }
  if (raw.down) s_calSeenAt = now;
  if (now - s_calSeenAt > 90000) {
    calibrateStop("no touch for a minute and a half");
    return;
  }
  if (s_calTaken) {
    if (!raw.down) {
      s_calTaken = false;
      s_calDrawn = false;
      if (++s_calIndex >= CAL_POINTS) {
        calibrateFinish();
        return;
      }
    }
  } else if (raw.down) {
    if (!s_calDown) {
      s_calDown = true;
      s_calDownAt = now;
      s_calSumX = s_calSumY = 0;
      s_calCount = 0;
    }
    // The first moments are the finger arriving; what counts is where it settles.
    if (now - s_calDownAt >= 200) {
      s_calSumX += raw.x;
      s_calSumY += raw.y;
      s_calCount++;
    }
    if (now - s_calDownAt >= 800 && s_calCount >= 3) {
      s_calReadX[s_calIndex] = (float)s_calSumX / s_calCount;
      s_calReadY[s_calIndex] = (float)s_calSumY / s_calCount;
#if RD_DEBUG_SERIAL
      TouchFix fix = hwTouchFix();
      Serial.printf("cal %d target %d %d read %.1f %.1f corrected %.1f %.1f samples %d\n", s_calIndex, CAL_AT[s_calIndex % 3], CAL_AT[s_calIndex / 3],
                    s_calReadX[s_calIndex], s_calReadY[s_calIndex], (s_calReadX[s_calIndex] - fix.offsetX) / fix.scaleX,
                    (s_calReadY[s_calIndex] - fix.offsetY) / fix.scaleY, s_calCount);
#endif
      s_calTaken = true;
      s_calDown = false;
      s_calDrawn = false;
    }
  } else if (s_calDown) {
    s_calDown = false;
#if RD_DEBUG_SERIAL
    Serial.printf("cal %d lifted too soon\n", s_calIndex);
#endif
  }
  if (!s_calDrawn) {
    s_calDrawn = true;
    hwScreen(true);
    hwBrightness(170);
    g->fillScreen(BLACK);
    // Where the cross goes is worked out here, after the step above may have moved on to the next one. (It used
    // to be worked out at the top, and every cross after the first was drawn where the one before it had been.)
    screenCalibrate((uint16_t*)g->getFramebuffer(), CAL_AT[s_calIndex % 3], CAL_AT[s_calIndex / 3], s_calIndex, CAL_POINTS, s_calTaken);
    hwPush();
  }
}

// MARK: the loop

void uiBegin() {
  g = hwCanvas();
  s_lastTouchAt = millis();
  screensBegin();
  s_kept.begin("desk", false);
  s_dnd = s_kept.getBool("dnd", false);
  s_mute = s_kept.getBool("mute", false);
#if RD_DEBUG_SERIAL
  Serial.printf("ui: the fonts in flash %s\n", screensReady() ? "were found, the new screens are on" : "were not found, the old screens are used");
  Serial.printf("ui: do not disturb %d, muted %d\n", (int)s_dnd, (int)s_mute);
#endif
}

void uiTick() {
  bool modern = screensReady();
  if (s_cal || s_calResultUntil != 0) {
    calibrateTick();
    return;
  }
  DENY_X = modern ? SCREEN_DENY_X : 34;
  ALLOW_X = modern ? SCREEN_ALLOW_X : 250;
  BTN_Y = modern ? SCREEN_BUTTON_Y : 330;
  BTN_W = modern ? SCREEN_BUTTON_W : 196;
  BTN_H = modern ? SCREEN_BUTTON_H : 110;
#if RD_DEBUG_SERIAL
  if (s_debugPage >= 0) {
    s_page = s_debugPage % PAGES;
    s_showList = false;
    s_dirty = true;
    s_debugPage = -1;
  }
#endif
  // The touch is read first: it stamps times of its own, and "now" must not be earlier than those.
  handleTouch();
  uint32_t now = millis();
  handleKeys(now);

  bool connected = linkConnected() || s_debugFeed;
  if (s_wasConnected != connected) s_dirty = true;
  if (s_wasConnected && !connected) {
    protoReset();
    s_showList = false;
    s_knowState = false;
    s_noteShowing = false;
    s_askAside[0] = s_lastAsk[0] = s_lastNote[0] = 0;
    s_lastStateAt = g_state.at;   // so that the emptying just done is not itself taken for a snapshot arriving
  }
  s_wasConnected = connected;

  State& s = g_state;
  bool fresh = connected && s.have && (now - s.at) < STALE_MS;
  // A link gone quiet has nothing to answer. The ids go too, so that if the same request or question is still
  // there when the computer speaks again, it comes back as a new arrival instead of staying gone.
  if (!fresh && s.prompt) {
    s.prompt = false;
    s.promptId[0] = 0;
  }
  if (!fresh && s.ask) {
    s.ask = false;
    s.askId[0] = 0;
  }

  // A request always lights the screen. Other news does too, unless "do not disturb" is on: something starting,
  // finishing, failing or wanting attention. While something is going on the screen stays bright.
  if (strcmp(s_lastPrompt, s.promptId) != 0) {
    strlcpy(s_lastPrompt, s.promptId, sizeof(s_lastPrompt));
    if (s.prompt) {
      wake();
      ping(SOUND_REQUEST);
      s_remindAt = now + 30000;
    }
    s_dirty = true;
  }
  // A request nobody has touched for half a minute gets one more call, and only one.
  if (s_remindAt != 0 && (int32_t)(now - s_remindAt) >= 0) {
    s_remindAt = 0;
    if (requestOnScreen() && !s.answered) ping(SOUND_REQUEST);
  }
  // A question lights the screen as a request does, and has the same sound: both want an answer here.
  if (strcmp(s_lastAsk, s.askId) != 0) {
    strlcpy(s_lastAsk, s.askId, sizeof(s_lastAsk));
    s_askAside[0] = 0;
    if (s.ask && screensReady()) {
      wake();
      ping(SOUND_REQUEST);
    }
    s_dirty = true;
  }
  // A notice is ordinary news: it lights the screen unless "do not disturb" is on, and sounds by how it went.
  // One that was already there when the computer connected is shown without a sound.
  if (strcmp(s_lastNote, s.noteId) != 0) {
    strlcpy(s_lastNote, s.noteId, sizeof(s_lastNote));
    if (s.note && screensReady()) {
      s_noteShowing = true;
      s_noteUntil = now + NOTE_MS;
      if (!s_dnd) wake();
      if (s_knowState) ping(!strcmp(s.noteLevel, "error") ? SOUND_FAILED : (!strcmp(s.noteLevel, "done") ? SOUND_DONE : SOUND_WAITING));
    }
    s_dirty = true;
  }
  if (s_noteShowing && (int32_t)(now - s_noteUntil) >= 0) {
    s_noteShowing = false;
    s_dirty = true;
  }
  if (s.at != s_lastStateAt) {
    s_lastStateAt = s.at;
    s_dirty = true;
    if (!s_dnd) {
      if (s.overall != OV_IDLE) s_lastTouchAt = now;
      if (s.overall != s_lastOverall && s.overall != OV_IDLE) wake();
    }
    if (pagesOn()) {
      if (!s_knowState) {
        // On connecting: the page of whatever is most urgent, and the renders' if nothing is.
        s_page = !strcmp(s.topKind, "render") || s.a.overall == OV_IDLE ? 0 : 1;
      } else if (!s_down) {
        // A side that now needs somebody, or has failed, takes the screen if another page is showing. Anything
        // less (something starting, something done) leaves the page where the user put it; the marks along the
        // bottom say what goes on elsewhere.
        bool sessionsCall = s.a.overall != s_lastSessions && (s.a.overall == OV_WAITING || s.a.overall == OV_ERROR);
        bool rendersCall = s.r.overall != s_lastRenders && (s.r.overall == OV_WAITING || s.r.overall == OV_ERROR);
        if (sessionsCall && s_page != 1) turnPage(1 - s_page);
        else if (rendersCall && !sessionsCall && s_page != 0) turnPage(-s_page);
      }
      s_lastRenders = s.r.overall;
      s_lastSessions = s.a.overall;
    }
    if (!s_knowState) {
      s_knowState = true;
      s_workingSince = now;
    } else if (s.overall != s_lastOverall) {
      // What changed, as a sound. "Done" only after something long: two minutes of work, as seen from here.
      if (s.overall == OV_WORKING) s_workingSince = now;
      else if (s.overall == OV_WAITING && !s.prompt) ping(SOUND_WAITING);
      else if (s.overall == OV_ERROR) ping(SOUND_FAILED);
      else if (s.overall == OV_DONE && s_lastOverall == OV_WORKING && now - s_workingSince >= 120000) ping(SOUND_DONE);
    }
    s_lastOverall = s.overall;
  }
  if (g_mac.at != s_lastMacAt) {
    s_lastMacAt = g_mac.at;
    s_dirty = true;   // its page shows them, and its mark along the bottom may change colour
  }
  uint32_t passkey = passkeyToShow();
  if (passkey != s_lastPasskey) {
    s_lastPasskey = passkey;
    if (passkey != 0) wake();
    s_dirty = true;
  }
  if (s_showList && now - s_listAt > LIST_BACK_MS) {
    s_showList = false;
    s_dirty = true;
  }
  if (s_toast[0] && (int32_t)(now - s_toastUntil) >= 0) {
    s_toast[0] = 0;
    s_dirty = true;
  }

  // Brightness: full when there is something to see; dim, then dark, when there is not and nobody has touched
  // it. Switched off with the power key, it stays dark until a key, a touch, or news.
  bool quiet = (!fresh || s.overall == OV_IDLE || s_dnd) && !requestOnScreen() && !askOnScreen() && !s_noteShowing;
  // (A key press just above may have stamped a time a moment later than `now`.)
  uint32_t untouched = (int32_t)(now - s_lastTouchAt) > 0 ? now - s_lastTouchAt : 0;
  bool dark = s_userOff;
#if !RD_DEBUG_SERIAL
  // (The bring-up build does not go dark by itself, only dims: a board being worked on should stay readable.)
  if (quiet && passkey == 0 && untouched > OFF_AFTER_MS) dark = true;
#endif
  if (dark) {
    if (!s_screenDark) {
      s_screenDark = true;
      hwScreen(false);
    }
    return;
  }
  if (s_screenDark) {
    s_screenDark = false;
    s_dirty = true;
  }
  hwScreen(true);
  hwBrightness(quiet && untouched > DIM_AFTER_MS ? 40 : 170);

#if RD_DEBUG_SERIAL
  // A picture sent over USB stays up until its time is over or the screen is touched.
  if (s_holdUntil != 0) {
    if (s_down || (int32_t)(now - s_holdUntil) >= 0) s_holdUntil = 0;
    else return;
  }
#endif

  // Draw at once when something changed; otherwise about ten times a second while something moves, and once a
  // second when nothing does.
  bool moving = s_down || s_toast[0] || (fresh && (requestOnScreen() || askOnScreen() || s.overall == OV_WAITING));
  if (!s_dirty && now - s_lastDrawAt < (moving ? 100u : 1000u)) return;
  s_dirty = false;
  s_lastDrawAt = now;

#if RD_DEBUG_SERIAL
  uint32_t drawStarted = micros();
#endif
  g->fillScreen(BLACK);
  if (modern) {
    uint16_t* frame = (uint16_t*)g->getFramebuffer();
    float held = s_down ? min(1.0f, (now - s_downAt) / (float)HOLD_MS) : -1.0f;
    float hold = s_downOnAllow ? held : -1.0f, holdDeny = s_downOnDeny ? held : -1.0f;
    bool link = !fresh || passkey != 0, request = !link && requestOnScreen();
    bool ask = !link && !request && askOnScreen(), note = !link && !request && !ask && s_noteShowing;
    bool list = !link && !request && !ask && !note && s_showList;
    bool plain = !link && !request && !ask && !note;
    // A computer that does not send RenderDock's fields has no renders and says nothing about itself: one page.
    bool paged = pagesOn();
    int page = paged ? s_page : 1;
    const Side& side = page == 0 ? s.r : s.a;
    // What has a percentage is shown with the ring: a render, or a task another program reports on.
    bool measured = (!strcmp(side.topKind, "render") || !strcmp(side.topKind, "task")) && side.topPercent >= 0;
    if (link) screenLink(frame, passkey, linkConnected(), linkName());
    else if (request) screenRequest(frame, hold, holdDeny, s_lastAllowed);
    else if (ask) screenAsk(frame, s_down ? s_downOnChoice : -1, max(0.0f, held));
    else if (note) screenNote(frame);
    else if (page == PAGE_MAC) screenMac(frame);
    else if (list) screenList(frame, side, paged ? page : -1);
    else if (side.overall == OV_ERROR) screenFinished(frame, side, true);
    else if (side.overall == OV_WAITING) screenWaiting(frame, side);
    else if (side.overall == OV_WORKING && measured) screenRendering(frame, side);
    else if (side.overall == OV_WORKING && page == 0) screenRenderGoing(frame, side);
    else if (side.overall == OV_WORKING) screenAgents(frame, side);
    else if (side.overall == OV_DONE) screenFinished(frame, side, false);
    else screenIdle(frame, paged ? page : -1);
    if (plain && paged) screenPages(frame, page);
    if (plain && !list && page != PAGE_MAC && (s_dnd || s_mute)) screenBadge(frame, s_dnd ? "勿扰" : "静音");
    if (s_toast[0]) screenToast(frame, s_toast);
  } else {
    if (!fresh || passkey != 0) drawLink();
    else if (requestOnScreen()) drawRequest();
    else if (s_showList) drawList();
    else if (s.overall == OV_ERROR) drawDone(true);
    else if (s.overall == OV_WAITING) drawWaiting();
    else if (s.overall == OV_WORKING) drawWorking();
    else if (s.overall == OV_DONE) drawDone(false);
    else drawIdle();
    if (s_toast[0]) {
      g->fillRoundRect(110, 206, 260, 56, 28, TRACK);
      text(s_toast, 240, 246, WHITE);
    }
  }
#if RD_DEBUG_SERIAL
  // Where the firmware thinks the finger is: the mark should sit under it.
  if (s_down) {
    g->drawCircle(s_lastX, s_lastY, 34, WHITE);
    g->fillCircle(s_lastX, s_lastY, 6, WHITE);
  }
  s_drawMicros = micros() - drawStarted;
#endif
  // Sending the frame takes longer than drawing it. Look at the finger once more before that, so that it is
  // read twice a frame and a quick swipe leaves more than two points.
  handleTouch();
#if RD_DEBUG_SERIAL
  uint32_t pushStarted = micros();
#endif
  hwPush();
#if RD_DEBUG_SERIAL
  s_pushMicros = micros() - pushStarted;
#endif
}
