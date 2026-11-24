#!/bin/sh
# Makes the one file a board can be flashed with from nothing: the start-up program, the layout of the flash, the
# program and the fonts, each where it belongs, to be written at address 0. This is the file a web flasher wants.
# Beside it goes a text file with the licences of everything the file carries, which travels with it.
#
#   sh tools/make-image.sh
#     -> .pio/renderdock-desk-display-<version>-esp32-s3-touch-amoled-2.16.bin
#     -> .pio/renderdock-desk-display-<version>-licences.txt
#
# Needs the fonts fetched first (tools/fetch-fonts.sh), and a Mac (the fonts are drawn with the system's own
# text drawing). Writing this file to a board empties what the board remembers: the computer it is paired with,
# its volume, its touch correction. A board that is already set up takes the program alone: `pio run -t upload`.
set -eu
cd "$(dirname "$0")/.."
PIO=${PIO:-$HOME/.platformio/penv/bin/pio}
ESPTOOL=${ESPTOOL:-$HOME/.platformio/packages/tool-esptool/esptool}
CORE=${CORE:-$HOME/.platformio/packages/framework-arduinoespressif32}
ENV=waveshare-s3-amoled-216
LIBS=.pio/libdeps/$ENV
VERSION=$(sed -n 's/^#define RD_VERSION "\(.*\)"$/\1/p' src/board.h)
[ -n "$VERSION" ] || { echo "no RD_VERSION in src/board.h" >&2; exit 1; }
OUT=.pio/renderdock-desk-display-$VERSION-esp32-s3-touch-amoled-2.16.bin
NOTES=.pio/renderdock-desk-display-$VERSION-licences.txt

PLATFORMIO_SETTING_ENABLE_TELEMETRY=no "$PIO" run -e "$ENV"
swiftc -O tools/make-fonts.swift -o .pio/make-fonts
.pio/make-fonts fonts .pio/fonts.bin

# The settings `pio run -t upload` writes with, and the addresses of partitions.csv.
"$ESPTOOL" --chip esp32s3 merge-bin -o "$OUT" --flash-mode dio --flash-freq 80m --flash-size 16MB \
  0x0 ".pio/build/$ENV/bootloader.bin" \
  0x8000 ".pio/build/$ENV/partitions.bin" \
  0xe000 "$CORE/tools/partitions/boot_app0.bin" \
  0x10000 ".pio/build/$ENV/firmware.bin" \
  0x310000 .pio/fonts.bin

# A file that is passed on carries no one's user name.
if LC_ALL=C grep -a -q -e "$(basename "$HOME")" "$OUT"; then
  echo "$OUT carries this computer's user name: not for passing on" >&2
  exit 1
fi

part() { printf '\n\n======== %s ========\n\n' "$1" >> "$NOTES"; }
{
  echo "RenderDock desk display $VERSION, for the Waveshare ESP32-S3-Touch-AMOLED-2.16"
  echo "Licences of what the firmware file carries. Source: https://github.com/JarnoNiu/RenderDock (firmware/desk-display)"
} > "$NOTES"
part "RenderDock (the firmware itself): MIT"; cat ../../LICENSE >> "$NOTES"
part "Notices"; cat NOTICE.md >> "$NOTES"
part "Source Han Sans: SIL Open Font License 1.1"; cat fonts/source-han-sans/LICENSE.txt >> "$NOTES"
part "Nunito: SIL Open Font License 1.1"; cat fonts/nunito/OFL.txt >> "$NOTES"
part "M PLUS Rounded 1c: SIL Open Font License 1.1"
{
  echo "Copyright 2016 The Rounded M+ Project Authors."
  echo "This Font Software is licensed under the SIL Open Font License, Version 1.1 (the font's own licence field)."
  echo "The text of that licence is the one printed above for Nunito, from 'This license is copied below' on."
} >> "$NOTES"
part "ArduinoJson"; cat "$LIBS/ArduinoJson/LICENSE.txt" >> "$NOTES"
part "SensorLib"; cat "$LIBS/SensorLib/LICENSE" >> "$NOTES"
part "XPowersLib"; cat "$LIBS/XPowersLib/LICENSE" >> "$NOTES"
part "U8g2 (and the fonts it carries)"; cat "$LIBS/U8g2/LICENSE" >> "$NOTES"

ls -l "$OUT" "$NOTES"
shasum -a 256 "$OUT"
