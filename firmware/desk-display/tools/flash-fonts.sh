#!/bin/sh
# Builds the file of drawn letters from the fetched fonts and writes it to the board's "fonts" part of the flash.
# Needed once, and again whenever the fonts or their sizes change; flashing the program does not touch it.
#
#   sh tools/flash-fonts.sh /dev/cu.usbmodem1101
set -eu
cd "$(dirname "$0")/.."
PORT=${1:?usage: sh tools/flash-fonts.sh PORT}
mkdir -p .pio
swiftc -O tools/make-fonts.swift -o .pio/make-fonts
.pio/make-fonts fonts .pio/fonts.bin
# 0x310000 is where partitions.csv puts "fonts".
"$HOME/.platformio/packages/tool-esptool/esptool" --chip esp32s3 --port "$PORT" --baud 921600 write-flash 0x310000 .pio/fonts.bin
