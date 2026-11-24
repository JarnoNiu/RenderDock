// Playback through the board's ES8311 codec and its small amplifier.
//
// The order and values of the codec's start-up registers follow Espressif's own driver for it
// (github.com/espressif/esp-bsp, components/es8311, Apache-2.0); see NOTICE.md. The codec takes its clocks from
// this chip: a master clock of 256 times the sample rate, and 16-bit samples.
#include "sound.h"
#include "board.h"
#include <ESP_I2S.h>
#include <Wire.h>

static const int RATE = 16000;
static const uint8_t CODEC = 0x18;

static I2SClass s_i2s;
static bool s_ready = false;
static QueueHandle_t s_queue = nullptr;
// 55 was tried first and was hard to hear from a chair; 70 is what its owner picked out of 55, 70 and 85.
static int s_volume = 70;

static bool codecWrite(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(CODEC);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

static int codecRead(uint8_t reg) {
  Wire.beginTransmission(CODEC);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return -1;
  if (Wire.requestFrom((int)CODEC, 1) != 1) return -1;
  return Wire.read();
}

static bool codecBegin() {
  // Back to its defaults, then on.
  if (!codecWrite(0x00, 0x1F)) return false;
  delay(20);
  codecWrite(0x00, 0x00);
  codecWrite(0x00, 0x80);
  // Clocks: all on, the master clock from its pin, none inverted; dividers for 4.096 MHz and 16 kHz.
  codecWrite(0x01, 0x3F);
  codecWrite(0x02, (uint8_t)(codecRead(0x02) & 0x07));
  codecWrite(0x03, 0x10);
  codecWrite(0x04, 0x10);
  codecWrite(0x05, 0x00);
  codecWrite(0x06, (uint8_t)((codecRead(0x06) & 0xC0) | 0x03));
  codecWrite(0x07, (uint8_t)(codecRead(0x07) & 0xC0));
  codecWrite(0x08, 0xFF);
  // It follows this chip's clocks; 16-bit samples in and out.
  codecWrite(0x00, (uint8_t)(codecRead(0x00) & 0xBF));
  codecWrite(0x09, 0x0C);
  codecWrite(0x0A, 0x0C);
  // The analogue side, the converter and its output; no equaliser.
  codecWrite(0x0D, 0x01);
  codecWrite(0x0E, 0x02);
  codecWrite(0x12, 0x00);
  codecWrite(0x13, 0x10);
  codecWrite(0x1C, 0x6A);
  codecWrite(0x37, 0x08);
  return true;
}

void soundVolume(int percent) {
  s_volume = constrain(percent, 0, 100);
  // The codec's own scale: 0 is silence, 191 is "as recorded", half a decibel a step. Its top quarter is
  // amplification, which a notification has no use for, so 100 here stops at "as recorded".
  if (s_ready) codecWrite(0x32, (uint8_t)(s_volume == 0 ? 0 : 71 + s_volume * 120 / 100));
}

int soundVolumeNow() { return s_volume; }

// A note: how high, how long, how strong (0…1), and how long to wait after it starts before the next one starts.
struct Note {
  float hertz;
  uint16_t ms;
  float strength;
  uint16_t nextAfterMs;
};

static const Note REQUEST[] = {{659.3f, 150, 0.9f, 130}, {880.0f, 260, 1.0f, 0}};
static const Note WAITING[] = {{587.3f, 280, 0.6f, 0}};
static const Note DONE[] = {{523.3f, 140, 0.8f, 110}, {659.3f, 140, 0.8f, 110}, {784.0f, 320, 0.9f, 0}};
// The small speaker does little below 500 Hz and most around 900 (heard through the board's own microphones),
// so "failed" stays above that, and the tick is short but not faint.
static const Note FAILED[] = {{659.3f, 200, 0.9f, 180}, {493.9f, 340, 1.0f, 0}};
static const Note TAP[] = {{987.8f, 70, 1.0f, 0}};

struct Tune {
  const Note* notes;
  int count;
};
static const Tune TUNES[SOUND_COUNT] = {{REQUEST, 2}, {WAITING, 1}, {DONE, 3}, {FAILED, 2}, {TAP, 1}};

// The amplifier (an NS4150B) is kept off when there is nothing to hear: left on, it hisses. Switched on, it
// takes about a fifth of a second before anything comes out of it; measured on the board, with its own
// microphones, at 190 to 200 ms. A sound sent sooner is simply lost, and these sounds are short and loudest at
// the start, so every one of them begins with this much silence.
static const uint32_t AMPLIFIER_WAKES_MS = 220;

// Works a tune out: 16-bit samples, left and right the same, after the silence the amplifier needs. Each note is
// a sine with a little of its octave, coming in over a few milliseconds and dying away, so that it sounds struck
// rather than switched on. The caller frees the result.
static int16_t* renderTune(const Tune& tune, uint32_t& samples) {
  uint32_t total = 0, start = 0;
  for (int i = 0; i < tune.count; i++) {
    total = max(total, start + tune.notes[i].ms);
    start += tune.notes[i].nextAfterMs;
  }
  uint32_t lead = AMPLIFIER_WAKES_MS * RATE / 1000;
  samples = lead + total * RATE / 1000 + RATE / 25;   // and a moment of silence to finish on
  int16_t* buffer = (int16_t*)ps_malloc(samples * 2 * sizeof(int16_t));
  if (!buffer) return nullptr;
  memset(buffer, 0, samples * 2 * sizeof(int16_t));
  start = 0;
  for (int i = 0; i < tune.count; i++) {
    const Note& note = tune.notes[i];
    uint32_t first = lead + start * RATE / 1000, length = (uint32_t)note.ms * RATE / 1000;
    float step = 6.2831853f * note.hertz / RATE, fade = 4.0f / length;   // dies away to a fiftieth by its end
    for (uint32_t n = 0; n < length && first + n < samples; n++) {
      float attack = n < 96 ? n / 96.0f : 1.0f;
      float value = (sinf(step * n) + 0.18f * sinf(2 * step * n)) * attack * expf(-fade * n) * note.strength * 9000.0f;
      int32_t mixed = buffer[(first + n) * 2] + (int32_t)value;
      mixed = mixed > 32000 ? 32000 : (mixed < -32000 ? -32000 : mixed);
      buffer[(first + n) * 2] = buffer[(first + n) * 2 + 1] = (int16_t)mixed;
    }
    start += note.nextAfterMs;
  }
  return buffer;
}

static void play(const Tune& tune) {
  uint32_t samples = 0;
  int16_t* buffer = renderTune(tune, samples);
  if (!buffer) return;
  digitalWrite(PIN_AUDIO_AMP, HIGH);
  s_i2s.write((const uint8_t*)buffer, samples * 2 * sizeof(int16_t));
  vTaskDelay(pdMS_TO_TICKS(80));
  digitalWrite(PIN_AUDIO_AMP, LOW);
  free(buffer);
}

static void soundTask(void*) {
  for (;;) {
    int which = 0;
    if (xQueueReceive(s_queue, &which, portMAX_DELAY) == pdTRUE && which >= 0 && which < SOUND_COUNT) play(TUNES[which]);
  }
}

bool soundBegin() {
  pinMode(PIN_AUDIO_AMP, OUTPUT);
  digitalWrite(PIN_AUDIO_AMP, LOW);
  s_i2s.setPins(PIN_I2S_BCLK, PIN_I2S_LRCK, PIN_I2S_TO_CODEC, -1, PIN_I2S_MCLK);
  if (!s_i2s.begin(I2S_MODE_STD, RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO)) return false;
  if (!codecBegin()) return false;
  s_ready = true;
  soundVolume(s_volume);
  s_queue = xQueueCreate(4, sizeof(int));
  xTaskCreate(soundTask, "sound", 4096, nullptr, 2, nullptr);
  return true;
}

void soundPlay(Sound sound) {
  if (!s_ready || !s_queue) return;
  int which = (int)sound;
  xQueueSend(s_queue, &which, 0);
}

#if RD_DEBUG_SERIAL
// The microphone chip (ES7210), set up after Espressif's driver for it (github.com/espressif/esp-bsp,
// components/es7210, Apache-2.0): 16 kHz from a 4.096 MHz master clock, 16 bits, all four inputs in one frame.
static const uint8_t MICS = 0x40;
static void micsWrite(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(MICS);
  Wire.write(reg);
  Wire.write(value);
  Wire.endTransmission();
}

static void micsBegin(bool fourInOneFrame) {
  micsWrite(0x00, 0xFF);
  micsWrite(0x00, 0x32);
  micsWrite(0x09, 0x30);
  micsWrite(0x0A, 0x30);
  micsWrite(0x23, 0x2A);
  micsWrite(0x22, 0x0A);
  micsWrite(0x21, 0x2A);
  micsWrite(0x20, 0x0A);
  micsWrite(0x11, 0x60);   // 16 bits, I2S
  micsWrite(0x12, fourInOneFrame ? 0x02 : 0x00);   // all four inputs in one frame, or just the two microphones
  micsWrite(0x40, 0xC3);
  micsWrite(0x41, 0x70);
  micsWrite(0x42, 0x70);
  for (uint8_t reg = 0x43; reg <= 0x46; reg++) micsWrite(reg, 0x10 | 10);   // 30 dB
  for (uint8_t reg = 0x47; reg <= 0x4A; reg++) micsWrite(reg, 0x08);
  micsWrite(0x07, 0x20);
  micsWrite(0x02, 0xC1);
  micsWrite(0x04, 0x01);
  micsWrite(0x05, 0x00);
  micsWrite(0x06, 0x04);
  micsWrite(0x4B, 0x0F);
  micsWrite(0x4C, 0x0F);
  micsWrite(0x00, 0x71);
  micsWrite(0x00, 0x41);
}

// Plays `amplitude` of a 1 kHz tone for about 0.7 s in every slot of the frame while recording the four slots,
// and prints, for each slot, how loud it was overall and how much of that was the tone.
static void listenOnce(const char* label, int amplitude, bool amplifier) {
  const int CHUNK = 256, CHUNKS = 44, SKIP = 14;   // frames a piece; pieces; pieces left out while things settle
  static int16_t out[CHUNK * 4], in[CHUNK * 4];
  double energy[4] = {0, 0, 0, 0}, real[4] = {0, 0, 0, 0}, imaginary[4] = {0, 0, 0, 0};
  uint32_t counted = 0, n = 0;
  digitalWrite(PIN_AUDIO_AMP, amplifier ? HIGH : LOW);
  for (int chunk = 0; chunk < CHUNKS; chunk++) {
    for (int i = 0; i < CHUNK; i++, n++) {
      int16_t value = (int16_t)(amplitude * sinf(6.2831853f * 1000.0f * n / RATE));
      out[i * 4] = out[i * 4 + 1] = out[i * 4 + 2] = out[i * 4 + 3] = value;
    }
    s_i2s.write((const uint8_t*)out, sizeof(out));
    size_t got = s_i2s.readBytes((char*)in, sizeof(in));
    if (chunk < SKIP) continue;
    for (size_t i = 0; i + 3 < got / 2; i += 4, counted++) {
      float c = cosf(6.2831853f * 1000.0f * counted / RATE), s = sinf(6.2831853f * 1000.0f * counted / RATE);
      for (int slot = 0; slot < 4; slot++) {
        double v = in[i + slot];
        energy[slot] += v * v;
        real[slot] += v * c;
        imaginary[slot] += v * s;
      }
    }
  }
  digitalWrite(PIN_AUDIO_AMP, LOW);
  Serial.printf("listen: %s:", label);
  for (int slot = 0; slot < 4; slot++) {
    double level = counted ? sqrt(energy[slot] / counted) : 0;
    double tone = counted ? 2.0 * sqrt(real[slot] * real[slot] + imaginary[slot] * imaginary[slot]) / counted / 1.41421356 : 0;
    Serial.printf("  slot %d level %.0f tone %.0f", slot, level, tone);
  }
  Serial.printf("  (%lu frames)\n", (unsigned long)counted);
}

// Switches the amplifier on while a quiet tone is already playing, and prints how loud the first microphone
// hears it, 16 ms at a time: how long the amplifier takes to wake.
static void wakeTime() {
  const int CHUNK = 256;
  static int16_t out[CHUNK * 4], in[CHUNK * 4];
  uint32_t n = 0;
  Serial.print("wake: level each 16 ms after switching the amplifier on:");
  for (int chunk = 0; chunk < 34; chunk++) {
    if (chunk == 4) digitalWrite(PIN_AUDIO_AMP, HIGH);
    for (int i = 0; i < CHUNK; i++, n++) {
      int16_t value = (int16_t)(2500 * sinf(6.2831853f * 1000.0f * n / RATE));
      out[i * 4] = out[i * 4 + 1] = out[i * 4 + 2] = out[i * 4 + 3] = value;
    }
    s_i2s.write((const uint8_t*)out, sizeof(out));
    size_t got = s_i2s.readBytes((char*)in, sizeof(in));
    double energy = 0;
    uint32_t count = 0;
    for (size_t i = 0; i + 3 < got / 2; i += 4, count++) energy += (double)in[i] * in[i];
    if (chunk >= 4) Serial.printf(" %.0f", count ? sqrt(energy / count) : 0);
  }
  digitalWrite(PIN_AUDIO_AMP, LOW);
  Serial.println();
}

void soundSelfTest() {
  if (!s_ready) {
    Serial.println("listen: the playback chip is not running");
    return;
  }
  // The same wires, with the microphone chip's data line added and four slots to a frame.
  s_i2s.end();
  s_i2s.setPins(PIN_I2S_BCLK, PIN_I2S_LRCK, PIN_I2S_TO_CODEC, PIN_I2S_FROM_MICS, PIN_I2S_MCLK);
  if (!s_i2s.begin(I2S_MODE_TDM, RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO, 0x0F)) {
    Serial.println("listen: the four-slot mode did not start");
  } else {
    micsBegin(true);
    delay(120);
    // Quiet: enough for the microphones, which sit right beside the speaker, and not much more.
    int before = s_volume;
    soundVolume(55);
    listenOnce("silence", 0, false);
    listenOnce("tone, amplifier off", 2500, false);
    listenOnce("tone, amplifier on", 2500, true);
    delay(300);
    wakeTime();
    soundVolume(before);
  }
  // Back to how sounds are normally played.
  s_i2s.end();
  s_i2s.setPins(PIN_I2S_BCLK, PIN_I2S_LRCK, PIN_I2S_TO_CODEC, -1, PIN_I2S_MCLK);
  s_i2s.begin(I2S_MODE_STD, RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO);
}

// Plays one of the sounds exactly as it is normally played, while the first microphone listens, and prints how
// loud it heard each 16 ms: the shape of the sound as it left the speaker.
void soundHear(int which) {
  if (!s_ready || which < 0 || which >= SOUND_COUNT) return;
  s_i2s.end();
  s_i2s.setPins(PIN_I2S_BCLK, PIN_I2S_LRCK, PIN_I2S_TO_CODEC, PIN_I2S_FROM_MICS, PIN_I2S_MCLK);
  if (s_i2s.begin(I2S_MODE_STD, RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO)) {
    micsBegin(false);
    delay(150);
    uint32_t samples = 0;
    int16_t* buffer = renderTune(TUNES[which], samples);
    if (buffer) {
      const uint32_t CHUNK = 256;
      static int16_t in[CHUNK * 2];
      Serial.printf("hear: sound %d, level each 16 ms:", which);
      digitalWrite(PIN_AUDIO_AMP, HIGH);
      for (uint32_t at = 0; at < samples; at += CHUNK) {
        uint32_t n = min(CHUNK, samples - at);
        s_i2s.write((const uint8_t*)(buffer + at * 2), n * 2 * sizeof(int16_t));
        size_t got = s_i2s.readBytes((char*)in, n * 2 * sizeof(int16_t));
        double energy = 0;
        uint32_t count = 0;
        for (size_t i = 0; i + 1 < got / 2; i += 2, count++) energy += (double)in[i] * in[i];
        Serial.printf(" %.0f", count ? sqrt(energy / count) : 0);
      }
      delay(80);
      digitalWrite(PIN_AUDIO_AMP, LOW);
      Serial.println();
      free(buffer);
    }
  }
  s_i2s.end();
  s_i2s.setPins(PIN_I2S_BCLK, PIN_I2S_LRCK, PIN_I2S_TO_CODEC, -1, PIN_I2S_MCLK);
  s_i2s.begin(I2S_MODE_STD, RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO);
}
#endif
