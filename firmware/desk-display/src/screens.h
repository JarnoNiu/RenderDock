// The redesigned screens: smooth shapes and the fonts kept in flash, drawn straight into the frame.
// A board without the fonts uses the first screens in ui.cpp instead.
#pragma once
#include <Arduino.h>

// Looks for the fonts.
void screensBegin();
bool screensReady();

// Where the two answer buttons are, so that the touch code and the drawing agree.
static const int SCREEN_DENY_X = 24, SCREEN_ALLOW_X = 248, SCREEN_BUTTON_Y = 302, SCREEN_BUTTON_W = 208, SCREEN_BUTTON_H = 150;

// Nothing has connected (or the computer went quiet); `passkey` not 0 shows the six digits to type on the computer.
void screenLink(uint16_t* frame, uint32_t passkey, bool connected, const char* name);
// Something is rendering: the ring, the percentage, the time left, the shot, its job and the sessions.
void screenRendering(uint16_t* frame);
// Sessions are working and nothing renders. Also what the plain protocol's counts are shown with.
void screenAgents(uint16_t* frame);
// A session needs the user, and it cannot be answered here.
void screenWaiting(uint16_t* frame);
// Something finished, or failed.
void screenFinished(uint16_t* frame, bool failed);
void screenIdle(uint16_t* frame);
void screenList(uint16_t* frame);
// A request to answer. Both buttons have to be held: on a screen this small a touch is too easily a mistake.
// `holdAllow` and `holdDeny` are how far a finger held on that button has got (0…1), or negative when none is;
// `allowed` says which answer was given, once one has been.
void screenRequest(uint16_t* frame, float holdAllow, float holdDeny, bool allowed);
// Whether the request on screen can be shown whole. If not, it cannot be allowed here.
bool screenRequestFits();
// A question another program is asking, with its answers as buttons to hold. `pressed` is the answer under the
// finger, or -1, and `hold` how far the hold has got (0…1). Lilac, where a request to approve is amber: the two
// must not be taken for each other.
void screenAsk(uint16_t* frame, int pressed, float hold);
// Whether the question on screen can be shown whole, answers and all. If not, it is answered on the computer.
bool screenAskFits();
// Which answer's button is at this point, or -1. `slack` widens every button by that much.
int screenAskHit(int x, int y, int slack);
// A notice another program sent: how it went, a title, a few lines, and who sent it.
void screenNote(uint16_t* frame);
// A word in the corner of the screens with the ring: "do not disturb" or "muted" is on.
void screenBadge(uint16_t* frame, const char* text);
// A short notice over whatever is on the screen, for the moment after a key changed something.
void screenToast(uint16_t* frame, const char* text);

#if RD_DEBUG_SERIAL
// Bring-up only: one target of the touch measurement. A cross to hold a finger on, which one of how many it is,
// and whether its reading has been taken (then the finger may be lifted).
void screenCalibrate(uint16_t* frame, int x, int y, int index, int total, bool taken);
// Bring-up only. Which rounded face the numerals use (2: Nunito, 3: M PLUS Rounded), and whether the redesigned
// screens are used at all.
void screensDebugRounded(int family);
void screensDebugUse(bool on);
#endif
