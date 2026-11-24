// The Hardware Buddy protocol from the device's side (github.com/anthropics/claude-desktop-buddy, REFERENCE.md),
// plus the fields RenderDock adds under "rd" when this device has said it understands them.
#include "state.h"
#include "link.h"
#include "hw.h"
#include "screens.h"
#include <ArduinoJson.h>

State g_state = {};
#if RD_DEBUG_SERIAL
bool g_protoFromConsole = false;
#endif

static bool s_clockSet = false;
static uint32_t s_clockEpoch = 0;
static int32_t s_clockOffset = 0;
static uint32_t s_clockAt = 0;

// Copies text into a buffer. If it does not all fit, it is cut between two characters, not inside one, and the
// answer is false: for what must be seen whole, the caller needs to know.
static bool copy(char* to, size_t size, const char* from) {
  if (!from) from = "";
  size_t length = strlen(from);
  if (length < size) {
    memcpy(to, from, length + 1);
    return true;
  }
  size_t keep = size - 1;
  while (keep > 0 && ((uint8_t)from[keep] & 0xC0) == 0x80) keep--;   // not in the middle of a character
  memcpy(to, from, keep);
  to[keep] = 0;
  return false;
}

static Overall overallOf(const char* word) {
  if (!word) return OV_IDLE;
  if (!strcmp(word, "error")) return OV_ERROR;
  if (!strcmp(word, "waiting")) return OV_WAITING;
  if (!strcmp(word, "working")) return OV_WORKING;
  if (!strcmp(word, "done")) return OV_DONE;
  return OV_IDLE;
}

// Takes a piece of text from the computer. True only if it is text, all of it was kept, and all of it can be
// seen: a NUL inside it would end it early here without a trace, and a control character has no shape on the
// screen. What must be shown whole is not whole otherwise. With `needed`, an empty or missing one is not whole.
static bool takeText(JsonVariantConst value, char* to, size_t size, bool needed = false) {
  if (!value.is<const char*>()) {
    to[0] = 0;
    return value.isNull() && !needed;
  }
  JsonString text = value.as<JsonString>();
  const char* from = text.c_str();
  bool whole = copy(to, size, from);
  if (from && strlen(from) != text.size()) whole = false;
  for (const char* c = to; *c; c++) {
    if ((uint8_t)*c < 0x20 || *c == 0x7F) whole = false;
  }
  if (needed && !to[0]) whole = false;
  return whole;
}

void protoReset() {
  g_state = {};
  g_state.topPercent = -1;
  g_state.topEta = -1;
  g_state.promptLeft = -1;
  g_state.askLeft = -1;
  g_state.askPicked = -1;
}

static void ack(const char* command, bool ok) {
  JsonDocument doc;
  doc["ack"] = command;
  doc["ok"] = ok;
  doc["n"] = 0;
  String out;
  serializeJson(doc, out);
  linkSendLine(out);
}

static void sendStatus() {
  JsonDocument doc;
  doc["ack"] = "status";
  doc["ok"] = true;
  JsonObject data = doc["data"].to<JsonObject>();
  data["name"] = linkName();
  data["sec"] = linkSecure();
  Battery battery = hwBattery();
  if (battery.percent >= 0) {
    JsonObject bat = data["bat"].to<JsonObject>();
    bat["pct"] = battery.percent;
    bat["mV"] = battery.millivolts;
    bat["usb"] = battery.usb;
  }
  JsonObject sys = data["sys"].to<JsonObject>();
  sys["up"] = millis() / 1000;
  sys["heap"] = ESP.getFreeHeap();
  // Not part of the published protocol: tells RenderDock it may send its "rd" fields and text beyond ASCII.
  // 2 says this device also shows questions, notices and tasks from other programs, which only the screens
  // drawn with the fonts in flash do.
  data["rd"] = screensReady() ? 2 : 1;
  // The first screens (a board without the font file) draw from a small bitmap font that has only some
  // characters, and leave out the rest without a trace. Such a board says it cannot draw beyond ASCII.
  data["utf8"] = screensReady();
  String out;
  serializeJson(doc, out);
  linkSendLine(out);
}

static void readSnapshot(JsonDocument& doc) {
  State& s = g_state;
  s.have = true;
  s.at = millis();
  s.total = doc["total"] | 0;
  s.running = doc["running"] | 0;
  s.waiting = doc["waiting"] | 0;
  copy(s.msg, sizeof(s.msg), doc["msg"] | "");

  s.entryCount = 0;
  JsonArray entries = doc["entries"];
  for (JsonVariant entry : entries) {
    if (s.entryCount >= 4) break;
    copy(s.entries[s.entryCount++], sizeof(s.entries[0]), entry | "");
  }

  JsonObject prompt = doc["prompt"];
  const char* id = prompt["id"] | "";
  if (prompt.isNull() || !*id) {
    s.prompt = false;
    s.answered = false;
    s.promptId[0] = 0;
  } else if (strcmp(id, s.promptId) != 0) {
    // A request this device has not seen yet.
    s.prompt = true;
    s.answered = false;
    s.promptAt = millis();
#if RD_DEBUG_SERIAL
    s.promptLocal = g_protoFromConsole;
#else
    s.promptLocal = false;
#endif
    bool whole = takeText(prompt["id"], s.promptId, sizeof(s.promptId), true);
    whole = takeText(prompt["tool"], s.promptTool, sizeof(s.promptTool), true) && whole;
    s.promptWhole = takeText(prompt["hint"], s.promptHint, sizeof(s.promptHint), true) && whole;
    s.promptLeft = doc["rd"]["left"] | -1;
    // Whose request this is, if the computer says. Not "the most urgent thing going on", which may be another
    // session altogether.
    JsonObjectConst by = doc["rd"]["by"];
    takeText(by["n"], s.promptBy, sizeof(s.promptBy));
    takeText(by["t"], s.promptAgent, sizeof(s.promptAgent));
  }

  JsonObject rd = doc["rd"];
  s.extended = !rd.isNull();
  s.rowCount = 0;
  s.topPercent = -1;
  s.topEta = -1;
  s.topKind[0] = s.topName[0] = s.topTool[0] = s.topWait[0] = s.jobTitle[0] = 0;
  s.jobDone = s.jobTotal = 0;
  if (!s.extended) {
    s.overall = s.waiting > 0 ? OV_WAITING : (s.running > 0 ? OV_WORKING : OV_IDLE);
    s.agentsError = s.agentsDone = s.agentsIdle = 0;
    s.agentsWaiting = s.waiting;
    s.agentsWorking = s.running;
    s.ask = s.note = false;
    s.askId[0] = s.noteId[0] = 0;
    return;
  }
  s.overall = overallOf(rd["state"] | "idle");
  JsonObject top = rd["top"];
  if (!top.isNull()) {
    copy(s.topKind, sizeof(s.topKind), top["kind"] | "");
    copy(s.topName, sizeof(s.topName), top["name"] | "");
    copy(s.topTool, sizeof(s.topTool), top["tool"] | "");
    copy(s.topWait, sizeof(s.topWait), top["wait"] | "");
    s.topPercent = top["pct"] | -1;
    s.topExact = top["exact"] | true;
    s.topEta = top["eta"] | -1;
  }
  JsonObject job = rd["job"];
  if (!job.isNull()) {
    copy(s.jobTitle, sizeof(s.jobTitle), job["title"] | "");
    s.jobDone = job["done"] | 0;
    s.jobTotal = job["total"] | 0;
  }
  JsonObject agents = rd["agents"];
  s.agentsError = agents["error"] | 0;
  s.agentsWaiting = agents["waiting"] | 0;
  s.agentsWorking = agents["working"] | 0;
  s.agentsDone = agents["done"] | 0;
  s.agentsIdle = agents["idle"] | 0;
  JsonArray rows = rd["rows"];
  for (JsonObject row : rows) {
    if (s.rowCount >= 6) break;
    Row& r = s.rows[s.rowCount++];
    copy(r.name, sizeof(r.name), row["n"] | "");
    copy(r.tool, sizeof(r.tool), row["t"] | "");
    copy(r.state, sizeof(r.state), row["s"] | "");
    r.age = row["a"] | -1;
    r.percent = row["p"] | -1;
  }

  JsonObject ask = rd["ask"];
  const char* askId = ask["id"] | "";
  if (ask.isNull() || !*askId) {
    s.ask = false;
    s.askId[0] = 0;
    s.askPicked = -1;
  } else if (strcmp(askId, s.askId) != 0) {
    // A question this device has not seen yet.
    s.ask = true;
    s.askPicked = -1;
    s.askAt = millis();
#if RD_DEBUG_SERIAL
    s.askLocal = g_protoFromConsole;
#else
    s.askLocal = false;
#endif
    bool whole = takeText(ask["id"], s.askId, sizeof(s.askId), true);
    whole = takeText(ask["from"], s.askFrom, sizeof(s.askFrom)) && whole;
    whole = takeText(ask["text"], s.askText, sizeof(s.askText), true) && whole;
    s.askChoiceCount = 0;
    JsonArray choices = ask["choices"];
    for (JsonVariant choice : choices) {
      if (s.askChoiceCount >= 4) {
        whole = false;   // more answers than there is room for
        break;
      }
      // An answer that is empty, or is not text, would be a blank button that can still be picked.
      whole = takeText(choice, s.askChoices[s.askChoiceCount++], sizeof(s.askChoices[0]), true) && whole;
    }
    s.askWhole = whole && s.askChoiceCount >= 2;
    s.askLeft = ask["left"] | -1;
  }

  JsonObject note = rd["note"];
  const char* noteId = note["id"] | "";
  if (note.isNull() || !*noteId) {
    s.note = false;   // its id is kept: the same notice coming round again is not new
  } else if (strcmp(noteId, s.noteId) != 0) {
    s.note = true;
    s.noteAt = millis();
    copy(s.noteId, sizeof(s.noteId), noteId);
    copy(s.noteFrom, sizeof(s.noteFrom), note["from"] | "");
    copy(s.noteTitle, sizeof(s.noteTitle), note["title"] | "");
    copy(s.noteBody, sizeof(s.noteBody), note["body"] | "");
    copy(s.noteLevel, sizeof(s.noteLevel), note["level"] | "info");
  }
}

void protoHandle(const String& line) {
  JsonDocument doc;
  if (deserializeJson(doc, line)) return;   // not JSON: not for us

  if (doc["time"].is<JsonArray>()) {
    s_clockEpoch = doc["time"][0] | 0;
    s_clockOffset = doc["time"][1] | 0;
    s_clockAt = millis();
    s_clockSet = s_clockEpoch > 0;
    return;
  }
  const char* command = doc["cmd"] | "";
  if (*command) {
    if (!strcmp(command, "status")) sendStatus();
    else if (!strcmp(command, "name") || !strcmp(command, "owner")) ack(command, true);   // accepted, not used
    else if (!strcmp(command, "unpair")) {
      ack(command, true);
      linkForgetAll();
    }
    // Anything else (the folder push, for one) is not answered: the sender gives up after a moment.
    return;
  }
  if (!doc["evt"].isNull()) return;   // turn events are not shown
  if (!doc["total"].isNull()) readSnapshot(doc);
}

void protoAnswer(bool allow) {
  State& s = g_state;
  if (!s.prompt || s.answered || !s.promptId[0]) return;
  s.answered = true;
#if RD_DEBUG_SERIAL
  Serial.printf("answer %s for %s%s\n", allow ? "once" : "deny", s.promptId, s.promptLocal ? " (made up on the console: not sent)" : "");
#endif
  // A request that was fed in over USB for testing is nobody's request. Its answer must not reach a computer
  // that happens to be paired and connected.
  if (s.promptLocal) return;
  JsonDocument doc;
  doc["cmd"] = "permission";
  doc["id"] = s.promptId;
  doc["decision"] = allow ? "once" : "deny";
  String out;
  serializeJson(doc, out);
  linkSendLine(out);
}

void protoChoose(int index) {
  State& s = g_state;
  if (!s.ask || s.askPicked >= 0 || !s.askId[0] || index < 0 || index >= s.askChoiceCount) return;
  s.askPicked = index;
#if RD_DEBUG_SERIAL
  Serial.printf("pick %d for %s%s\n", index, s.askId, s.askLocal ? " (made up on the console: not sent)" : "");
#endif
  // The same rule as for a request: what was fed in over USB is nobody's question.
  if (s.askLocal) return;
  JsonDocument doc;
  doc["cmd"] = "choice";
  doc["id"] = s.askId;
  doc["index"] = index;
  String out;
  serializeJson(doc, out);
  linkSendLine(out);
}

bool protoDate(int& month, int& day, int& weekday) {
  if (!s_clockSet) return false;
  uint32_t now = s_clockEpoch + (millis() - s_clockAt) / 1000 + s_clockOffset;
  uint32_t days = now / 86400;
  weekday = (int)((days + 4) % 7);   // the first day of 1970 was a Thursday
  // Days since 1970 to a month and a day (the usual civil-calendar arithmetic).
  uint32_t z = days + 719468;
  uint32_t era = z / 146097, dayOfEra = z - era * 146097;
  uint32_t yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365;
  uint32_t dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
  uint32_t shifted = (5 * dayOfYear + 2) / 153;
  day = (int)(dayOfYear - (153 * shifted + 2) / 5 + 1);
  month = (int)(shifted < 10 ? shifted + 3 : shifted - 9);
  return true;
}

bool protoClock(int& hour, int& minute) {
  if (!s_clockSet) return false;
  uint32_t now = s_clockEpoch + (millis() - s_clockAt) / 1000 + s_clockOffset;
  hour = (now % 86400) / 3600;
  minute = (now % 3600) / 60;
  return true;
}
