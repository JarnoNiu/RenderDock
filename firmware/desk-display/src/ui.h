// The screens, and what a finger does on them.
#pragma once
#include <Arduino.h>

void uiBegin();
// Call often from loop(): reads the touch panel, decides which screen applies, and redraws when something changed.
void uiTick();

// Bring-up only: show what arrives over USB as if a paired computer had sent it. A request fed this way is marked
// as made up, and an answer to it is not sent anywhere.
void uiDebugFeed(bool on);
#if RD_DEBUG_SERIAL
// Whether snapshots fed in over USB may make the board sound. Off unless asked for.
void uiDebugLoud(bool on);
// Starts (or stops) measuring the touch: nine crosses, one after another, each to be held with a finger. For each
// the console gets the cross's place and where the touch controller said the finger was, with and without the
// correction in use. Nothing else on the screen answers to touch meanwhile.
void uiDebugCalibrate(bool on);
#endif
#if RD_DEBUG_SERIAL
// Bring-up only: a finger put down at a point from the console (down = false lifts it), so the screens that
// answer to touch can be checked without one.
void uiDebugTouch(bool down, int x, int y);
// Bring-up only: show the pairing screen with these digits (0 to stop), to check how it looks without pairing.
void uiDebugPasskey(uint32_t passkey);
// Puts a page on the screen: 0 the renders, 1 the agents, 2 the computer itself.
void uiDebugPage(int page);
// Bring-up only: leave whatever is on the panel alone for this long (a picture sent over USB). A touch ends it.
void uiDebugHold(uint32_t ms);
// Bring-up only: how long the last frame took to draw and to send to the panel, in microseconds.
void uiDebugTimes(uint32_t& draw, uint32_t& push);
#endif
