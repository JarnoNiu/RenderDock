#include "font.h"
#include "board.h"
#include <esp_partition.h>

// The layout of the file is described at the top of tools/make-fonts.swift.
struct __attribute__((packed)) FaceRecord {
  uint16_t id, size;
  int16_t ascent, descent;
  uint32_t count, index, data;
};
struct __attribute__((packed)) GlyphRecord {
  uint16_t character;
  uint8_t width, height;
  int8_t left, top;
  uint8_t advance, unused;
  uint32_t offset;
};

static const uint8_t* s_file = nullptr;
static const FaceRecord* s_faces = nullptr;
static uint16_t s_faceCount = 0;

bool fontBegin() {
  const esp_partition_t* part = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, "fonts");
  if (!part) return false;
  const void* mapped = nullptr;
  esp_partition_mmap_handle_t handle;
  if (esp_partition_mmap(part, 0, part->size, ESP_PARTITION_MMAP_DATA, &mapped, &handle) != ESP_OK) return false;
  const uint8_t* file = (const uint8_t*)mapped;
  if (memcmp(file, "RDF1", 4) != 0) return false;
  s_faceCount = file[4] | (file[5] << 8);
  if (s_faceCount == 0 || s_faceCount > 64) return false;
  s_faces = (const FaceRecord*)(file + 8);
  s_file = file;
  return true;
}

bool fontReady() { return s_file != nullptr; }

static const FaceRecord* faceOf(uint16_t id) {
  for (uint16_t i = 0; i < s_faceCount; i++) {
    if (s_faces[i].id == id) return &s_faces[i];
  }
  return nullptr;
}

bool fontHas(uint16_t face) { return s_file != nullptr && faceOf(face) != nullptr; }

static const GlyphRecord* glyphIn(const FaceRecord* face, uint16_t character) {
  if (!face) return nullptr;
  const GlyphRecord* index = (const GlyphRecord*)(s_file + face->index);
  int32_t low = 0, high = (int32_t)face->count - 1;
  while (low <= high) {
    int32_t middle = (low + high) / 2;
    uint16_t at = index[middle].character;
    if (at == character) return &index[middle];
    if (at < character) low = middle + 1;
    else high = middle - 1;
  }
  return nullptr;
}

// The glyph for a character and the face it came from. Letters and digits try the rounded face first. A
// character nobody has is shown as a hollow box rather than left out without a trace.
static const GlyphRecord* glyphFor(TextStyle style, uint16_t character, const FaceRecord** from) {
  const FaceRecord* text = faceOf(style.text);
  if (style.latin != 0 && character < 0x2E80) {
    const FaceRecord* latin = faceOf(style.latin);
    const GlyphRecord* g = glyphIn(latin, character);
    if (g) {
      *from = latin;
      return g;
    }
  }
  *from = text;
  const GlyphRecord* g = glyphIn(text, character);
  if (!g) g = glyphIn(text, 0x25A1);
  return g;
}

// The next character of a UTF-8 text; 0 at its end. Characters beyond the first 65,536 come out as a box.
static uint16_t nextCharacter(const char*& p) {
  uint8_t c = (uint8_t)*p;
  if (c == 0) return 0;
  if (c < 0x80) {
    p++;
    return c;
  }
  int extra = (c & 0xE0) == 0xC0 ? 1 : (c & 0xF0) == 0xE0 ? 2 : (c & 0xF8) == 0xF0 ? 3 : 0;
  uint32_t value = extra == 1 ? (c & 0x1F) : extra == 2 ? (c & 0x0F) : (c & 0x07);
  p++;
  for (int i = 0; i < extra && ((uint8_t)*p & 0xC0) == 0x80; i++, p++) value = (value << 6) | ((uint8_t)*p & 0x3F);
  return extra == 0 || value > 0xFFFF ? 0x25A1 : (uint16_t)value;
}

int fontWidth(TextStyle style, const char* utf8) {
  if (!s_file) return 0;
  int width = 0;
  const char* p = utf8;
  while (uint16_t character = nextCharacter(p)) {
    const FaceRecord* from = nullptr;
    const GlyphRecord* g = glyphFor(style, character, &from);
    if (g) width += g->advance;
  }
  return width;
}

// Sixteen levels of grey as a weight out of 32.
static const uint8_t WEIGHT[16] = {0, 2, 4, 6, 9, 11, 13, 15, 17, 19, 21, 23, 26, 28, 30, 32};

// One colour over another, both 5-6-5, by a weight out of 32.
static inline uint16_t mix(uint16_t under, uint16_t over, uint8_t weight) {
  uint32_t u = (under | ((uint32_t)under << 16)) & 0x07E0F81F;
  uint32_t o = (over | ((uint32_t)over << 16)) & 0x07E0F81F;
  uint32_t r = (u + (((o - u) * weight) >> 5)) & 0x07E0F81F;
  return (uint16_t)(r | (r >> 16));
}

void fontDraw(uint16_t* frame, TextStyle style, int x, int baseline, uint16_t color, const char* utf8) {
  if (!s_file) return;
  const char* p = utf8;
  while (uint16_t character = nextCharacter(p)) {
    const FaceRecord* from = nullptr;
    const GlyphRecord* g = glyphFor(style, character, &from);
    if (!g) continue;
    const uint8_t* pixels = s_file + from->data + g->offset;
    int left = x + g->left, top = baseline - g->top;
    for (int row = 0; row < g->height; row++) {
      int y = top + row;
      if (y < 0 || y >= LCD_H) continue;
      uint16_t* line = frame + y * LCD_W;
      uint32_t n = (uint32_t)row * g->width;
      for (int column = 0; column < g->width; column++, n++) {
        uint8_t value = pixels[n >> 1];
        value = (n & 1) ? (value & 15) : (value >> 4);
        if (value == 0) continue;
        int px = left + column;
        if (px < 0 || px >= LCD_W) continue;
        line[px] = value == 15 ? color : mix(line[px], color, WEIGHT[value]);
      }
    }
    x += g->advance;
  }
}

void fontDrawCentred(uint16_t* frame, TextStyle style, int centreX, int baseline, uint16_t color, const char* utf8) {
  fontDraw(frame, style, centreX - fontWidth(style, utf8) / 2, baseline, color, utf8);
}

void fontDrawRight(uint16_t* frame, TextStyle style, int rightX, int baseline, uint16_t color, const char* utf8) {
  fontDraw(frame, style, rightX - fontWidth(style, utf8), baseline, color, utf8);
}

// Where each character of a text starts, so that it can be cut between characters.
static int characterStarts(const char* utf8, uint16_t* starts, int max) {
  int count = 0;
  const char* p = utf8;
  while (*p && count < max) {
    starts[count++] = (uint16_t)(p - utf8);
    nextCharacter(p);
  }
  return count;
}

String fontFit(TextStyle style, const char* utf8, int maxWidth, bool keepEnd) {
  String whole = utf8;
  if (fontWidth(style, utf8) <= maxWidth) return whole;
  static uint16_t starts[160];
  int count = characterStarts(utf8, starts, 160);
  int length = strlen(utf8);
  if (!keepEnd) {
    for (int keep = count - 1; keep > 0; keep--) {
      String cut = whole.substring(0, starts[keep]) + "…";
      if (fontWidth(style, cut.c_str()) <= maxWidth) return cut;
    }
    return "…";
  }
  // Take characters away from the middle, a little more from the front half than the back.
  for (int drop = 1; drop < count - 1; drop++) {
    int tail = max(1, (count - drop) * 2 / 5);
    int head = count - drop - tail;
    if (head < 1) break;
    String cut = whole.substring(0, starts[head]) + "…" + whole.substring(starts[count - tail], length);
    if (fontWidth(style, cut.c_str()) <= maxWidth) return cut;
  }
  return "…";
}
