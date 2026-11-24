// Smooth text. The letters are drawn ahead of time on a computer (tools/make-fonts.swift) and kept in their own
// part of the flash ("fonts"); this file finds them there and puts them on the frame, sixteen levels of grey each.
#pragma once
#include <Arduino.h>

// Which drawn letters to use. `text` has Chinese and everything else; `latin`, when not 0, is tried first for
// letters, digits and punctuation, so that numbers and names come out in the rounded face.
struct TextStyle {
  uint16_t text;
  uint16_t latin;
};

// Finds the fonts. False if this board has none (or another version of the file): the callers then fall back to
// the built-in bitmap font.
bool fontBegin();
bool fontReady();
// Whether a face with this id is in the file.
bool fontHas(uint16_t face);

int fontWidth(TextStyle style, const char* utf8);
// Draws at a baseline. `color` is the letters' colour as the panel takes it (5-6-5).
void fontDraw(uint16_t* frame, TextStyle style, int x, int baseline, uint16_t color, const char* utf8);
// The same, centred on x or ending at x.
void fontDrawCentred(uint16_t* frame, TextStyle style, int centreX, int baseline, uint16_t color, const char* utf8);
void fontDrawRight(uint16_t* frame, TextStyle style, int rightX, int baseline, uint16_t color, const char* utf8);

// A text cut to a width. Names lose their middle (the end often tells versions apart); other text loses its end.
String fontFit(TextStyle style, const char* utf8, int maxWidth, bool keepEnd);
