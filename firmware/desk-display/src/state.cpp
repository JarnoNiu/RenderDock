// The Hardware Buddy protocol from the device's side (github.com/anthropics/claude-desktop-buddy, REFERENCE.md),
// plus the fields RenderDock adds under "rd" when this device has said it understands them.
#include "state.h"
#include "link.h"
#include "hw.h"
#include "screens.h"
#include "net.h"
#include <ArduinoJson.h>

State g_state = {};
Mac g_mac = {};
#if RD_DEBUG_SERIAL
bool g_protoFromConsole = false;
#endif

// Set while a line that came over Wi-Fi is being read.
static bool s_fromNetwork = false;
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

static void emptySide(Side& side) {
  side.overall = OV_IDLE;
  side.topKind[0] = side.topName[0] = side.topTool[0] = side.topWait[0] = 0;
  side.topPercent = side.topEta = side.topAge = -1;
  side.topExact = true;
  side.rowCount = 0;
}

void protoReset() {
  g_state = {};
  g_mac = {};
  emptySide(g_state.r);
  emptySide(g_state.a);
  g_state.queueEta = -1;
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
  // drawn with the fonts in flash do. 3 says it also keeps renders and agents on pages of their own and has a
  // page for the computer itself, so both sides and the "mac" lines are worth sending.
  data["rd"] = screensReady() ? 3 : 1;
  // The first screens (a board without the font file) draw from a small bitmap font that has only some
  // characters, and leave out the rest without a trace. Such a board says it cannot draw beyond ASCII.
  data["utf8"] = screensReady();
  // Whether Wi-Fi has been set up here and how it is doing (the numbers of NetState). Never what was set.
  data["wifi"] = (int)netState();
  // …and how its last use went, which is all that is left to ask once a computer is back on Bluetooth.
  if (netLast() != NET_UNSET) data["wifiWas"] = (int)netLast();
  String out;
  serializeJson(doc, out);
  linkSendLine(out);
}

static void readRows(JsonArrayConst from, Row* rows, int& count) {
  count = 0;
  for (JsonObjectConst row : from) {
    if (count >= 6) break;
    Row& r = rows[count++];
    copy(r.name, sizeof(r.name), row["n"] | "");
    copy(r.tool, sizeof(r.tool), row["t"] | "");
    copy(r.state, sizeof(r.state), row["s"] | "");
    r.age = row["a"] | -1;
    r.percent = row["p"] | -1;
  }
}

// One side as the computer describes it.
static void readSide(JsonObjectConst from, Side& side, const char* kind) {
  emptySide(side);
  side.overall = overallOf(from["state"] | "idle");
  JsonObjectConst top = from["top"];
  if (!top.isNull()) {
    copy(side.topKind, sizeof(side.topKind), top["kind"] | kind);
    copy(side.topName, sizeof(side.topName), top["name"] | "");
    copy(side.topTool, sizeof(side.topTool), top["tool"] | "");
    copy(side.topWait, sizeof(side.topWait), top["wait"] | "");
    side.topPercent = top["pct"] | -1;
    side.topExact = top["exact"] | true;
    side.topEta = top["eta"] | -1;
    side.topAge = top["age"] | -1;
  }
  readRows(from["rows"], side.rows, side.rowCount);
}

// Both sides worked out from the one list and the one "most urgent thing" an older RenderDock sends.
static void sidesFromOne(State& s) {
  emptySide(s.r);
  emptySide(s.a);
  s.rendering = s.queued = 0;
  s.queueEta = -1;
  for (int i = 0; i < s.rowCount; i++) {
    Side& side = s.rows[i].tool[0] ? s.a : s.r;   // a render names no tool
    if (side.rowCount < 6) side.rows[side.rowCount++] = s.rows[i];
    if (!s.rows[i].tool[0] && !strcmp(s.rows[i].state, "working")) s.rendering++;
  }
  bool topIsRender = !strcmp(s.topKind, "render");
  // The side the most urgent thing belongs to takes it, and the overall state with it.
  if (s.topKind[0]) {
    Side& mine = topIsRender ? s.r : s.a;
    mine.overall = s.overall;
    strlcpy(mine.topKind, s.topKind, sizeof(mine.topKind));
    strlcpy(mine.topName, s.topName, sizeof(mine.topName));
    strlcpy(mine.topTool, s.topTool, sizeof(mine.topTool));
    strlcpy(mine.topWait, s.topWait, sizeof(mine.topWait));
    mine.topPercent = s.topPercent;
    mine.topExact = s.topExact;
    mine.topEta = s.topEta;
    for (int i = 0; i < mine.rowCount; i++) {
      if (!strcmp(mine.rows[i].name, mine.topName)) mine.topAge = mine.rows[i].age;
    }
  }
  // The other side is worked out from what is left: the sessions from their counts, the renders from their rows.
  if (topIsRender || !s.topKind[0]) {
    s.a.overall = s.agentsError > 0 ? OV_ERROR : (s.agentsWaiting > 0 ? OV_WAITING : (s.agentsWorking > 0 ? OV_WORKING : (s.agentsDone > 0 ? OV_DONE : OV_IDLE)));
  }
  if (!topIsRender) {
    for (int i = 0; i < s.r.rowCount; i++) {
      if (!strcmp(s.r.rows[i].state, "waiting")) s.r.overall = OV_WAITING;
      else if (!strcmp(s.r.rows[i].state, "working") && s.r.overall == OV_IDLE) s.r.overall = OV_WORKING;
    }
  }
  // It was sent no "most urgent thing" of its own: the first of its rows in that state stands in.
  Side& other = topIsRender ? s.a : s.r;
  if (other.overall != OV_IDLE && !other.topName[0] && other.rowCount > 0) {
    const char* wanted = other.overall == OV_ERROR ? "error" : (other.overall == OV_WAITING ? "waiting" : (other.overall == OV_WORKING ? "working" : "done"));
    const Row* row = nullptr;
    for (int i = 0; i < other.rowCount && !row; i++) {
      if (!strcmp(other.rows[i].state, wanted)) row = &other.rows[i];
    }
    if (row) {
      strlcpy(other.topKind, row->tool[0] ? "agent" : "render", sizeof(other.topKind));
      strlcpy(other.topName, row->name, sizeof(other.topName));
      strlcpy(other.topTool, row->tool, sizeof(other.topTool));
      other.topPercent = row->percent;
      other.topAge = row->age;
    }
  }
}

// The computer about itself: {"mac":{"cpu":37,"cores":10,"gpu":92,"vram":8.2,"mem":[21.4,32],"mp":1,"swap":1.2,
// "t":71,"tmax":78,"th":0,"disk":212,"ac":true,"bat":82,"awake":true,"w":143,"fan":100}}. Whatever is missing is
// shown as unknown.
static void readMac(JsonObjectConst mac) {
  Mac& m = g_mac;
  m.have = true;
  m.at = millis();
  m.cpu = mac["cpu"] | -1;
  m.cores = mac["cores"] | 0;
  m.gpu = mac["gpu"] | -1;
  m.vram = mac["vram"] | -1.0f;
  m.memUsed = mac["mem"][0] | -1.0f;
  m.memTotal = mac["mem"][1] | -1.0f;
  m.memPressure = mac["mp"] | 1;
  m.swap = mac["swap"] | -1.0f;
  m.temp = mac["t"] | -1;
  m.tempMax = mac["tmax"] | -1;
  m.thermal = mac["th"] | 0;
  m.diskFree = mac["disk"] | -1;
  m.onAC = mac["ac"].is<bool>() ? (mac["ac"].as<bool>() ? 1 : 0) : -1;
  m.battery = mac["bat"] | -1;
  m.awake = mac["awake"] | false;
  m.watts = mac["w"] | -1;
  m.fan = mac["fan"] | -1;
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
  // Over Wi-Fi nothing can be answered, so nothing is taken as a request, whatever the line says.
  if (prompt.isNull() || !*id || s_fromNetwork) {
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
    // The plain protocol knows no renders: what it counts is all on the one side.
    sidesFromOne(s);
    s.a.overall = s.overall;
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
  readRows(rd["rows"], s.rows, s.rowCount);
  // Each side as the computer sees it, when it says; otherwise taken apart here.
  JsonObjectConst renders = rd["r"], sessions = rd["a"];
  if (!renders.isNull() && !sessions.isNull()) {
    readSide(renders, s.r, "render");
    readSide(sessions, s.a, "agent");
    s.rendering = renders["n"]["run"] | 0;
    s.queued = renders["n"]["queue"] | 0;
    s.queueEta = renders["qeta"] | -1;
    JsonObjectConst queue = renders["job"];
    if (!queue.isNull()) {
      copy(s.jobTitle, sizeof(s.jobTitle), queue["title"] | "");
      s.jobDone = queue["done"] | 0;
      s.jobTotal = queue["total"] | 0;
    }
  } else {
    sidesFromOne(s);
  }

  JsonObject ask = rd["ask"];
  const char* askId = ask["id"] | "";
  if (ask.isNull() || !*askId || s_fromNetwork) {
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

void protoHandle(const String& line, bool fromNetwork) {
  JsonDocument doc;
  if (deserializeJson(doc, line)) return;   // not JSON: not for us
  s_fromNetwork = fromNetwork;

  if (doc["time"].is<JsonArray>()) {
    // Over Wi-Fi the time is taken only by a board that has none yet. The clock decides the hours the board
    // keeps quiet, and that is not for whatever answers at the computer's address to set.
    if (fromNetwork && s_clockSet) return;
    s_clockEpoch = doc["time"][0] | 0;
    s_clockOffset = doc["time"][1] | 0;
    s_clockAt = millis();
    s_clockSet = s_clockEpoch > 0;
    return;
  }
  if (doc["mac"].is<JsonObject>()) {
    readMac(doc["mac"]);
    return;
  }
  const char* command = doc["cmd"] | "";
  if (*command) {
    // Commands are obeyed from the encrypted Bluetooth link alone. What comes over Wi-Fi can ask for nothing.
    if (fromNetwork) return;
    if (!strcmp(command, "wifi")) {
      // The network to join and where the computer is on it; or, with "off", forget both.
      // "scan": look for the networks in range. The answer is its own line, a few seconds later (see main.cpp).
      if (doc["scan"] | false) {
        netScanRequest();
        return;
      }
      bool ok = true;
      if (doc["off"] | false) netConfigure("", "", "", "", 0, "");
      // Without a network's name: only where the computer is now (its address, port or token changed).
      else if (doc["ssid"].isNull()) netPlace(doc["host"] | "", doc["ip"] | "", doc["port"] | 47600, doc["token"] | "");
      else ok = netConfigure(doc["ssid"] | "", doc["pass"] | "", doc["host"] | "", doc["ip"] | "", doc["port"] | 47600, doc["token"] | "");
      ack(command, ok);
      return;
    }
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
