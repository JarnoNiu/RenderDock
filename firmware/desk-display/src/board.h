// Pins of the Waveshare ESP32-S3-Touch-AMOLED-2.16, from Waveshare's own pin table.
#pragma once

// The version of this firmware; it follows RenderDock's own.
#define RD_VERSION "0.3.0"

#define LCD_W 480
#define LCD_H 480

// AMOLED, CO5300 over QSPI
#define PIN_LCD_SDIO0 4
#define PIN_LCD_SDIO1 5
#define PIN_LCD_SDIO2 6
#define PIN_LCD_SDIO3 7
#define PIN_LCD_SCLK 38
#define PIN_LCD_CS 12
#define PIN_LCD_RESET 39
// The panel is mounted a quarter turn from its natural orientation. MV + MY puts the picture upright.
#define LCD_MADCTL 0xA0

// One I2C bus for touch, power chip, IMU, RTC and the audio codec
#define PIN_I2C_SDA 15
#define PIN_I2C_SCL 14

// Touch, CST9220
#define PIN_TP_INT 11
#define PIN_TP_RESET 40
#define TP_ADDRESS 0x5A

// Keys. They never approve anything.
// The power key is the power chip's own; this pin (the schematic's "SYS_OUT") follows it: high while it is held.
// What the key did, a short press or a long one, is asked of the chip (hw.cpp).
#define PIN_KEY_PWR 16   // active high
#define PIN_KEY_USER 18  // active low
#define PIN_KEY_BOOT 0   // active low

// Sound: the ES8311 codec and an NS4150B amplifier, whose output goes to a socket for a speaker (P10); and,
// sharing the codec's clocks, the ES7210 for the two microphones, which only the bring-up tests use. The codec's
// analogue side is fed by the power chip's ALDO1.
#define PIN_I2S_MCLK 42
#define PIN_I2S_BCLK 9
#define PIN_I2S_LRCK 45
#define PIN_I2S_TO_CODEC 8      // samples to play
#define PIN_I2S_FROM_MICS 10    // not used
#define PIN_AUDIO_AMP 46        // the amplifier's switch: high is on
