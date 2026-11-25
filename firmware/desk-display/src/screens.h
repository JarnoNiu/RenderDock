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
// Two lines for that screen about how Wi-Fi is doing, in place of "switch the link on in RenderDock's menu".
// Empty for a device that has not been given a network. Set before a frame is drawn.
// What is shown is coming over Wi-Fi, and not over Bluetooth.
void screensOverWiFi(bool on);
void screensNetWords(const char* first, const char* second);
// The screens below are drawn for one side of what the computer is doing (state.h): its renders, or its agents
// and other programs' tasks. Each side has a page.
struct Side;
// Something has a percentage: the ring, the number, the time left, its name; for a render its job and queue.
void screenRendering(uint16_t* frame, const Side& side);
// A render that does not say how far along it is.
void screenRenderGoing(uint16_t* frame, const Side& side);
// Sessions are working. Also what the plain protocol's counts are shown with.
void screenAgents(uint16_t* frame, const Side& side);
// A session needs the user and cannot be answered here; or a render has stopped moving.
void screenWaiting(uint16_t* frame, const Side& side);
// Something finished, or failed.
void screenFinished(uint16_t* frame, const Side& side, bool failed);
// Nothing on this page: the clock. `page` 0 is the renders', 1 the agents', -1 when the two are not told apart.
void screenIdle(uint16_t* frame, int page);
void screenList(uint16_t* frame, const Side& side, int page);
// The computer itself: processor, graphics, memory, heat, and under them disk, power and sleep.
void screenMac(uint16_t* frame);
// The three marks along the bottom edge that say which page this is and how the others are doing.
void screenPages(uint16_t* frame, int page);
// How much is left in this device's own battery, for the screens to show while it runs from it: 0…100, or a
// negative number when it is on USB or has no battery (then nothing is drawn). Set before a frame is drawn.
void screensBattery(int percent);
// That battery, small, in the top right corner: for the screens with the ring and the clock. The computer's own
// page draws it beside its clock instead; a list has that corner taken.
void screenBatteryCorner(uint16_t* frame);
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

// Measuring the touch: one target. A cross to hold a finger on, which one of how many it is, and whether its
// reading has been taken (then the finger may be lifted).
void screenCalibrate(uint16_t* frame, int x, int y, int index, int total, bool taken);
// How the measuring went: taken and kept (with how far off a finger was read before and is read now, in pixels),
// or not good enough to keep.
void screenCalibrateResult(uint16_t* frame, bool kept, int before, int after);

#if RD_DEBUG_SERIAL
// Bring-up only. Which rounded face the numerals use (2: Nunito, 3: M PLUS Rounded), and whether the redesigned
// screens are used at all.
void screensDebugRounded(int family);
void screensDebugUse(bool on);
#endif
