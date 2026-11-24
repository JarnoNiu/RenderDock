#include "shapes.h"
#include "board.h"

// One colour over another, by a weight out of 32.
static inline uint16_t mix(uint16_t under, uint16_t over, uint8_t weight) {
  uint32_t u = (under | ((uint32_t)under << 16)) & 0x07E0F81F;
  uint32_t o = (over | ((uint32_t)over << 16)) & 0x07E0F81F;
  uint32_t r = (u + (((o - u) * weight) >> 5)) & 0x07E0F81F;
  return (uint16_t)(r | (r >> 16));
}

// Lays a colour on a pixel, as much as `cover` (0…1) of `strength` (0…255) says.
static inline void lay(uint16_t* frame, int x, int y, uint16_t color, float cover, uint8_t strength) {
  if (cover <= 0.0f || x < 0 || y < 0 || x >= LCD_W || y >= LCD_H) return;
  if (cover > 1.0f) cover = 1.0f;
  uint8_t weight = (uint8_t)(cover * strength * (32.0f / 255.0f) + 0.5f);
  if (weight == 0) return;
  uint16_t* at = frame + y * LCD_W + x;
  *at = weight >= 32 ? color : mix(*at, color, weight);
}

// How far a point is outside a box with round corners (negative inside). The box is centred on the origin.
static inline float roundBoxDistance(float px, float py, float halfW, float halfH, float radius) {
  float dx = fabsf(px) - (halfW - radius), dy = fabsf(py) - (halfH - radius);
  float ox = dx > 0 ? dx : 0, oy = dy > 0 ? dy : 0;
  float inside = (dx > dy ? dx : dy);
  return sqrtf(ox * ox + oy * oy) + (inside < 0 ? inside : 0) - radius;
}

void shapeRoundRect(uint16_t* frame, int x, int y, int w, int h, int radius, uint16_t color, uint8_t strength) {
  if (w <= 0 || h <= 0) return;
  if (radius * 2 > w) radius = w / 2;
  if (radius * 2 > h) radius = h / 2;
  float cx = x + w / 2.0f, cy = y + h / 2.0f;
  uint8_t weight = (uint8_t)(strength * (32.0f / 255.0f) + 0.5f);
  for (int py = y; py < y + h; py++) {
    if (py < 0 || py >= LCD_H) continue;
    // Only the corners need measuring. Everything between them is a plain run of pixels, filled as one.
    bool cornerRow = py < y + radius || py >= y + h - radius;
    int from = x, to = x + w;
    if (cornerRow) {
      from = x + radius;
      to = x + w - radius;
      for (int i = 0; i < radius; i++) {
        float cover = 0.5f - roundBoxDistance(x + i + 0.5f - cx, py + 0.5f - cy, w / 2.0f, h / 2.0f, radius);
        lay(frame, x + i, py, color, cover, strength);
        lay(frame, x + w - 1 - i, py, color, cover, strength);
      }
    }
    if (from < 0) from = 0;
    if (to > LCD_W) to = LCD_W;
    uint16_t* line = frame + py * LCD_W;
    if (weight >= 32) {
      for (int px = from; px < to; px++) line[px] = color;
    } else if (weight > 0) {
      for (int px = from; px < to; px++) line[px] = mix(line[px], color, weight);
    }
  }
}

void shapeRoundRectLine(uint16_t* frame, int x, int y, int w, int h, int radius, float line, uint16_t color, uint8_t strength) {
  if (w <= 0 || h <= 0) return;
  if (radius * 2 > w) radius = w / 2;
  if (radius * 2 > h) radius = h / 2;
  float cx = x + w / 2.0f, cy = y + h / 2.0f;
  // The four corners are measured pixel by pixel.
  for (int j = 0; j < radius; j++) {
    for (int i = 0; i < radius; i++) {
      float d = roundBoxDistance(x + i + 0.5f - cx, y + j + 0.5f - cy, w / 2.0f, h / 2.0f, radius);
      float cover = min(0.5f - d, d + line + 0.5f);   // inside the box, and no deeper than the line is wide
      if (cover <= 0) continue;
      lay(frame, x + i, y + j, color, cover, strength);
      lay(frame, x + w - 1 - i, y + j, color, cover, strength);
      lay(frame, x + i, y + h - 1 - j, color, cover, strength);
      lay(frame, x + w - 1 - i, y + h - 1 - j, color, cover, strength);
    }
  }
  // The straight sides are plain runs: whole pixels, then one row or column for what is left of the width.
  int rows = (int)ceilf(line);
  for (int k = 0; k < rows; k++) {
    float cover = min(1.0f, line - k);
    for (int px = x + radius; px < x + w - radius; px++) {
      lay(frame, px, y + k, color, cover, strength);
      lay(frame, px, y + h - 1 - k, color, cover, strength);
    }
    for (int py = y + radius; py < y + h - radius; py++) {
      lay(frame, x + k, py, color, cover, strength);
      lay(frame, x + w - 1 - k, py, color, cover, strength);
    }
  }
}

void shapeDisc(uint16_t* frame, float cx, float cy, float radius, uint16_t color, uint8_t strength) {
  int x0 = (int)floorf(cx - radius - 1), x1 = (int)ceilf(cx + radius + 1);
  int y0 = (int)floorf(cy - radius - 1), y1 = (int)ceilf(cy + radius + 1);
  for (int py = y0; py <= y1; py++) {
    for (int px = x0; px <= x1; px++) {
      float dx = px + 0.5f - cx, dy = py + 0.5f - cy;
      lay(frame, px, py, color, radius + 0.5f - sqrtf(dx * dx + dy * dy), strength);
    }
  }
}

void shapeLine(uint16_t* frame, float x0, float y0, float x1, float y1, float width, uint16_t color) {
  float half = width / 2.0f;
  int left = (int)floorf(min(x0, x1) - half - 1), right = (int)ceilf(max(x0, x1) + half + 1);
  int top = (int)floorf(min(y0, y1) - half - 1), bottom = (int)ceilf(max(y0, y1) + half + 1);
  float vx = x1 - x0, vy = y1 - y0;
  float lengthSquared = vx * vx + vy * vy;
  for (int py = top; py <= bottom; py++) {
    for (int px = left; px <= right; px++) {
      float wx = px + 0.5f - x0, wy = py + 0.5f - y0;
      float along = lengthSquared > 0 ? (wx * vx + wy * vy) / lengthSquared : 0;
      along = along < 0 ? 0 : (along > 1 ? 1 : along);
      float dx = wx - along * vx, dy = wy - along * vy;
      lay(frame, px, py, color, half + 0.5f - sqrtf(dx * dx + dy * dy), 255);
    }
  }
}

// The angle of a point, close enough for colouring a ring (within a hundredth of a degree), without the cost of
// the library's own.
static inline float quickAtan2(float y, float x) {
  float ax = fabsf(x), ay = fabsf(y);
  float a = ax > ay ? ay / (ax + 1e-12f) : ax / (ay + 1e-12f);
  float s = a * a;
  float r = ((-0.0464964749f * s + 0.15931422f) * s - 0.327622764f) * s * a + a;
  if (ay > ax) r = 1.57079637f - r;
  if (x < 0) r = 3.14159274f - r;
  return y < 0 ? -r : r;
}

// A colour between two, by t 0…1, mixed in full colour and only then cut down to what the panel takes.
static inline uint16_t between(uint16_t a, uint16_t b, float t) {
  if (t <= 0) return a;
  if (t >= 1) return b;
  int ar = (a >> 11) & 31, ag = (a >> 5) & 63, ab = a & 31;
  int br = (b >> 11) & 31, bg = (b >> 5) & 63, bb = b & 31;
  int r = ar + (int)((br - ar) * t + 0.5f), g = ag + (int)((bg - ag) * t + 0.5f), bl = ab + (int)((bb - ab) * t + 0.5f);
  return (uint16_t)((r << 11) | (g << 5) | bl);
}

void shapeRing(uint16_t* frame, int cx, int cy, int outerRadius, int thickness, float fraction, uint16_t from, uint16_t to, uint16_t track) {
  const float TWO_PI_F = 6.2831853f;
  const float glowReach = 13.0f, glowStrength = 0.34f;
  bool whole = fraction >= 0.999f;
  if (fraction < 0) fraction = 0;
  float sweep = whole ? TWO_PI_F : fraction * TWO_PI_F;
  float outer = outerRadius, inner = outerRadius - thickness, middle = outerRadius - thickness / 2.0f, half = thickness / 2.0f;
  // The round ends: one at twelve o'clock, one where the arc stops.
  float endX = cx + middle * sinf(sweep), endY = cy - middle * cosf(sweep);
  float startX = cx, startY = cy - middle;
  int reach = outerRadius + (int)glowReach + 1;
  float outerSquared = (outer + glowReach + 1) * (outer + glowReach + 1);
  float innerLimit = inner - glowReach - 1;
  float innerSquared = innerLimit > 0 ? innerLimit * innerLimit : 0;

  for (int py = cy - reach; py <= cy + reach; py++) {
    if (py < 0 || py >= LCD_H) continue;
    for (int px = cx - reach; px <= cx + reach; px++) {
      if (px < 0 || px >= LCD_W) continue;
      float dx = px + 0.5f - cx, dy = py + 0.5f - cy;
      float squared = dx * dx + dy * dy;
      if (squared > outerSquared || squared < innerSquared) continue;
      float d = sqrtf(squared);
      // How much of this pixel lies in the band of the ring, and how far outside the band it is.
      float band = min(outer - d + 0.5f, d - inner + 0.5f);
      float outside = d > outer ? d - outer : (d < inner ? inner - d : 0);

      // Where along the arc: 0 at twelve o'clock, growing clockwise.
      float angle = quickAtan2(dx, -dy);
      if (angle < 0) angle += TWO_PI_F;
      bool onArc = fraction > 0 && (whole || angle <= sweep);
      float along;   // 0…1 along the arc, for the colour
      float end = 0; // how much the round ends cover, when not on the arc itself
      float endGlow = 0;
      if (onArc) {
        along = whole ? (angle < 3.14159274f ? angle / 3.14159274f : (TWO_PI_F - angle) / 3.14159274f) : angle / sweep;
      } else if (fraction > 0) {
        float sx = px + 0.5f - startX, sy = py + 0.5f - startY, ex = px + 0.5f - endX, ey = py + 0.5f - endY;
        float toStart = sqrtf(sx * sx + sy * sy), toEnd = sqrtf(ex * ex + ey * ey);
        bool nearerStart = toStart < toEnd;
        float nearest = nearerStart ? toStart : toEnd;
        along = nearerStart ? 0 : 1;
        end = half + 0.5f - nearest;
        endGlow = 1.0f - (nearest - half) / glowReach;
      } else {
        along = 0;
      }

      uint16_t* at = frame + py * LCD_W + px;
      if (band > 0) {
        float cover = band > 1 ? 1 : band;
        // The track first, then the arc (or its round end) on top.
        uint8_t weight = (uint8_t)(cover * 32.0f + 0.5f);
        uint16_t under = weight >= 32 ? track : mix(*at, track, weight);
        float arc = onArc ? cover : (end > 0 ? min(end, cover) : 0);
        if (arc > 0) {
          uint8_t arcWeight = (uint8_t)((arc > 1 ? 1 : arc) * 32.0f + 0.5f);
          uint16_t color = between(from, to, along);
          under = arcWeight >= 32 ? color : mix(under, color, arcWeight);
        }
        *at = under;
      }
      // The glow: outside the band, fading with distance, only beside the arc.
      if (outside > 0 && fraction > 0) {
        float fade = 1.0f - outside / glowReach;
        if (!onArc) fade = min(fade, endGlow > 1 ? 1.0f : endGlow);
        if (fade > 0) {
          uint8_t weight = (uint8_t)(fade * fade * glowStrength * 32.0f + 0.5f);
          if (weight > 0) *at = mix(*at, between(from, to, along), weight);
        }
      }
    }
  }
}

void shapeDottedRing(uint16_t* frame, int cx, int cy, int outerRadius, int thickness, int dots, float dotRadius, uint16_t color, uint16_t track) {
  shapeRing(frame, cx, cy, outerRadius, thickness, 0, color, color, track);
  float middle = outerRadius - thickness / 2.0f;
  for (int i = 0; i < dots; i++) {
    float angle = 6.2831853f * i / dots;
    shapeDisc(frame, cx + middle * sinf(angle), cy - middle * cosf(angle), dotRadius, color);
  }
}
