#include "screens.h"
#include "board.h"
#include "font.h"
#include "shapes.h"
#include "state.h"

// The desktop app's colours.
static const uint16_t MINT = rgb(79, 237, 176), AQUA = rgb(66, 194, 255), AMBER = rgb(255, 189, 69), CORAL = rgb(255, 110, 105);
static const uint16_t TEAL = rgb(74, 222, 204);      // between mint and aqua, where one colour has to do for both
static const uint16_t WHITE = rgb(245, 245, 245);    // the main text
static const uint16_t BRIGHT = rgb(214, 214, 214);   // the second thing to read
static const uint16_t SOFT = rgb(189, 189, 189);     // labels
static const uint16_t DIM = rgb(153, 153, 153);      // the least important, still readable
static const uint16_t TRACK = rgb(23, 23, 23), EMPTY = rgb(33, 33, 33);
static const uint16_t CARD = rgb(20, 23, 28), HAIR = rgb(45, 47, 51);
static const uint16_t AQUA_UNDER = rgb(11, 31, 41), MINT_UNDER = rgb(12, 36, 26), GREY_UNDER = rgb(26, 26, 26);
static const uint16_t AMBER_UNDER = rgb(51, 38, 14), AMBER_LINE = rgb(87, 64, 23);
static const uint16_t PILL = rgb(33, 33, 33), PILL_TEXT = rgb(223, 229, 240);
// A question from another program has a colour of its own (the desktop app's lilac).
static const uint16_t LILAC = rgb(179, 161, 255), LILAC_UNDER = rgb(31, 27, 50), LILAC_LINE = rgb(98, 88, 150), LILAC_TEXT = rgb(234, 228, 255);

// What every screen with the ring shares: the ring itself, then a title, a line under it, and the row of labels.
static const int CX = 240, CY = 150, OUTER = 138, THICK = 22;
static const int NUMBER_Y = 185, UNDER_NUMBER_Y = 227, TITLE_Y = 335, LINE_Y = 381, LINE_MIDDLE = 372, LABELS_TOP = 412;

// Faces in the font file (tools/make-fonts.swift): 10, 11, 12 are Chinese text at 26, 30 and 38 pixels, 13 the
// words on the buttons at 34; 20…24 and 30…34 are the two rounded families at 26, 30, 38, 118 and 92.
static int s_rounded = 2;
static bool s_use = true;
static const uint16_t TEXT26 = 10, TEXT30 = 11, TEXT38 = 12, BUTTON34 = 13;
static uint16_t rounded(int size) { return (uint16_t)(s_rounded * 10 + size); }   // 0 → 26, 1 → 30, 2 → 38, 3 → 118, 4 → 92

// Plain text, and text whose letters and digits take the rounded face (names, numbers).
static TextStyle text26() { return {TEXT26, 0}; }
static TextStyle text30() { return {TEXT30, 0}; }
static TextStyle text38() { return {TEXT38, 0}; }
static TextStyle name26() { return {TEXT26, rounded(0)}; }
static TextStyle name30() { return {TEXT30, rounded(1)}; }
static TextStyle name38() { return {TEXT38, rounded(2)}; }

void screensBegin() { fontBegin(); }
bool screensReady() { return s_use && fontReady() && fontHas(TEXT38) && fontHas(BUTTON34) && fontHas(rounded(3)); }

#if RD_DEBUG_SERIAL
void screensDebugRounded(int family) {
  if (family == 2 || family == 3) s_rounded = family;
}
void screensDebugUse(bool on) { s_use = on; }
#endif

// MARK: pieces

static String span(int seconds) {
  if (seconds < 60) return String(seconds) + " 秒";
  if (seconds < 3600) return String(seconds / 60) + " 分";
  return String(seconds / 3600) + " 时";
}

// How long the named row has been in its state, or -1 if the list does not say.
static int ageOf(const char* name) {
  const State& s = g_state;
  for (int i = 0; i < s.rowCount; i++) {
    if (!strcmp(s.rows[i].name, name)) return s.rows[i].age;
  }
  return -1;
}

// A tick in a box 20 pixels across, times `scale`.
static void tick(uint16_t* frame, float x, float y, float scale, uint16_t color) {
  shapeLine(frame, x + 3.9f * scale, y + 10.6f * scale, x + 7.9f * scale, y + 14.6f * scale, 2.7f * scale, color);
  shapeLine(frame, x + 7.9f * scale, y + 14.6f * scale, x + 16.1f * scale, y + 5.6f * scale, 2.7f * scale, color);
}

// A little laptop, in a box 30 by 24, times `scale`: "this is for the computer".
static void laptop(uint16_t* frame, int x, int y, float scale, uint16_t color) {
  shapeRoundRectLine(frame, x + (int)(5 * scale), y + (int)(3 * scale), (int)(20 * scale), (int)(13 * scale), (int)(2.5f * scale), 2.2f * scale, color);
  shapeLine(frame, x + 1.5f * scale, y + 20.5f * scale, x + 28.5f * scale, y + 20.5f * scale, 2.4f * scale, color);
}

struct Label {
  String text;
  uint16_t color, under;
  int mark;             // 0 none, 1 a dot, 2 a tick
  uint16_t markColor;   // 0: the same as the text
};

// The row of small labels along the bottom, centred.
static void labels(uint16_t* frame, Label* list, int count) {
  const int height = 44, gap = 12;
  TextStyle style = name26();
  int widths[3], total = 0;
  for (int i = 0; i < count; i++) {
    int mark = list[i].mark == 1 ? 10 + 9 : (list[i].mark == 2 ? 20 + 9 : 3);
    widths[i] = 15 + mark + fontWidth(style, list[i].text.c_str()) + 18;
    total += widths[i] + (i ? gap : 0);
  }
  int x = LCD_W / 2 - total / 2;
  for (int i = 0; i < count; i++) {
    uint16_t markColor = list[i].markColor ? list[i].markColor : list[i].color;
    shapeRoundRect(frame, x, LABELS_TOP, widths[i], height, height / 2, list[i].under);
    int at = x + 15;
    if (list[i].mark == 1) {
      shapeDisc(frame, at + 5, LABELS_TOP + height / 2.0f, 5, markColor);
      at += 10 + 9;
    } else if (list[i].mark == 2) {
      tick(frame, at, LABELS_TOP + 12, 1, markColor);
      at += 20 + 9;
    } else {
      at += 3;
    }
    fontDraw(frame, style, at, LABELS_TOP + 31, list[i].color, list[i].text.c_str());
    x += widths[i] + gap;
  }
}

// How the sessions are doing, for the row of labels. `skipWorking` when the big number already says it.
static void sessionLabels(uint16_t* frame, bool skipWorking, bool sayWhenNone) {
  const State& s = g_state;
  if (!s.extended) return;
  Label list[3];
  int count = 0;
  if (!skipWorking && s.agentsWorking > 0) list[count++] = {String(s.agentsWorking) + " 在干活", AQUA, AQUA_UNDER, 1, 0};
  if (s.agentsDone > 0) list[count++] = {String(s.agentsDone) + " 做完", MINT, MINT_UNDER, 2, 0};
  if (count < 2 && skipWorking && s.agentsIdle > 0) list[count++] = {String(s.agentsIdle) + " 空闲", SOFT, GREY_UNDER, 0, 0};
  if (count == 0 && sayWhenNone) list[count++] = {String("没有会话在干活"), SOFT, GREY_UNDER, 0, 0};
  if (count) labels(frame, list, count);
}

// The line under the title: a tool's name on a small plate, then a few words.
static void toolLine(uint16_t* frame, const char* tool, const String& rest) {
  TextStyle plate = name26(), words = name26();
  int plateWidth = tool[0] ? fontWidth(plate, tool) + 26 : 0;
  String shown = fontFit(words, rest.c_str(), 440 - plateWidth - 14, false);
  int restWidth = fontWidth(words, shown.c_str());
  int gap = plateWidth && restWidth ? 14 : 0;
  int x = CX - (plateWidth + gap + restWidth) / 2;
  if (plateWidth) {
    shapeRoundRect(frame, x, LINE_MIDDLE - 17, plateWidth, 34, 16, PILL);
    fontDraw(frame, plate, x + 13, LINE_Y, PILL_TEXT, tool);
    x += plateWidth + gap;
  }
  if (restWidth) fontDraw(frame, words, x, LINE_Y, SOFT, shown.c_str());
}

// The ring takes far longer to work out than anything else on a screen (every pixel of it is measured), and it
// changes rarely. So the patch of the frame it lands on is kept, and put back as it is until something about
// the ring is different.
enum RingKind { RING_ARC, RING_WHOLE, RING_DOTS };
static void ring(uint16_t* frame, RingKind kind, int percent, uint16_t from, uint16_t to, uint16_t track) {
  static uint16_t* kept = nullptr;
  static struct { int kind, percent; uint16_t from, to, track; bool valid; } keptFor = {0, 0, 0, 0, 0, false};
  const int reach = OUTER + 15;
  int left = max(0, CX - reach), right = min(LCD_W - 1, CX + reach), top = max(0, CY - reach), bottom = min(LCD_H - 1, CY + reach);
  int width = right - left + 1, height = bottom - top + 1;
  if (!kept) kept = (uint16_t*)ps_malloc((size_t)width * height * 2);
  if (kept && keptFor.valid && keptFor.kind == kind && keptFor.percent == percent && keptFor.from == from && keptFor.to == to && keptFor.track == track) {
    for (int y = 0; y < height; y++) memcpy(frame + (top + y) * LCD_W + left, kept + y * width, (size_t)width * 2);
    return;
  }
  if (kind == RING_DOTS) {
    shapeDottedRing(frame, CX, CY, OUTER, THICK, 20, 6.5f, from, track);
  } else {
    float fraction = kind == RING_WHOLE ? 1.0f : percent / 100.0f;
    shapeRing(frame, CX, CY, OUTER, THICK, fraction, from, to, track);
    if (fraction > 0.0f && fraction < 0.999f) {
      // A bright point at the head of the arc.
      float angle = fraction * 6.2831853f, middle = OUTER - THICK / 2.0f;
      shapeDisc(frame, CX + middle * sinf(angle), CY - middle * cosf(angle), 4, WHITE, 235);
    }
  }
  if (kept) {
    for (int y = 0; y < height; y++) memcpy(kept + y * width, frame + (top + y) * LCD_W + left, (size_t)width * 2);
    keptFor = {kind, percent, from, to, track, true};
  }
}

// A count in the middle of the ring, and a word or two under it.
static void numberInRing(uint16_t* frame, int value, uint16_t color, const char* under) {
  char number[8];
  snprintf(number, sizeof(number), "%d", value);
  TextStyle big = {rounded(strlen(number) >= 3 ? 4 : 3), 0};
  fontDrawCentred(frame, big, CX, NUMBER_Y, color, number);
  if (under[0]) fontDrawCentred(frame, text30(), CX, UNDER_NUMBER_Y, BRIGHT, under);
}

void screenBadge(uint16_t* frame, const char* text) { fontDraw(frame, text26(), 30, 40, DIM, text); }

void screenToast(uint16_t* frame, const char* text) {
  int width = fontWidth(text30(), text) + 60;
  shapeRoundRect(frame, CX - width / 2, 198, width, 64, 32, rgb(38, 41, 48));
  shapeRoundRectLine(frame, CX - width / 2, 198, width, 64, 32, 1.5f, rgb(84, 88, 96));
  fontDrawCentred(frame, text30(), CX, 241, WHITE, text);
}

// MARK: link and pairing

void screenLink(uint16_t* frame, uint32_t passkey, bool connected, const char* name) {
  if (passkey != 0) {
    char front[4], back[4];
    snprintf(front, sizeof(front), "%03lu", (unsigned long)((passkey % 1000000) / 1000));
    snprintf(back, sizeof(back), "%03lu", (unsigned long)(passkey % 1000));
    TextStyle digits = {rounded(4), 0};
    int frontWidth = fontWidth(digits, front), backWidth = fontWidth(digits, back), gap = 26;
    int x = CX - (frontWidth + gap + backWidth) / 2;
    fontDrawCentred(frame, text30(), CX, 84, SOFT, "配对");
    fontDraw(frame, digits, x, 232, WHITE, front);
    fontDraw(frame, digits, x + frontWidth + gap, 232, WHITE, back);
    fontDrawCentred(frame, text30(), CX, 322, WHITE, "在电脑上输入这六位数");
    fontDrawCentred(frame, name26(), CX, 378, DIM, "30 秒内有效");
    return;
  }
  shapeRing(frame, CX, 108, 60, 12, 0.33f, MINT, AQUA, TRACK);
  shapeDisc(frame, CX, 108, 12, rgb(87, 87, 87));
  fontDrawCentred(frame, text38(), CX, 231, WHITE, connected ? "已连上，等电脑发数据" : "等电脑来连");
  fontDrawCentred(frame, name30(), CX, 280, SOFT, name);
  if (!connected) {
    fontDrawCentred(frame, text26(), CX, 358, SOFT, "在渲染坞的菜单里打开");
    fontDrawCentred(frame, text26(), CX, 396, SOFT, "「连接蓝牙小设备」");
  }
}

// MARK: the screens with the ring

void screenRendering(uint16_t* frame) {
  const State& s = g_state;
  float fraction = s.topPercent / 100.0f;
  ring(frame, RING_ARC, s.topPercent, MINT, AQUA, TRACK);

  // The number with its sign, as one group in the middle. Three digits take the smaller numerals.
  char number[8];
  snprintf(number, sizeof(number), "%d", s.topPercent);
  bool wide = strlen(number) >= 3;
  TextStyle big = {rounded(wide ? 4 : 3), 0}, small = {rounded(wide ? 1 : 2), 0};
  int about = s.topExact ? 0 : fontWidth(small, "≈") + 4;
  int numberWidth = fontWidth(big, number), signWidth = fontWidth(small, "%");
  int x = CX - (about + numberWidth + 6 + signWidth) / 2;
  if (about) fontDraw(frame, small, x, NUMBER_Y - 47, SOFT, "≈");
  fontDraw(frame, big, x + about, NUMBER_Y, WHITE, number);
  fontDraw(frame, small, x + about + numberWidth + 6, NUMBER_Y, SOFT, "%");
  if (s.topEta >= 0) fontDrawCentred(frame, name30(), CX, UNDER_NUMBER_Y, BRIGHT, (String("剩约 ") + span(s.topEta)).c_str());

  // The shot.
  fontDrawCentred(frame, name38(), CX, TITLE_Y, WHITE, fontFit(name38(), s.topName, 440, true).c_str());

  // Its job: the name, one piece per shot, and how many are done.
  if (s.jobTitle[0]) {
    TextStyle text = name26();
    bool pieces = s.jobTotal > 1 && s.jobTotal <= 16;
    String count = s.jobTotal > 1 ? String(s.jobDone) + "/" + s.jobTotal + " 段" : String("");
    int countWidth = fontWidth(text, count.c_str());
    // Beside the pieces the name has little room; alone on the line it has nearly all of it.
    String name = fontFit(text, s.jobTitle, pieces ? 170 : 392 - (count.length() ? countWidth + 30 : 0), false);
    int nameWidth = fontWidth(text, name.c_str());
    if (pieces) {
      fontDraw(frame, text, 44, LINE_Y, SOFT, name.c_str());
      fontDrawRight(frame, text, 436, LINE_Y, SOFT, count.c_str());
      int left = 44 + nameWidth + 14, right = 436 - countWidth - 14;
      float each = (right - left - 8.0f * (s.jobTotal - 1)) / s.jobTotal;
      for (int i = 0; i < s.jobTotal && each >= 6; i++) {
        int pieceLeft = left + (int)(i * (each + 8) + 0.5f), pieceWidth = (int)(each + 0.5f);
        shapeRoundRect(frame, pieceLeft, LINE_MIDDLE - 5, pieceWidth, 10, 5, i < s.jobDone ? MINT : EMPTY);
        if (i == s.jobDone && fraction > 0) shapeRoundRect(frame, pieceLeft, LINE_MIDDLE - 5, max(10, (int)(pieceWidth * min(1.0f, fraction))), 10, 5, MINT);
      }
    } else {
      fontDrawCentred(frame, text, CX, LINE_Y, SOFT, (count.length() ? name + " · " + count : name).c_str());
    }
  } else if (!strcmp(s.topKind, "task") && s.topTool[0]) {
    // A task another program reports on: who is reporting.
    int age = ageOf(s.topName);
    toolLine(frame, s.topTool, age >= 0 ? String("已经 ") + span(age) : String(""));
  }
  // "No sessions at work" is worth saying next to a render, not next to another program's task.
  sessionLabels(frame, false, strcmp(s.topKind, "task") != 0);
}

void screenAgents(uint16_t* frame) {
  const State& s = g_state;
  ring(frame, RING_DOTS, 0, AQUA, AQUA, rgb(10, 29, 38));
  if (!strcmp(s.topKind, "task")) {
    // A task that does not say how far along it is: no number to show, only that it is going.
    for (int i = -1; i <= 1; i++) shapeDisc(frame, CX + i * 34, CY - 6, 9, AQUA);
    fontDrawCentred(frame, text30(), CX, UNDER_NUMBER_Y, BRIGHT, "进行中");
    fontDrawCentred(frame, name38(), CX, TITLE_Y, WHITE, fontFit(name38(), s.topName, 440, true).c_str());
    int age = ageOf(s.topName);
    toolLine(frame, s.topTool, age >= 0 ? String("已经 ") + span(age) : String(""));
    sessionLabels(frame, false, false);
    return;
  }
  numberInRing(frame, s.extended ? s.agentsWorking : s.running, AQUA, "在干活");
  if (s.extended) {
    if (s.topName[0]) {
      fontDrawCentred(frame, name38(), CX, TITLE_Y, WHITE, fontFit(name38(), s.topName, 440, true).c_str());
      int age = ageOf(s.topName);
      toolLine(frame, s.topTool, age >= 0 ? String("已经 ") + span(age) : String(""));
    }
    sessionLabels(frame, true, false);
  } else {
    // The plain protocol: the computer's own line, and its latest entries.
    fontDrawCentred(frame, name30(), CX, TITLE_Y - 4, WHITE, fontFit(name30(), s.msg, 440, false).c_str());
    for (int i = 0; i < min(s.entryCount, 3); i++) {
      fontDrawCentred(frame, name26(), CX, LINE_Y + i * 36, SOFT, fontFit(name26(), s.entries[i], 440, false).c_str());
    }
  }
}

void screenWaiting(uint16_t* frame) {
  const State& s = g_state;
  ring(frame, RING_WHOLE, 100, AMBER, AMBER, TRACK);
  // The mark breathes: there is something to do, and it is not urgent enough to flash.
  float phase = (millis() % 2400) / 2400.0f;
  uint8_t strength = (uint8_t)(140 + 115 * (phase < 0.5f ? phase * 2 : (1 - phase) * 2));
  shapeRoundRect(frame, CX - 14, 84, 28, 90, 14, AMBER, strength);
  shapeDisc(frame, CX, 204, 15.5f, AMBER, strength);
  if (s.extended && s.topName[0]) {
    const char* tail = " 在等你";
    String who = fontFit(name38(), s.topName, 440 - fontWidth(name38(), tail), true) + tail;
    fontDrawCentred(frame, name38(), CX, TITLE_Y, WHITE, who.c_str());
    int age = ageOf(s.topName);
    toolLine(frame, s.topTool, age >= 0 ? String("等了 ") + span(age) : String(""));
    // Not a button: a line of text with a small computer beside it.
    const char* note = "这一条要到电脑上处理";
    int x = CX - (30 + 10 + fontWidth(text26(), note)) / 2;
    laptop(frame, x, LABELS_TOP + 10, 1, SOFT);
    fontDraw(frame, text26(), x + 40, LABELS_TOP + 31, SOFT, note);
  } else {
    fontDrawCentred(frame, name38(), CX, TITLE_Y, WHITE, (String(s.waiting) + " 个在等你").c_str());
    fontDrawCentred(frame, name26(), CX, LINE_Y, SOFT, fontFit(name26(), s.msg, 440, false).c_str());
  }
}

void screenFinished(uint16_t* frame, bool failed) {
  const State& s = g_state;
  bool render = !strcmp(s.topKind, "render");
  if (failed) {
    ring(frame, RING_WHOLE, 100, CORAL, CORAL, TRACK);
    shapeLine(frame, CX - 41, CY - 41, CX + 41, CY + 41, 23, CORAL);
    shapeLine(frame, CX + 41, CY - 41, CX - 41, CY + 41, 23, CORAL);
  } else {
    ring(frame, RING_WHOLE, 100, MINT, AQUA, TRACK);
    shapeLine(frame, CX - 52.5f, CY + 4, CX - 15.5f, CY + 41, 23, TEAL);
    shapeLine(frame, CX - 15.5f, CY + 41, CX + 54.5f, CY - 37, 23, TEAL);
  }
  fontDrawCentred(frame, text38(), CX, TITLE_Y, WHITE, failed ? (render ? "渲染失败" : "出错了") : (render ? "渲完了" : "做完了"));
  if (s.topName[0]) {
    if (render || !s.topTool[0]) {
      String what = s.jobTitle[0] ? String(s.topName) + " · " + s.jobTitle : String(s.topName);
      fontDrawCentred(frame, name26(), CX, LINE_Y, SOFT, fontFit(name26(), what.c_str(), 440, false).c_str());
    } else {
      toolLine(frame, s.topTool, String(s.topName));
    }
  }
  sessionLabels(frame, false, false);
}

void screenIdle(uint16_t* frame) {
  int hour, minute;
  if (protoClock(hour, minute)) {
    char clock[8];
    snprintf(clock, sizeof(clock), "%02d:%02d", hour, minute);
    fontDrawCentred(frame, {rounded(3), 0}, CX, 214, rgb(128, 128, 128), clock);
    int month, day, weekday;
    if (protoDate(month, day, weekday)) {
      static const char* const DAYS[] = {"周日", "周一", "周二", "周三", "周四", "周五", "周六"};
      fontDrawCentred(frame, name30(), CX, 283, DIM, (String(month) + " 月 " + day + " 日 · " + DAYS[weekday % 7]).c_str());
    }
  }
  Label nothing = {String("没有任务"), SOFT, GREY_UNDER, 1, MINT};
  labels(frame, &nothing, 1);
}

// MARK: the list

static uint16_t stateColor(const char* state) {
  if (!strcmp(state, "waiting")) return AMBER;
  if (!strcmp(state, "working")) return AQUA;
  if (!strcmp(state, "done")) return MINT;
  if (!strcmp(state, "error")) return CORAL;
  return SOFT;
}

static const char* stateWord(const char* state) {
  if (!strcmp(state, "waiting")) return "等你";
  if (!strcmp(state, "working")) return "在干活";
  if (!strcmp(state, "done")) return "刚做完";
  if (!strcmp(state, "error")) return "出错";
  return "";
}

void screenList(uint16_t* frame) {
  const State& s = g_state;
  fontDraw(frame, text26(), 36, 41, SOFT, "现在");
  String counts;
  if (s.agentsWaiting > 0) counts += String(s.agentsWaiting) + " 等你";
  if (s.agentsWorking > 0) counts += (counts.length() ? " · " : "") + String(s.agentsWorking) + " 在干活";
  fontDrawRight(frame, name26(), 444, 41, SOFT, counts.c_str());

  if (s.rowCount == 0) {
    fontDrawCentred(frame, name30(), CX, 240, SOFT, s.extended ? "没有在跑的" : fontFit(name30(), s.msg, 440, false).c_str());
    for (int i = 0; !s.extended && i < min(s.entryCount, 3); i++) {
      fontDrawCentred(frame, name26(), CX, 290 + i * 36, DIM, fontFit(name26(), s.entries[i], 440, false).c_str());
    }
    return;
  }
  for (int i = 0; i < min(s.rowCount, 4); i++) {
    const Row& r = s.rows[i];
    int top = 58 + i * 92;
    bool waiting = !strcmp(r.state, "waiting");
    // A bar is for what is still going. What finished or failed says so in words, whatever percentage it reached.
    bool bar = r.percent >= 0 && (waiting || !strcmp(r.state, "working"));
    uint16_t color = bar ? MINT : stateColor(r.state);
    shapeRoundRect(frame, 18, top, 444, 86, 26, waiting ? AMBER_UNDER : CARD);
    shapeRoundRectLine(frame, 18, top, 444, 86, 26, 1.0f, waiting ? AMBER_LINE : HAIR);
    shapeDisc(frame, 44, top + 30, 6, color);

    int rightWidth;
    if (bar) {
      String number = String(r.percent);
      TextStyle digits = {rounded(2), 0}, sign = {rounded(0), 0};
      int signWidth = fontWidth(sign, "%"), numberWidth = fontWidth(digits, number.c_str());
      fontDraw(frame, sign, 442 - signWidth, top + 55, SOFT, "%");
      fontDraw(frame, digits, 442 - signWidth - 3 - numberWidth, top + 55, MINT, number.c_str());
      rightWidth = signWidth + 3 + numberWidth;
      int barRight = 442 - rightWidth - 18;
      shapeRoundRect(frame, 62, top + 56, barRight - 62, 10, 5, EMPTY);
      shapeRoundRect(frame, 62, top + 56, max(10, (barRight - 62) * min(100, r.percent) / 100), 10, 5, MINT);
    } else {
      String right = String(stateWord(r.state)) + (r.age >= 0 ? " · " + span(r.age) : "");
      rightWidth = fontWidth(name26(), right.c_str());
      fontDraw(frame, name26(), 442 - rightWidth, top + 52, color, right.c_str());
      fontDraw(frame, name26(), 62, top + 70, SOFT, fontFit(name26(), r.tool, 442 - rightWidth - 16 - 62, false).c_str());
    }
    fontDraw(frame, name30(), 62, top + 37, WHITE, fontFit(name30(), r.name, 442 - rightWidth - 16 - 62, true).c_str());
  }
  int more = max(0, s.rowCount - 4);
  String foot;
  if (more > 0) foot = String("还有 ") + more + " 个";
  if (s.agentsIdle > 0) foot += (foot.length() ? " · " : "") + String("另有 ") + s.agentsIdle + " 个空闲";
  if (foot.length()) fontDrawCentred(frame, name26(), CX, 458, DIM, foot.c_str());
}

// MARK: a request

static const int ASK_WIDTH = 396, ASK_LINES = 3;

// Breaks text into lines no wider than `maxWidth`, between any two characters. A closing mark stays with the
// line it closes. With `words`, a word written in Latin letters is not cut in two (unless it is longer than a
// line): right for sentences, wrong for a path, where the break may fall anywhere. Returns how many lines the
// text needs; only the first `maxLines` are kept.
static int breakLines(TextStyle style, const char* text, int maxWidth, String* lines, int maxLines, bool words = false) {
  int count = 0;
  String current;
  const char* p = text;
  while (*p) {
    uint8_t c = (uint8_t)*p;
    int n = c >= 0xF0 ? 4 : (c >= 0xE0 ? 3 : (c >= 0xC0 ? 2 : 1));
    String next = current;
    int taken = 0;
    for (; taken < n && p[taken]; taken++) next += p[taken];
    bool closing = n == 3 && (!strncmp(p, "”", 3) || !strncmp(p, "’", 3) || !strncmp(p, "，", 3) || !strncmp(p, "。", 3)
                              || !strncmp(p, "、", 3) || !strncmp(p, "）", 3) || !strncmp(p, "》", 3) || !strncmp(p, "」", 3)
                              || !strncmp(p, "？", 3) || !strncmp(p, "！", 3) || !strncmp(p, "：", 3) || !strncmp(p, "；", 3));
    // A closing mark stays with its line, by one mark's width and no more: a run of them would otherwise carry
    // a line as far off both edges as it liked, while it still counted as one line that fits.
    int width = fontWidth(style, next.c_str());
    if (current.length() > 0 && (closing ? width > maxWidth + 30 : width > maxWidth)) {
      // In the middle of a word: the part of it already on this line goes down to the next one with the rest.
      String carried;
      int space = current.lastIndexOf(' ');
      if (words && n == 1 && c != ' ' && space > 0 && current[current.length() - 1] != ' ') {
        carried = current.substring(space + 1);
        current = current.substring(0, space);
      }
      current.trim();
      if (count < maxLines) lines[count] = current;
      count++;
      current = carried;
      while (*p == ' ' && !carried.length()) p++;
      continue;
    }
    current = next;
    p += taken;
  }
  current.trim();
  if (current.length() > 0) {
    if (count < maxLines) lines[count] = current;
    count++;
  }
  return count;
}

// The request on screen, broken into lines once and kept until another request arrives.
static String s_askLines[ASK_LINES];
static int s_askCount = 0;
static bool s_askToolFits = false;
static char s_askFor[40] = "\x01";
static uint32_t s_askForAt = 0;
static void prepareAsk() {
  const State& s = g_state;
  // Kept for one arrival of one request: the same id coming again later is laid out afresh.
  if (!strcmp(s_askFor, s.promptId) && s_askForAt == s.promptAt) return;
  strlcpy(s_askFor, s.promptId, sizeof(s_askFor));
  s_askForAt = s.promptAt;
  s_askCount = breakLines(name30(), s.promptHint, ASK_WIDTH, s_askLines, ASK_LINES);
  s_askToolFits = fontWidth(name30(), s.promptTool) + 40 <= 432;
}

bool screenRequestFits() {
  prepareAsk();
  return g_state.promptWhole && s_askToolFits && s_askCount >= 1 && s_askCount <= ASK_LINES;
}

void screenRequest(uint16_t* frame, float holdAllow, float holdDeny, bool allowed) {
  const State& s = g_state;
  bool whole = screenRequestFits();
  bool holding = holdAllow >= 0 && !s.answered, denying = holdDeny >= 0 && !s.answered;
  float hold = holdAllow;
  bool wasAllowed = s.answered && allowed, wasDenied = s.answered && !allowed;

  // Who asks, and with what.
  const char* asks = " 要你批准";
  String who = s.promptBy[0] ? String(s.promptBy) + (s.promptAgent[0] ? String(" · ") + s.promptAgent : String("")) : String(s.promptAgent);
  if (who.length()) who = fontFit(name26(), who.c_str(), 440 - fontWidth(name26(), asks), true) + asks;
  else who = "要你批准";
  fontDrawCentred(frame, name26(), CX, 41, SOFT, who.c_str());
  // A tool's name too long for its plate is cut for the look of it; such a request cannot be allowed here anyway.
  String tool = fontFit(name30(), s.promptTool, 392, false);
  int toolWidth = fontWidth(name30(), tool.c_str()) + 40;
  shapeRoundRect(frame, CX - toolWidth / 2, 54, toolWidth, 44, 22, rgb(43, 32, 12));
  fontDrawCentred(frame, name30(), CX, 87, AMBER, tool.c_str());

  // What is asked, whole or not at all.
  shapeRoundRect(frame, 24, 108, 432, 140, 26, CARD);
  shapeRoundRectLine(frame, 24, 108, 432, 140, 26, holding || denying ? 2.0f : 1.0f, holding ? rgb(62, 185, 137) : (denying ? rgb(190, 84, 80) : HAIR));
  if (whole) {
    for (int i = 0; i < s_askCount; i++) fontDrawCentred(frame, name30(), CX, 189 - (s_askCount - 1) * 20 + i * 40, WHITE, s_askLines[i].c_str());
  } else {
    fontDrawCentred(frame, text30(), CX, 189, WHITE, "内容太长，这里显示不全");
  }

  // The line between: time left, or how far the hold has got, or what was answered. A finger on the button
  // hides the button, so the hold shows here as well.
  String note;
  uint16_t noteColor = SOFT, barColor = AMBER;
  float filled = 0;
  if (wasAllowed) {
    note = "已答复";
    noteColor = MINT;
    barColor = MINT;
    filled = 1;
  } else if (wasDenied) {
    note = "已答复";
    noteColor = CORAL;
  } else if (holding) {
    note = "按住，别松手";
    noteColor = MINT;
    barColor = MINT;
    filled = min(1.0f, hold);
  } else if (denying) {
    note = "按住，别松手";
    noteColor = CORAL;
    barColor = CORAL;
    filled = min(1.0f, holdDeny);
  } else if (s.promptLeft > 0) {
    int left = max(0, s.promptLeft - (int)((millis() - s.promptAt) / 1000));
    note = String("还有 ") + left + " 秒";
    filled = (float)left / s.promptLeft;
  }
  if (note.length()) {
    int noteWidth = fontWidth(name26(), note.c_str());
    int barWidth = 432 - noteWidth - 14;
    fontDraw(frame, name26(), 456 - noteWidth, 283, noteColor, note.c_str());
    shapeRoundRect(frame, 24, 269, barWidth, 10, 5, EMPTY);
    if (filled > 0) shapeRoundRect(frame, 24, 269, max(10, (int)(barWidth * filled)), 10, 5, barColor);
  }

  const int y = SCREEN_BUTTON_Y, w = SCREEN_BUTTON_W, h = SCREEN_BUTTON_H;
  TextStyle word = {BUTTON34, 0};

  // "Deny": held like "allow", and filling the same way, in its own colour.
  int denyMiddle = SCREEN_DENY_X + w / 2;
  if (wasDenied) {
    shapeRoundRect(frame, SCREEN_DENY_X, y, w, h, 36, CORAL);
    fontDrawCentred(frame, word, denyMiddle, y + 87, rgb(60, 12, 10), "已拒绝");
  } else {
    bool faded = holding || wasAllowed;
    shapeRoundRect(frame, SCREEN_DENY_X, y, w, h, 36, faded ? rgb(16, 8, 8) : rgb(40, 17, 16));
    if (denying) shapeRoundRect(frame, SCREEN_DENY_X, y, max(72, (int)(w * min(1.0f, holdDeny))), h, 36, rgb(196, 78, 74));
    shapeRoundRectLine(frame, SCREEN_DENY_X, y, w, h, 36, 2.5f, faded ? rgb(70, 32, 31) : rgb(214, 96, 92));
    if (denying) {
      fontDrawCentred(frame, word, denyMiddle, y + 69, WHITE, "拒绝");
      fontDrawCentred(frame, text26(), denyMiddle, y + 109, rgb(235, 235, 235), "继续按住");
    } else {
      fontDrawCentred(frame, word, denyMiddle, y + 69, faded ? rgb(92, 60, 58) : rgb(255, 150, 146), "拒绝");
      fontDrawCentred(frame, name26(), denyMiddle, y + 109, faded ? rgb(78, 52, 50) : rgb(219, 140, 136), "按住 1 秒");
    }
  }

  // "Allow": an empty slot that has to be filled, or, when the request cannot be shown whole, no button at all.
  bool allowFaded = denying || wasDenied;
  int allowMiddle = SCREEN_ALLOW_X + w / 2;
  if (!whole) {
    laptop(frame, allowMiddle - 22, y + 22, 1.45f, SOFT);
    fontDrawCentred(frame, text26(), allowMiddle, y + 92, SOFT, "要允许，");
    fontDrawCentred(frame, text26(), allowMiddle, y + 126, SOFT, "到电脑上看全");
    return;
  }
  if (wasAllowed) {
    shapeRoundRect(frame, SCREEN_ALLOW_X, y, w, h, 36, TEAL);
    int wordWidth = fontWidth(word, "已允许"), x = allowMiddle - (30 + 8 + wordWidth) / 2;
    tick(frame, x, y + 40, 1.5f, rgb(6, 40, 30));
    fontDraw(frame, word, x + 38, y + 69, rgb(6, 40, 30), "已允许");
    fontDrawCentred(frame, text26(), allowMiddle, y + 109, rgb(14, 62, 50), "只这一次");
    return;
  }
  shapeRoundRect(frame, SCREEN_ALLOW_X, y, w, h, 36, rgb(5, 8, 7));
  if (holding) shapeRoundRect(frame, SCREEN_ALLOW_X, y, max(72, (int)(w * min(1.0f, hold))), h, 36, rgb(40, 172, 142));
  shapeRoundRectLine(frame, SCREEN_ALLOW_X, y, w, h, 36, 2.5f, allowFaded ? rgb(20, 59, 44) : rgb(62, 185, 137));
  if (holding) {
    fontDrawCentred(frame, word, allowMiddle, y + 69, WHITE, "允许一次");
    fontDrawCentred(frame, text26(), allowMiddle, y + 109, rgb(235, 235, 235), "继续按住");
  } else {
    uint16_t color = allowFaded ? rgb(25, 76, 56) : MINT, softer = allowFaded ? rgb(22, 66, 49) : rgb(68, 204, 151);
    int wordWidth = fontWidth(word, "允许一次"), x = allowMiddle - (30 + 8 + wordWidth) / 2;
    // A ring of dots: something to be completed.
    for (int i = 0; i < 8; i++) {
      float angle = 6.2831853f * i / 8;
      shapeDisc(frame, x + 15 + 11.5f * sinf(angle), y + 57 - 11.5f * cosf(angle), 2.3f, color);
    }
    fontDraw(frame, word, x + 38, y + 69, color, "允许一次");
    fontDrawCentred(frame, name26(), allowMiddle, y + 109, softer, "按住 1 秒");
  }
}


// MARK: a question from another program

// Where everything on the question's screen goes, worked out once for each question. The drawing and the touch
// code both read it, so a button is where it looks to be.
static struct {
  char forId[12];
  bool fits;
  int lineCount;
  String lines[3];
  int top;                  // the first line's baseline
  int barTop;
  int count;
  int x[4], y[4], w[4], h[4];
  int face[4];              // 0, 1, 2: the answer is drawn at 26, 30 or 38 pixels
} s_question = {"\x01", false, 0, {}, 0, 0, 0, {}, {}, {}, {}, {}};
static uint32_t s_questionAt = 0;

static const int QUESTION_LEFT = 24, QUESTION_WIDTH = 432, QUESTION_BOTTOM = 468, QUESTION_PITCH = 40;
static const int CHOICE_MIN = 60, CHOICE_MAX = 104;

static TextStyle choiceStyle(int face) { return face == 2 ? name38() : (face == 1 ? name30() : name26()); }

// The largest face an answer fits in, inside a button `width` wide and `height` high; -1 if none.
static int choiceFace(const char* text, int width, int height) {
  for (int face = height >= 84 ? 2 : 1; face >= 0; face--) {
    if (fontWidth(choiceStyle(face), text) <= width - 36) return face;
  }
  return -1;
}

static void prepareQuestion() {
  const State& s = g_state;
  if (!strcmp(s_question.forId, s.askId) && s_questionAt == s.askAt) return;
  strlcpy(s_question.forId, s.askId, sizeof(s_question.forId));
  s_questionAt = s.askAt;
  auto& q = s_question;
  q.fits = false;
  q.count = 0;
  int n = s.askChoiceCount;
  if (!s.askWhole || n < 2 || n > 4) return;
  q.lineCount = breakLines(name30(), s.askText, QUESTION_WIDTH, q.lines, 3, true);
  if (q.lineCount < 1 || q.lineCount > 3) return;

  // Under the two lines that say who asks and how to answer: the question, the time left, then the answers.
  // One under another when each can be tall enough for a finger; four that cannot go two by two; and if that
  // does not work either, the question is for the computer.
  const int first = 124, afterText = 26, afterBar = 32, gap = 10;
  int buttonsTop = first + (q.lineCount - 1) * QUESTION_PITCH + afterText + afterBar;
  int room = QUESTION_BOTTOM - buttonsTop;
  int each = min(CHOICE_MAX, (room - (n - 1) * gap) / n);
  bool stacked = each >= CHOICE_MIN;
  for (int i = 0; stacked && i < n; i++) stacked = choiceFace(s.askChoices[i], QUESTION_WIDTH, each) >= 0;
  int used;
  if (stacked) {
    for (int i = 0; i < n; i++) {
      q.x[i] = QUESTION_LEFT;
      q.w[i] = QUESTION_WIDTH;
      q.h[i] = each;
      q.y[i] = buttonsTop + i * (each + gap);
      q.face[i] = choiceFace(s.askChoices[i], QUESTION_WIDTH, each);
    }
    used = n * each + (n - 1) * gap;
  } else {
    if (n != 4) return;
    int width = (QUESTION_WIDTH - gap) / 2, height = min(CHOICE_MAX, (room - gap) / 2);
    if (height < CHOICE_MIN) return;
    for (int i = 0; i < 4; i++) {
      q.face[i] = choiceFace(s.askChoices[i], width, height);
      if (q.face[i] < 0) return;
      q.x[i] = QUESTION_LEFT + (i % 2) * (width + gap);
      q.y[i] = buttonsTop + (i / 2) * (height + gap);
      q.w[i] = width;
      q.h[i] = height;
    }
    used = 2 * height + gap;
  }
  // What is left over is shared above and below, so a short question does not hang at the top.
  int shift = max(0, (room - used) / 2);
  q.top = first + shift;
  q.barTop = q.top + (q.lineCount - 1) * QUESTION_PITCH + afterText;
  for (int i = 0; i < n; i++) q.y[i] += shift;
  q.count = n;
  q.fits = true;
}

bool screenAskFits() {
  prepareQuestion();
  return s_question.fits;
}

int screenAskHit(int x, int y, int slack) {
  prepareQuestion();
  const auto& q = s_question;
  if (!q.fits) return -1;
  for (int i = 0; i < q.count; i++) {
    if (x >= q.x[i] - slack && x < q.x[i] + q.w[i] + slack && y >= q.y[i] - slack && y < q.y[i] + q.h[i] + slack) return i;
  }
  return -1;
}

void screenAsk(uint16_t* frame, int pressed, float hold) {
  const State& s = g_state;
  prepareQuestion();
  const auto& q = s_question;

  // Who asks.
  const char* asks = " 问你";
  String who = s.askFrom[0] ? fontFit(name26(), s.askFrom, 440 - fontWidth(name26(), asks), true) + asks : String("有个程序问你");
  int whoWidth = fontWidth(name26(), who.c_str());
  shapeDisc(frame, CX - whoWidth / 2 - 16, 32, 5, LILAC);
  fontDraw(frame, name26(), CX - whoWidth / 2, 41, SOFT, who.c_str());

  if (!q.fits) {
    // Not shown in part: a question read half is a question answered wrong.
    laptop(frame, CX - 36, 138, 2.4f, LILAC);
    fontDrawCentred(frame, text38(), CX, 262, WHITE, "到电脑上回答");
    fontDrawCentred(frame, text26(), CX, 312, SOFT, "这个问题在这里显示不全");
    fontDrawCentred(frame, text26(), CX, 420, DIM, "按一下键，先放到一边");
    return;
  }
  // How to answer, always said: a touch that does nothing would otherwise look like a fault.
  fontDrawCentred(frame, name26(), CX, 77, DIM, "按住一个选项 1 秒来回答");

  for (int i = 0; i < q.lineCount; i++) fontDrawCentred(frame, name30(), CX, q.top + i * QUESTION_PITCH, WHITE, q.lines[i].c_str());

  // Time left, or how far the hold has got, or that it has been answered. A finger on a button hides the
  // button, so the hold shows here as well.
  bool picked = s.askPicked >= 0;
  bool holding = !picked && pressed >= 0 && pressed < q.count;
  String note;
  float filled = 0;
  if (picked) {
    note = "已回答";
    filled = 1;
  } else if (holding) {
    note = "按住，别松手";
    filled = min(1.0f, max(0.0f, hold));
  } else if (s.askLeft > 0) {
    int left = max(0, s.askLeft - (int)((millis() - s.askAt) / 1000));
    note = String("还有 ") + (left >= 90 ? span(left) : String(left) + " 秒");
    filled = (float)left / s.askLeft;
  }
  if (note.length()) {
    int noteWidth = fontWidth(name26(), note.c_str());
    int barWidth = QUESTION_WIDTH - noteWidth - 14;
    fontDraw(frame, name26(), QUESTION_LEFT + QUESTION_WIDTH - noteWidth, q.barTop + 14, picked || holding ? LILAC : SOFT, note.c_str());
    shapeRoundRect(frame, QUESTION_LEFT, q.barTop, barWidth, 10, 5, EMPTY);
    if (filled > 0) shapeRoundRect(frame, QUESTION_LEFT, q.barTop, max(10, (int)(barWidth * filled)), 10, 5, LILAC);
  }

  // The answers. Each has to be held for a second, and fills while it is; the one picked stays filled, the rest
  // step back.
  for (int i = 0; i < q.count; i++) {
    int radius = min(28, q.h[i] / 2);
    TextStyle style = choiceStyle(q.face[i]);
    int baseline = q.y[i] + q.h[i] / 2 + (q.face[i] == 2 ? 14 : (q.face[i] == 1 ? 11 : 9));
    int middle = q.x[i] + q.w[i] / 2;
    if (picked && i == s.askPicked) {
      shapeRoundRect(frame, q.x[i], q.y[i], q.w[i], q.h[i], radius, LILAC);
      int textWidth = fontWidth(style, s.askChoices[i]);
      int x = middle - (26 + 8 + textWidth) / 2;
      tick(frame, x, q.y[i] + q.h[i] / 2 - 13, 1.3f, rgb(28, 20, 66));
      fontDraw(frame, style, x + 34, baseline, rgb(28, 20, 66), s.askChoices[i]);
    } else if (picked) {
      shapeRoundRect(frame, q.x[i], q.y[i], q.w[i], q.h[i], radius, rgb(14, 13, 21));
      fontDrawCentred(frame, style, middle, baseline, rgb(92, 88, 110), s.askChoices[i]);
    } else if (holding && i != pressed) {
      shapeRoundRect(frame, q.x[i], q.y[i], q.w[i], q.h[i], radius, rgb(18, 16, 28));
      shapeRoundRectLine(frame, q.x[i], q.y[i], q.w[i], q.h[i], radius, 1.5f, rgb(52, 47, 80));
      fontDrawCentred(frame, style, middle, baseline, rgb(122, 116, 150), s.askChoices[i]);
    } else {
      bool down = i == pressed;
      shapeRoundRect(frame, q.x[i], q.y[i], q.w[i], q.h[i], radius, LILAC_UNDER);
      if (down) shapeRoundRect(frame, q.x[i], q.y[i], max(2 * radius, (int)(q.w[i] * min(1.0f, max(0.0f, hold)))), q.h[i], radius, rgb(108, 94, 178));
      shapeRoundRectLine(frame, q.x[i], q.y[i], q.w[i], q.h[i], radius, down ? 2.5f : 1.5f, down ? LILAC : LILAC_LINE);
      fontDrawCentred(frame, style, middle, baseline, down ? WHITE : LILAC_TEXT, s.askChoices[i]);
    }
  }
}

// MARK: a notice from another program

// The last line there is room for, when more text follows it: it ends in an ellipsis.
static String withMore(TextStyle style, String line, int maxWidth) {
  while (line.length() > 0 && fontWidth(style, (line + "…").c_str()) > maxWidth) {
    int end = line.length() - 1;
    while (end > 0 && ((uint8_t)line[end] & 0xC0) == 0x80) end--;   // a whole character at a time
    line.remove(end);
  }
  return line + "…";
}

void screenNote(uint16_t* frame) {
  const State& s = g_state;
  bool done = !strcmp(s.noteLevel, "done"), failed = !strcmp(s.noteLevel, "error");
  uint16_t color = failed ? CORAL : (done ? MINT : AQUA);

  // How it went, as a small mark at the top.
  const int markY = 74;
  shapeRing(frame, CX, markY, 44, 7, 1.0f, color, done ? AQUA : color, TRACK);
  if (failed) {
    shapeLine(frame, CX - 13, markY - 13, CX + 13, markY + 13, 7.5f, color);
    shapeLine(frame, CX + 13, markY - 13, CX - 13, markY + 13, 7.5f, color);
  } else if (done) {
    shapeLine(frame, CX - 17, markY + 1, CX - 5, markY + 13, 7.5f, TEAL);
    shapeLine(frame, CX - 5, markY + 13, CX + 18, markY - 12, 7.5f, TEAL);
  } else {
    // A speech mark: three dots.
    for (int i = -1; i <= 1; i++) shapeDisc(frame, CX + i * 15, markY, 4.5f, color);
  }

  // The title, then what it says, together in the middle of the room between the mark and the sender. A notice
  // is only read, so what does not fit ends in an ellipsis: all of it is on the computer.
  const int roomTop = 136, roomBottom = s.noteFrom[0] ? 398 : 452;
  String title[2], body[5];
  int titleCount = 0, bodyCount = 0;
  bool leading = !s.noteTitle[0];   // with no title, the words themselves are the main thing
  TextStyle bodyStyle = leading ? name30() : name26();
  const int titlePitch = 42, bodyPitch = leading ? 42 : 36, between = 8;
  if (s.noteTitle[0]) {
    int needed = breakLines(name30(), s.noteTitle, 432, title, 2, true);
    titleCount = min(needed, 2);
    if (needed > 2) title[1] = withMore(name30(), title[1], 432);
  }
  if (s.noteBody[0]) {
    int room = max(1, min(5, (roomBottom - roomTop - titleCount * titlePitch - (titleCount ? between : 0)) / bodyPitch));
    int needed = breakLines(bodyStyle, s.noteBody, 432, body, room, true);
    bodyCount = min(needed, room);
    if (needed > room) body[room - 1] = withMore(bodyStyle, body[room - 1], 432);
  }
  int height = titleCount * titlePitch + bodyCount * bodyPitch + (titleCount && bodyCount ? between : 0);
  int y = roomTop + max(0, (roomBottom - roomTop - height) / 2) + 30;   // the first baseline
  for (int i = 0; i < titleCount; i++, y += titlePitch) fontDrawCentred(frame, name30(), CX, y, WHITE, title[i].c_str());
  if (titleCount && bodyCount) y += between - (titlePitch - bodyPitch);
  for (int i = 0; i < bodyCount; i++, y += bodyPitch) fontDrawCentred(frame, bodyStyle, CX, y, leading ? WHITE : BRIGHT, body[i].c_str());
  if (s.noteFrom[0]) {
    Label from = {fontFit(name26(), s.noteFrom, 380, false), SOFT, GREY_UNDER, 1, color};
    labels(frame, &from, 1);
  }
}


// MARK: measuring the touch

void screenCalibrate(uint16_t* frame, int x, int y, int index, int total, bool taken) {
  uint16_t color = taken ? MINT : WHITE;
  shapeRing(frame, x, y, 30, 3, 1.0f, color, color, TRACK);
  shapeLine(frame, x - 44, y, x - 9, y, 3, color);
  shapeLine(frame, x + 9, y, x + 44, y, 3, color);
  shapeLine(frame, x, y - 44, x, y - 9, 3, color);
  shapeLine(frame, x, y + 9, x, y + 44, 3, color);
  shapeDisc(frame, x, y, 3.5f, color);
  // The words go where the target is not.
  int words = y > 300 ? 150 : 372;
  fontDrawCentred(frame, text30(), CX, words, WHITE, taken ? "好了，松手" : "按住十字的中心");
  fontDrawCentred(frame, name26(), CX, words + 42, SOFT, (String("像平时那样按 · ") + (index + 1) + "/" + total).c_str());
  fontDrawCentred(frame, text26(), CX, words + 80, DIM, "按任意键取消");
}

void screenCalibrateResult(uint16_t* frame, bool kept, int before, int after) {
  if (kept) {
    ring(frame, RING_WHOLE, 100, MINT, AQUA, TRACK);
    shapeLine(frame, CX - 52.5f, CY + 4, CX - 15.5f, CY + 41, 23, TEAL);
    shapeLine(frame, CX - 15.5f, CY + 41, CX + 54.5f, CY - 37, 23, TEAL);
    fontDrawCentred(frame, text38(), CX, TITLE_Y, WHITE, "触摸校正好了");
    fontDrawCentred(frame, name26(), CX, LINE_Y, SOFT, (String("偏差 ") + before + " → " + after + " 像素").c_str());
  } else {
    ring(frame, RING_WHOLE, 100, AMBER, AMBER, TRACK);
    shapeLine(frame, CX, CY - 46, CX, CY + 14, 23, AMBER);
    shapeDisc(frame, CX, CY + 46, 12.5f, AMBER);
    fontDrawCentred(frame, text38(), CX, TITLE_Y, WHITE, "这次没有校成");
    fontDrawCentred(frame, name26(), CX, LINE_Y, SOFT, "读数不稳，保持原来的");
  }
}
