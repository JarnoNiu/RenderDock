// Smooth shapes, drawn straight into the frame: edges are blended, so a ring looks like a ring and not like stairs.
#pragma once
#include <Arduino.h>

// A colour as the panel takes it (5-6-5), from red, green and blue 0…255.
constexpr uint16_t rgb(uint8_t r, uint8_t g, uint8_t b) { return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)); }

// A filled box with round corners. `strength` 0…255 lays the colour over what is there (255: solid).
void shapeRoundRect(uint16_t* frame, int x, int y, int w, int h, int radius, uint16_t color, uint8_t strength = 255);
// The outline of such a box, `line` pixels wide.
void shapeRoundRectLine(uint16_t* frame, int x, int y, int w, int h, int radius, float line, uint16_t color, uint8_t strength = 255);
void shapeDisc(uint16_t* frame, float cx, float cy, float radius, uint16_t color, uint8_t strength = 255);
// A thick line with round ends.
void shapeLine(uint16_t* frame, float x0, float y0, float x1, float y1, float width, uint16_t color);

// The progress ring. It starts at twelve o'clock and runs clockwise for `fraction` of the way round, its colour
// passing from `from` to `to` along the way, with round ends and a faint glow; the rest of the circle is `track`.
// `fraction` 1 or more closes it into a whole ring (`from` at the top, `to` at the bottom).
void shapeRing(uint16_t* frame, int cx, int cy, int outerRadius, int thickness, float fraction, uint16_t from, uint16_t to, uint16_t track);
// The same ring as a row of dots: something is going on, and how far along it is cannot be told.
void shapeDottedRing(uint16_t* frame, int cx, int cy, int outerRadius, int thickness, int dots, float dotRadius, uint16_t color, uint16_t track);
