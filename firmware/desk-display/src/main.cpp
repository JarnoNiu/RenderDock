// RenderDock desk display, for the Waveshare ESP32-S3-Touch-AMOLED-2.16.
//
// A small screen that shows how the renders and the coding agents on a Mac are doing, and lets the user answer
// an agent's request with a finger. It speaks the Hardware Buddy protocol over Bluetooth, so the other end may
// be RenderDock (which adds a few fields of its own) or the Claude desktop app.
#include <Arduino.h>
#include "board.h"
#include "hw.h"
#include "link.h"
#include "screens.h"
#include "sound.h"
#include "state.h"
#include "ui.h"

void setup() {
#if RD_DEBUG_SERIAL
  // The USB port keeps 256 bytes by default and drops what does not fit; a snapshot is longer than that.
  Serial.setRxBufferSize(8192);
#endif
  Serial.setTxBufferSize(4096);
  Serial.begin(115200);
  // Nothing this firmware prints is worth waiting for. Left at its default, a board plugged into a computer where
  // no program is reading the port waits two seconds at every line it prints, and the screen and the touch wait
  // with it. With no wait, a line that does not fit is dropped.
  Serial.setTxTimeoutMs(0);
  protoReset();
  if (!hwBegin()) {
    // Without a screen there is nothing to show; say so on the serial port and stop.
    while (true) {
      Serial.println("RenderDock desk display: the screen did not start");
      delay(2000);
    }
  }
  bool sound = soundBegin();
  linkBegin();
  uiBegin();
  Serial.printf("sound: the playback chip %s\n", sound ? "is ready" : "did not start; there will be no sound");
  Serial.printf("RenderDock desk display %s ready as %s\n", RD_VERSION, linkName());
}

#if RD_DEBUG_SERIAL
static uint32_t debugWorstGap(bool reset);
// "quiet SECONDS" on the console: what the paired computer sends is not shown for that long, so that snapshots
// fed over USB stay on the screen long enough to be looked at.
static uint32_t s_quietUntil = 0;

// "image SECONDS", then one whole frame of pixels as the panel takes them (two bytes each, 460800 in all): shown
// for that long, or until the screen is touched. For looking at a drawing on the glass itself.
static void receiveImage(int seconds) {
  uint8_t* frame = (uint8_t*)hwCanvas()->getFramebuffer();
  size_t total = (size_t)LCD_W * LCD_H * 2, got = 0;
  uint32_t last = millis();
  while (got < total && millis() - last < 2000) {
    int waiting = Serial.available();
    if (waiting <= 0) {
      delay(1);
      continue;
    }
    size_t n = Serial.read(frame + got, min((size_t)waiting, total - got));
    if (n > 0) {
      got += n;
      last = millis();
    }
  }
  if (got == total) {
    hwScreen(true);
    hwBrightness(170);
    hwPush();
    uiDebugHold((uint32_t)max(1, seconds) * 1000);
    Serial.printf("image ok\n");
  } else {
    Serial.printf("image short %u\n", (unsigned)got);
  }
}

// The bring-up console on USB. "shot" dumps the frame as drawn; a line of JSON is shown as if a paired computer
// had sent it, without the sounds that would go with it unless "feed loud" was sent first ("feed quiet" undoes
// that); "feed off" goes back to showing only what arrives over Bluetooth; "down X Y" puts a finger on the
// screen and "up" lifts it; "passkey 123456" shows the pairing screen with those digits ("passkey 0" stops);
// "stall" says how long the loop has ever been held up; "i2c", "pmu", "bench" and "keylog" report on the board
// (see hw.h); "image SECONDS" shows a picture sent after it; "ui old" and "ui new" switch between the old and the
// redesigned screens, and "round 2" / "round 3" pick the rounded face of the numerals (Nunito / M PLUS Rounded);
// "quiet SECONDS" leaves what the paired computer sends unshown for that long; "key power", "key power long",
// "key user", "key user long" and "key boot" act as if that key had been pressed; "sound N" plays one of the
// sounds whatever the hour or the switches say (0 a request, 1 waiting, 2 done, 3 failed, 4 the tick), and
// "volume N" sets how loud, 0 to 100. "calibrate" measures where a finger is read against where it aims, on nine
// crosses ("calibrate off" stops it); "touchfix" prints the correction in use, "touchfix SX OX SY OY" sets and
// keeps one (read = scale * aimed + offset, for X and for Y), "touchfix reset" removes it.
static void debugConsole() {
  static String input;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c != '\n') {
      if (c != '\r' && input.length() < 6000) input += c;
      continue;
    }
    if (input == "shot") hwDumpFrame();
    else if (input == "i2c" || input == "pmu" || input == "rails" || input == "bench" || input == "keylog") hwDebugProbe(input);
    else if (input.startsWith("image ")) receiveImage(atoi(input.c_str() + 6));
    else if (input == "round 2" || input == "round 3") screensDebugRounded(input[6] - '0');
    else if (input == "ui old" || input == "ui new") screensDebugUse(input == "ui new");
    else if (input.startsWith("sound ")) soundPlay((Sound)constrain(atoi(input.c_str() + 6), 0, SOUND_COUNT - 1));
    else if (input == "listen") soundSelfTest();
    else if (input.startsWith("hear ")) soundHear(atoi(input.c_str() + 5));
    else if (input.startsWith("volume ")) {
      soundVolume(atoi(input.c_str() + 7));
      Serial.printf("sound: volume %d\n", soundVolumeNow());
    }
    else if (input == "key power") hwDebugKey(KEY_POWER_SHORT);
    else if (input == "key power long") hwDebugKey(KEY_POWER_LONG);
    else if (input == "key user") hwDebugKey(KEY_USER_SHORT);
    else if (input == "key user long") hwDebugKey(KEY_USER_LONG);
    else if (input == "key boot") hwDebugKey(KEY_BOOT_SHORT);
    else if (input == "key boot long") hwDebugKey(KEY_BOOT_LONG);
    else if (input.startsWith("quiet ")) s_quietUntil = millis() + (uint32_t)max(0L, atol(input.c_str() + 6)) * 1000;
    else if (input == "stall") {
      uint32_t draw = 0, push = 0;
      uiDebugTimes(draw, push);
      Serial.printf("stall: longest gap between two passes of the loop %lu ms, up %lu s; last frame drawn in %lu us, sent in %lu us\n",
                    (unsigned long)debugWorstGap(true), (unsigned long)(millis() / 1000), (unsigned long)draw, (unsigned long)push);
    }
    else if (input == "feed off") uiDebugFeed(false);
    else if (input == "feed loud" || input == "feed quiet") uiDebugLoud(input == "feed loud");
    else if (input == "calibrate" || input == "calibrate off") uiDebugCalibrate(input == "calibrate");
    else if (input == "touchfix") {
      TouchFix f = hwTouchFix();
      Serial.printf("touchfix: scale %.4f %.4f offset %.2f %.2f\n", f.scaleX, f.scaleY, f.offsetX, f.offsetY);
    }
    else if (input.startsWith("touchfix ")) {
      // "touchfix SX OX SY OY" sets the correction and keeps it; "touchfix reset" goes back to none.
      TouchFix f = {1.0f, 0.0f, 1.0f, 0.0f};
      if (input == "touchfix reset" || sscanf(input.c_str() + 9, "%f %f %f %f", &f.scaleX, &f.offsetX, &f.scaleY, &f.offsetY) == 4) {
        hwSetTouchFix(f, true);
        f = hwTouchFix();
        Serial.printf("touchfix: scale %.4f %.4f offset %.2f %.2f\n", f.scaleX, f.scaleY, f.offsetX, f.offsetY);
      }
    }
    else if (input == "up") uiDebugTouch(false, 0, 0);
    else if (input.startsWith("passkey ")) uiDebugPasskey((uint32_t)atol(input.c_str() + 8));
    else if (input.startsWith("down ")) {
      int x = 0, y = 0;
      if (sscanf(input.c_str() + 5, "%d %d", &x, &y) == 2) uiDebugTouch(true, x, y);
    }
    else if (input.startsWith("{")) {
      uiDebugFeed(true);
      g_protoFromConsole = true;
      protoHandle(input);
      g_protoFromConsole = false;
    }
    input = "";
  }
}
#endif

#if RD_DEBUG_SERIAL
// The longest the loop has gone without coming round, since it was last asked ("stall" on the console).
static uint32_t s_loopAt = 0, s_worstGap = 0;
static uint32_t debugWorstGap(bool reset) {
  uint32_t worst = s_worstGap;
  if (reset) s_worstGap = 0;
  return worst;
}
#endif

void loop() {
#if RD_DEBUG_SERIAL
  uint32_t loopNow = millis();
  if (s_loopAt != 0 && loopNow - s_loopAt > s_worstGap) s_worstGap = loopNow - s_loopAt;
  s_loopAt = loopNow;
#endif
  String line;
  linkTick();
  while (linkReadLine(line)) {
#if RD_DEBUG_SERIAL
    if (s_quietUntil != 0 && (int32_t)(millis() - s_quietUntil) < 0) continue;
#endif
    protoHandle(line);
  }
#if RD_DEBUG_SERIAL
  debugConsole();
  hwDebugPollKeys();
#endif
  uiTick();
  delay(10);
}
