# Notices

This firmware is part of RenderDock and is under RenderDock's MIT licence (see the `LICENSE` file at the top of the repository).

## The protocol

The wire protocol is the Hardware Buddy protocol of the Claude desktop apps, documented by Anthropic in
<https://github.com/anthropics/claude-desktop-buddy> (`REFERENCE.md`). That document says the protocol may be
implemented without anything from its repository. No code from that repository is included here.

## Board support

How this board is brought up — the order of initialisation, the display controller's orientation register, the
single-write frame push, the touch controller's address and mirroring, the power chip's set-up, and the shape of
the Bluetooth security set-up — follows the board support in
<https://github.com/vthinkxie/claude-desktop-buddy-esp32>, a port of Anthropic's reference firmware to Waveshare's
AMOLED boards. That project is distributed under the MIT licence with this notice:

> Copyright 2026 Anthropic, PBC.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
> documentation files (the "Software"), to deal in the Software without restriction, including without limitation
> the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
> to permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of
> the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
> THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
> TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

None of that project's artwork is used.

## Libraries

Fetched by PlatformIO at build time, each under its own licence: GFX Library for Arduino, SensorLib, XPowersLib,
ArduinoJson, U8g2, and Espressif's Arduino core for the ESP32 (LGPL 2.1, on Espressif's ESP-IDF, Apache License 2.0).

The program carries one of U8g2's fonts, `u8g2_font_wqy16_t_gb2312`, for the plain look a board without the font
file falls back to. It is WenQuanYi Bitmap Song. U8g2's font list gives it as: "Copyright: (C)2004-2010, WenQuanYi
Project Board of Trustees and Qianqian Fang", "License : GPL v2 (with font embedding exception)"
(<https://github.com/olikraus/u8g2/wiki/fntgrpwqy>). The complete source of this firmware is this repository.

## The playback chip

The order and values of the ES8311 codec's start-up registers in `src/sound.cpp` follow Espressif's driver for
it, <https://github.com/espressif/esp-bsp/tree/master/components/es8311> (Copyright 2015-2026 Espressif Systems
(Shanghai) CO LTD, Apache License 2.0). No file of that driver is included; the register sequence was written
out anew for this board's one use of the chip. The same goes for the ES7210 microphone chip, which only the
bring-up tests use: its start-up sequence follows <https://github.com/espressif/esp-bsp/tree/master/components/es7210>
(Copyright 2022 Espressif Systems (Shanghai) CO LTD, Apache License 2.0).

## Fonts

The fonts are not part of this repository; `tools/fetch-fonts.sh` fetches them, and a board that has been given
them carries drawings of their characters in its flash.

- **Source Han Sans** (Chinese text). Copyright 2014-2025 Adobe, with Reserved Font Name 'Source'. SIL Open Font
  License 1.1. <https://github.com/adobe-fonts/source-han-sans>
- **Nunito** (numerals and Latin). Copyright 2014 The Nunito Project Authors. SIL Open Font License 1.1.
  <https://github.com/googlefonts/nunito>
- **M PLUS Rounded 1c** (a second family for the numerals; the font file carries it, the screens do not use it
  unless switched from the bring-up console). Copyright 2016 The Rounded M+ Project Authors. SIL Open Font
  License 1.1, by the font's own licence field. <https://github.com/google/fonts/tree/main/ofl/mplusrounded1c>

Anyone who passes on a board, or a copy of its flash, with these characters in it passes on the fonts' licence
texts with it: `fonts/source-han-sans/LICENSE.txt` and `fonts/nunito/OFL.txt` after fetching.
`tools/make-image.sh` writes them, with the libraries' licences, into the text file that goes with the image.
