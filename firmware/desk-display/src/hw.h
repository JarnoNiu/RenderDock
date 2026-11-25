// The board: power, screen, touch, keys.
#pragma once
#include <Arduino.h>
#include <Arduino_GFX_Library.h>

struct Battery {
  int percent;   // rough, from the cell voltage
  int millivolts;
  bool usb;
};

struct Touch {
  bool down;   // a finger is on the screen
  int x, y;    // where, in screen pixels
};

// Where the touch controller says a finger is, is not where the person holding the finger out thinks it is: the
// part of the finger that meets the glass sits below the tip they aim with, and how far depends on the hand and
// on how the board stands. So the reading is corrected, each axis on its own:
//     shown = (read - offset) / scale
// The numbers are measured on the board with the hand that uses it (BOOT held for three seconds starts it; so does
// "calibrate" on the bring-up console), and kept across restarts. With none kept, the reading is used as it is.
struct TouchFix {
  float scaleX, offsetX, scaleY, offsetY;
};

// The correction in use, and setting another one. `keep` writes it where it survives a restart.
// A correction that is plainly a mistake is not taken: false then.
TouchFix hwTouchFix();
bool hwSetTouchFix(const TouchFix& fix, bool keep);
// The touch controller's own reading, without the correction (for measuring one).
struct Touch hwTouchRaw();

// Brings the board up. Returns false, with a line on the serial port, if the screen cannot be started.
bool hwBegin();

// Everything is drawn here, then pushed to the panel in one go.
Arduino_Canvas* hwCanvas();
void hwPush();

// 0 (off) … 255
void hwBrightness(uint8_t level);
void hwScreen(bool on);

// Writes the frame as it was last drawn to the serial port: a header line, the raw 16-bit pixels, a footer line.
void hwDumpFrame();

Touch hwTouch();
bool hwAnyKeyPressed();
Battery hwBattery();

// The three keys. BOOT and KEY3 are plain switches. The power key belongs to the power chip, which says when it
// was pressed briefly and when it has been held for a second and a half; held for four seconds, the chip cuts
// the power by itself, whatever this firmware is doing. BOOT counts as held after three seconds: what it starts
// (measuring the touch) should not start by accident.
enum KeyEvent { KEY_NONE, KEY_POWER_SHORT, KEY_POWER_LONG, KEY_USER_SHORT, KEY_USER_LONG, KEY_BOOT_SHORT, KEY_BOOT_LONG };
// Call often. What a key has done since the last call, one event at a time.
KeyEvent hwKeyEvent();

#if RD_DEBUG_SERIAL
// Bring-up only. "i2c": which chips answer on the shared bus. "pmu": how the power chip is set up for its key.
// "rails": which of the power chip's outputs are on, and at what voltage.
// "bench": how long a frame takes to reach the panel. "keylog": what the three keys have done since start-up.
void hwDebugProbe(const String& what);
// Call often: notes every change of a key's pin.
void hwDebugPollKeys();
// As if a key had been pressed, for trying what the keys do without a hand.
void hwDebugKey(KeyEvent event);
#endif
