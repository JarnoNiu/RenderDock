// Board bring-up for the Waveshare ESP32-S3-Touch-AMOLED-2.16.
//
// The order of operations and the panel quirks (one-shot frame pushes, the MADCTL value for the rotated
// mount, the touch controller's address and mirroring) follow the board support in
// github.com/vthinkxie/claude-desktop-buddy-esp32, an MIT-licensed port of Anthropic's reference firmware.
// See NOTICE.md.
#include "hw.h"
#include "board.h"
#include <Wire.h>
#include <XPowersLib.h>
#include <TouchDrvCST.hpp>
#include <Preferences.h>

static Arduino_DataBus* s_bus = nullptr;
static Arduino_CO5300* s_panel = nullptr;
static Arduino_Canvas* s_canvas = nullptr;
static XPowersPMU s_pmu;
static bool s_pmuOk = false;
static TouchDrvCST92xx s_touch;
static void loadTouchFix();
static bool s_touchOk = false;
static bool s_screenOn = true;
static uint8_t s_level = 160;

// MARK: keys

#if RD_DEBUG_SERIAL
static void keyNote(uint8_t what);
static KeyEvent s_injectedKey = KEY_NONE;
void hwDebugKey(KeyEvent event) { s_injectedKey = event; }
#endif

// A press can be shorter than one pass of the loop (a frame takes a tenth of a second), so the moment a key goes
// down is caught by an interrupt; everything after that is worked out at leisure.
struct Switch {
  uint8_t pin;
  volatile bool hit;
  volatile uint32_t hitAt;
  bool tracking, longFired;
  uint32_t pressedAt, releasedAt;
};
static Switch s_bootKey = {PIN_KEY_BOOT, false, 0, false, false, 0, 0};
static Switch s_userKey = {PIN_KEY_USER, false, 0, false, false, 0, 0};
static const uint32_t LONG_PRESS_MS = 1500, BOOT_LONG_PRESS_MS = 3000;

static void IRAM_ATTR bootKeyDown() {
  if (!s_bootKey.hit) {
    s_bootKey.hitAt = millis();
    s_bootKey.hit = true;
  }
}
static void IRAM_ATTR userKeyDown() {
  if (!s_userKey.hit) {
    s_userKey.hitAt = millis();
    s_userKey.hit = true;
  }
}

static void keysBegin() {
  attachInterrupt(digitalPinToInterrupt(PIN_KEY_BOOT), bootKeyDown, FALLING);
  attachInterrupt(digitalPinToInterrupt(PIN_KEY_USER), userKeyDown, FALLING);
}

static KeyEvent pollSwitch(Switch& key, KeyEvent brief, KeyEvent held, uint32_t longMs, uint32_t now) {
  bool down = digitalRead(key.pin) == LOW;
  if (!key.tracking) {
    bool hit = key.hit;
    key.hit = false;
    // A press, unless it follows a release so closely that it is the contact bouncing.
    if ((hit || down) && now - key.releasedAt > 60) {
      key.tracking = true;
      key.longFired = false;
      key.pressedAt = hit ? key.hitAt : now;
    } else {
      return KEY_NONE;
    }
  }
  if (down) {
    // Signed: a press noted by the interrupt a moment after `now` was read is not a press that has lasted for ever.
    if (held != KEY_NONE && !key.longFired && (int32_t)(now - key.pressedAt) >= (int32_t)longMs) {
      key.longFired = true;
      return held;
    }
    return KEY_NONE;
  }
  key.tracking = false;
  key.releasedAt = now;
  key.hit = false;
  return key.longFired ? KEY_NONE : brief;
}

KeyEvent hwKeyEvent() {
  uint32_t now = millis();
#if RD_DEBUG_SERIAL
  if (s_injectedKey != KEY_NONE) {
    KeyEvent event = s_injectedKey;
    s_injectedKey = KEY_NONE;
    return event;
  }
#endif
  // The power key: ask the chip a few times a second what it has seen.
  static uint32_t askedAt = 0;
  if (s_pmuOk && now - askedAt >= 60) {
    askedAt = now;
    s_pmu.getIrqStatus();
    bool down = s_pmu.isPekeyNegativeIrq(), up = s_pmu.isPekeyPositiveIrq(), brief = s_pmu.isPekeyShortPressIrq(), held = s_pmu.isPekeyLongPressIrq();
    if (down || up || brief || held) {
      s_pmu.clearIrqStatus();
#if RD_DEBUG_SERIAL
      if (down) keyNote(7);
      if (held) keyNote(10);
      if (brief) keyNote(9);
      if (up) keyNote(8);
#endif
      if (held) return KEY_POWER_LONG;
      if (brief) return KEY_POWER_SHORT;
    }
  }
  KeyEvent event = pollSwitch(s_userKey, KEY_USER_SHORT, KEY_USER_LONG, LONG_PRESS_MS, now);
  if (event != KEY_NONE) return event;
  return pollSwitch(s_bootKey, KEY_BOOT_SHORT, KEY_BOOT_LONG, BOOT_LONG_PRESS_MS, now);
}

bool hwBegin() {
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);
  Wire.setClock(400000);

  pinMode(PIN_KEY_PWR, INPUT);
  pinMode(PIN_KEY_USER, INPUT_PULLUP);
  pinMode(PIN_KEY_BOOT, INPUT_PULLUP);
  keysBegin();

  // Power chip first: it feeds the rest.
  s_pmuOk = s_pmu.begin(Wire, AXP2101_SLAVE_ADDRESS, PIN_I2C_SDA, PIN_I2C_SCL);
  if (s_pmuOk) {
    s_pmu.setChargeTargetVoltage(XPOWERS_AXP2101_CHG_VOL_4V2);
    s_pmu.setChargerConstantCurr(XPOWERS_AXP2101_CHG_CUR_500MA);
    s_pmu.enableBattDetection();
    s_pmu.enableVbusVoltageMeasure();
    s_pmu.enableBattVoltageMeasure();
    s_pmu.enableALDO3();
    // The playback chip's analogue side runs from this output ("A3V3" in the schematic). With it off the chip
    // still answers on the bus, takes its samples, and makes no sound at all.
    Serial.printf("hw: the analogue supply (ALDO1) was %s, set to %u mV\n", s_pmu.isEnableALDO1() ? "on" : "off", (unsigned)s_pmu.getALDO1Voltage());
    s_pmu.setALDO1Voltage(3300);
    s_pmu.enableALDO1();
    // Have the chip note what its own key does. Nothing here waits for its interrupt line; it is asked.
    s_pmu.disableIRQ(XPOWERS_AXP2101_ALL_IRQ);
    s_pmu.clearIrqStatus();
    s_pmu.enableIRQ(XPOWERS_AXP2101_PKEY_SHORT_IRQ | XPOWERS_AXP2101_PKEY_LONG_IRQ | XPOWERS_AXP2101_PKEY_NEGATIVE_IRQ | XPOWERS_AXP2101_PKEY_POSITIVE_IRQ);
    Serial.printf("hw: power chip ok, battery %d mV, usb %d\n", (int)s_pmu.getBattVoltage(), (int)(s_pmu.getVbusVoltage() > 4000));
  } else {
    Serial.println("hw: power chip did not answer");
  }

  // Screen. The driver pulses the reset pin itself; the canvas starts the panel and the bus.
  s_bus = new Arduino_ESP32QSPI(PIN_LCD_CS, PIN_LCD_SCLK, PIN_LCD_SDIO0, PIN_LCD_SDIO1, PIN_LCD_SDIO2, PIN_LCD_SDIO3);
  s_panel = new Arduino_CO5300(s_bus, PIN_LCD_RESET, 0, LCD_W, LCD_H, 0, 0, 0, 0);
  s_canvas = new Arduino_Canvas(LCD_W, LCD_H, s_panel);
  if (!s_canvas->begin()) {
    Serial.println("hw: screen did not start");
    return false;
  }
  s_canvas->setUTF8Print(true);
  s_bus->beginWrite();
  s_bus->writeC8D8(0x36, LCD_MADCTL);
  s_bus->endWrite();
  s_panel->setBrightness(0);   // a black first frame, not a white flash
  s_canvas->fillScreen(0x0000);
  s_canvas->flush();
  s_panel->setBrightness(s_level);
  Serial.printf("hw: screen started, free heap %u, free psram %u\n", (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getFreePsram());

  // Touch
  s_touch.setPins(PIN_TP_RESET, PIN_TP_INT);
  s_touchOk = s_touch.begin(Wire, TP_ADDRESS, PIN_I2C_SDA, PIN_I2C_SCL);
  if (s_touchOk) {
    s_touch.setMaxCoordinates(LCD_W, LCD_H);
    s_touch.setMirrorXY(true, true);
    loadTouchFix();
    Serial.printf("hw: touch ok, model %s\n", s_touch.getModelName());
  } else {
    Serial.println("hw: touch controller did not answer");
  }
  return true;
}

Arduino_Canvas* hwCanvas() { return s_canvas; }

// The whole frame in one write: this panel shows nothing if a frame is sent as many small writes.
void hwPush() {
  if (s_screenOn) s_canvas->flush();
}

void hwBrightness(uint8_t level) {
  s_level = level;
  if (s_screenOn) s_panel->setBrightness(level);
}

void hwScreen(bool on) {
  if (on == s_screenOn) return;
  s_screenOn = on;
  if (on) {
    s_panel->displayOn();
    s_panel->setBrightness(s_level);
    s_canvas->flush();
  } else {
    s_panel->setBrightness(0);
    s_panel->displayOff();
  }
}

void hwDumpFrame() {
  const uint8_t* pixels = (const uint8_t*)s_canvas->getFramebuffer();
  size_t bytes = (size_t)LCD_W * LCD_H * 2;
  Serial.setTxTimeoutMs(200);   // this one is worth waiting for: someone asked for it and is reading
  Serial.printf("\nSHOT %d %d %u\n", LCD_W, LCD_H, (unsigned)bytes);
  for (size_t offset = 0; offset < bytes; offset += 2048) {
    Serial.write(pixels + offset, min((size_t)2048, bytes - offset));
  }
  Serial.print("\nEND\n");
  Serial.flush();
  Serial.setTxTimeoutMs(0);
}

static TouchFix s_touchFix = {1.0f, 0.0f, 1.0f, 0.0f};
static Preferences s_touchKept;

// A correction that would move a touch by more than a third of the screen, or stretch it by more than a quarter,
// is a mistake, not a measurement.
static bool sane(const TouchFix& f) {
  return f.scaleX > 0.75f && f.scaleX < 1.25f && f.scaleY > 0.75f && f.scaleY < 1.25f && fabsf(f.offsetX) < LCD_W / 3 && fabsf(f.offsetY) < LCD_H / 3;
}

static void loadTouchFix() {
  s_touchKept.begin("touch", false);
  TouchFix f = {s_touchKept.getFloat("sx", 1.0f), s_touchKept.getFloat("ox", 0.0f), s_touchKept.getFloat("sy", 1.0f), s_touchKept.getFloat("oy", 0.0f)};
  if (sane(f)) s_touchFix = f;
  Serial.printf("hw: touch correction scale %.3f %.3f, offset %.1f %.1f\n", s_touchFix.scaleX, s_touchFix.scaleY, s_touchFix.offsetX, s_touchFix.offsetY);
}

TouchFix hwTouchFix() { return s_touchFix; }

bool hwSetTouchFix(const TouchFix& fix, bool keep) {
  if (!sane(fix)) return false;
  s_touchFix = fix;
  if (keep) {
    s_touchKept.putFloat("sx", fix.scaleX);
    s_touchKept.putFloat("ox", fix.offsetX);
    s_touchKept.putFloat("sy", fix.scaleY);
    s_touchKept.putFloat("oy", fix.offsetY);
  }
  return true;
}

Touch hwTouchRaw() {
  Touch t = {false, 0, 0};
  if (!s_touchOk) return t;
  const TouchPoints& points = s_touch.getTouchPoints();
  if (points.getPointCount() > 0) {
    const TouchPoint& p = points.getPoint(0);
    t.down = true;
    // On this board the touch controller's axes are a quarter turn from the picture's: what it calls X runs up
    // the screen, and what it calls Y runs across it. Measured with a finger on nine crosses ("calibrate"); for
    // weeks before that a finger further right was read as a finger further down, and nobody had held a finger
    // on a button to notice.
    int alongX = constrain((int)p.y, 0, LCD_W - 1), upY = constrain((int)p.x, 0, LCD_H - 1);
    t.x = alongX;
    t.y = (LCD_H - 1) - upY;
  }
  return t;
}

Touch hwTouch() {
  Touch t = hwTouchRaw();
  if (t.down) {
    t.x = constrain((int)lroundf((t.x - s_touchFix.offsetX) / s_touchFix.scaleX), 0, LCD_W - 1);
    t.y = constrain((int)lroundf((t.y - s_touchFix.offsetY) / s_touchFix.scaleY), 0, LCD_H - 1);
  }
  return t;
}

bool hwAnyKeyPressed() {
  return digitalRead(PIN_KEY_PWR) == HIGH || digitalRead(PIN_KEY_USER) == LOW || digitalRead(PIN_KEY_BOOT) == LOW;
}

#if RD_DEBUG_SERIAL
// What the keys did, kept in memory so it can be read later without having had a program listening.
static const char* const KEY_EVENTS[] = {
  "", "BOOT key (GPIO0) down", "BOOT key (GPIO0) up", "KEY3 (GPIO18) down", "KEY3 (GPIO18) up",
  "GPIO16 went high", "GPIO16 went low", "power chip: its key went down", "power chip: its key came up",
  "power chip: short press", "power chip: long press"};
static struct { uint32_t at; uint8_t what; } s_keyLog[48];
static uint8_t s_keyLogCount = 0, s_keyLogNext = 0;
static bool s_keyWas[3] = {false, false, false};
static bool s_keyPollReady = false;

static void keyNote(uint8_t what) {
  s_keyLog[s_keyLogNext] = {millis(), what};
  s_keyLogNext = (s_keyLogNext + 1) % 48;
  if (s_keyLogCount < 48) s_keyLogCount++;
  Serial.printf("key: %s\n", KEY_EVENTS[what]);
}

static int readRegister(uint8_t address, uint8_t reg) {
  Wire.beginTransmission(address);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return -1;
  if (Wire.requestFrom((int)address, 1) != 1) return -1;
  return Wire.read();
}

void hwDebugPollKeys() {
  if (!s_keyPollReady) {
    s_keyPollReady = true;
    s_keyWas[0] = digitalRead(PIN_KEY_BOOT) == LOW;
    s_keyWas[1] = digitalRead(PIN_KEY_USER) == LOW;
    s_keyWas[2] = digitalRead(PIN_KEY_PWR) == HIGH;
  }
  bool boot = digitalRead(PIN_KEY_BOOT) == LOW, user = digitalRead(PIN_KEY_USER) == LOW, high16 = digitalRead(PIN_KEY_PWR) == HIGH;
  if (boot != s_keyWas[0]) { s_keyWas[0] = boot; keyNote(boot ? 1 : 2); }
  if (user != s_keyWas[1]) { s_keyWas[1] = user; keyNote(user ? 3 : 4); }
  if (high16 != s_keyWas[2]) { s_keyWas[2] = high16; keyNote(high16 ? 5 : 6); }
}

void hwDebugProbe(const String& what) {
  if (what == "i2c") {
    Serial.print("i2c: chips that answer at");
    for (uint8_t address = 0x08; address < 0x78; address++) {
      Wire.beginTransmission(address);
      if (Wire.endTransmission() == 0) Serial.printf(" 0x%02X", address);
    }
    Serial.println();
  } else if (what == "pmu") {
    if (!s_pmuOk) {
      Serial.println("pmu: the power chip does not answer");
      return;
    }
    Serial.printf("pmu: key hold-to-switch-off setting %u, hold-to-switch-on setting %u, register 0x22 = 0x%02X, register 0x27 = 0x%02X\n",
                  (unsigned)s_pmu.getPowerKeyPressOffTime(), (unsigned)s_pmu.getPowerKeyPressOnTime(), readRegister(AXP2101_SLAVE_ADDRESS, 0x22),
                  readRegister(AXP2101_SLAVE_ADDRESS, 0x27));
    Serial.printf("pmu: usb power %d, battery present %d, battery %d mV, system %d mV, charging %d\n", (int)s_pmu.isVbusIn(), (int)s_pmu.isBatteryConnect(),
                  (int)s_pmu.getBattVoltage(), (int)s_pmu.getSystemVoltage(), (int)s_pmu.isCharging());
    Serial.printf("pmu: pins now: GPIO0 %d, GPIO18 %d, GPIO16 %d\n", digitalRead(PIN_KEY_BOOT), digitalRead(PIN_KEY_USER), digitalRead(PIN_KEY_PWR));
  } else if (what == "rails") {
    if (!s_pmuOk) return;
    Serial.printf("rails: DC1 %d %u mV, DC2 %d %u, DC3 %d %u, DC4 %d %u, DC5 %d %u\n", (int)s_pmu.isEnableDC1(), (unsigned)s_pmu.getDC1Voltage(),
                  (int)s_pmu.isEnableDC2(), (unsigned)s_pmu.getDC2Voltage(), (int)s_pmu.isEnableDC3(), (unsigned)s_pmu.getDC3Voltage(),
                  (int)s_pmu.isEnableDC4(), (unsigned)s_pmu.getDC4Voltage(), (int)s_pmu.isEnableDC5(), (unsigned)s_pmu.getDC5Voltage());
    Serial.printf("rails: ALDO1 %d %u mV, ALDO2 %d %u, ALDO3 %d %u, ALDO4 %d %u, BLDO1 %d %u, BLDO2 %d %u, DLDO1 %d %u, DLDO2 %d %u\n",
                  (int)s_pmu.isEnableALDO1(), (unsigned)s_pmu.getALDO1Voltage(), (int)s_pmu.isEnableALDO2(), (unsigned)s_pmu.getALDO2Voltage(),
                  (int)s_pmu.isEnableALDO3(), (unsigned)s_pmu.getALDO3Voltage(), (int)s_pmu.isEnableALDO4(), (unsigned)s_pmu.getALDO4Voltage(),
                  (int)s_pmu.isEnableBLDO1(), (unsigned)s_pmu.getBLDO1Voltage(), (int)s_pmu.isEnableBLDO2(), (unsigned)s_pmu.getBLDO2Voltage(),
                  (int)s_pmu.isEnableDLDO1(), (unsigned)s_pmu.getDLDO1Voltage(), (int)s_pmu.isEnableDLDO2(), (unsigned)s_pmu.getDLDO2Voltage());
  } else if (what == "bench") {
    uint32_t started = micros();
    for (int i = 0; i < 5; i++) s_canvas->flush();
    uint32_t push = (micros() - started) / 5;
    started = micros();
    for (int i = 0; i < 5; i++) s_canvas->fillScreen(0x0000);
    uint32_t fill = (micros() - started) / 5;
    Serial.printf("bench: one frame to the panel %lu us, clearing the frame in memory %lu us\n", (unsigned long)push, (unsigned long)fill);
  } else if (what == "keylog") {
    Serial.printf("keylog: %u events, now %lu ms after start\n", (unsigned)s_keyLogCount, (unsigned long)millis());
    for (uint8_t i = 0; i < s_keyLogCount; i++) {
      uint8_t at = (uint8_t)((s_keyLogNext + 48 - s_keyLogCount + i) % 48);
      Serial.printf("keylog: %8lu ms  %s\n", (unsigned long)s_keyLog[at].at, KEY_EVENTS[s_keyLog[at].what]);
      delay(3);   // short lines, a little apart: nothing is waited for when the port is slow to take them
    }
  }
}
#endif

Battery hwBattery() {
  Battery b = {-1, 0, false};
  if (!s_pmuOk) return b;
  b.millivolts = s_pmu.getBattVoltage();
  b.usb = s_pmu.getVbusVoltage() > 4000;
  if (s_pmu.isBatteryConnect()) b.percent = constrain((b.millivolts - 3200) / 10, 0, 100);
  return b;
}
