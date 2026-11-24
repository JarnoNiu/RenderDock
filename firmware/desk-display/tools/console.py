"""Talks to the desk display's bring-up console over USB, in one sitting.

Only the `debug` build has the console (pio run -e debug -t upload). Opening the port the usual way resets
the board, so everything for one test happens inside a single run:

  console.py PORT STEP [STEP …]          PORT is the board's serial port, e.g. /dev/cu.usbmodem1101

  noreset             as the first step: open the port without resetting the board, to look at it as it is

  wait:SECONDS        print what the board says for that long
  send:LINE           send one line (see the console's commands in src/main.cpp)
  sendfile:PATH       send the contents of a file as one line
  shot:OUT.png        save the frame the board has drawn
  image:FILE.png:SECONDS   show a 480 x 480 PNG on the panel for that long (a touch ends it sooner)
  until:SECONDS:TEXT  print what the board says as it comes, until a line contains TEXT. If SECONDS pass
                      first, stop there and skip the remaining steps (so a later `shot` is not taken blind)

Needs pyserial; PlatformIO's own Python has it:  ~/.platformio/penv/bin/python console.py …
"""
import struct
import sys
import time
import zlib

import serial


def png(path, width, height, pixels):
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            v = pixels[(y * width + x) * 2] | (pixels[(y * width + x) * 2 + 1] << 8)
            r, g, b = (v >> 11) & 0x1F, (v >> 5) & 0x3F, v & 0x1F
            rows += bytes(((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + chunk(b'IEND', b''))
    return sum(1 for b in pixels if b)


def read_png(path):
    """A PNG as rows of RGB bytes. Enough of the format for a screenshot: 8 bits a channel, RGB or RGBA, not interlaced."""
    data = open(path, 'rb').read()
    position, raw, header = 8, b'', None
    while position < len(data):
        length, kind = struct.unpack('>I4s', data[position:position + 8])
        body = data[position + 8:position + 8 + length]
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            raw += body
        position += 12 + length
    width, height, depth, colour, _, _, interlace = header
    if depth != 8 or colour not in (2, 6) or interlace:
        raise SystemExit('image: only plain 8-bit RGB or RGBA PNG files are read here')
    size = 4 if colour == 6 else 3
    stride = width * size
    data = zlib.decompress(raw)
    rows, previous = [], bytearray(stride)
    for y in range(height):
        kind = data[y * (stride + 1)]
        line = bytearray(data[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            left = line[i - size] if i >= size else 0
            up = previous[i]
            corner = previous[i - size] if i >= size else 0
            if kind == 1:
                line[i] = (line[i] + left) & 255
            elif kind == 2:
                line[i] = (line[i] + up) & 255
            elif kind == 3:
                line[i] = (line[i] + (left + up) // 2) & 255
            elif kind == 4:
                p = left + up - corner
                a, b, c = abs(p - left), abs(p - up), abs(p - corner)
                line[i] = (line[i] + (left if a <= b and a <= c else up if b <= c else corner)) & 255
        rows.append(line)
        previous = line
    return width, height, size, rows


def frame_bytes(path):
    """The picture as the panel takes it: 16 bits a pixel, low byte first."""
    width, height, size, rows = read_png(path)
    if (width, height) != (480, 480):
        raise SystemExit('image: the picture must be 480 x 480, this one is %d x %d' % (width, height))
    out = bytearray()
    for line in rows:
        for x in range(width):
            r, g, b = line[x * size], line[x * size + 1], line[x * size + 2]
            v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
            out += bytes((v & 255, v >> 8))
    return bytes(out)


def show(text):
    for line in text.decode('utf-8', 'replace').splitlines():
        if line.strip():
            print('  |', line[:200])


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    s = serial.Serial()
    s.port = sys.argv[1]
    s.baudrate = 115200
    s.timeout = 0.2
    steps = sys.argv[2:]
    # The board resets when the port is opened with these two lines dropped one after the other, which is what
    # happens when they are set to False. Leaving both raised opens it without a reset.
    keep = steps[0] == 'noreset'
    if keep:
        steps = steps[1:]
    s.dtr = keep
    s.rts = keep
    s.open()
    for step in steps:
        kind, _, arg = step.partition(':')
        if kind == 'wait':
            end = time.time() + float(arg)
            text = b''
            while time.time() < end:
                text += s.read(4096)
            show(text)
        elif kind == 'image':
            path, _, seconds = arg.rpartition(':')
            frame = frame_bytes(path)
            s.read(65536)
            s.write(('image %s\n' % seconds).encode())
            s.flush()
            time.sleep(0.05)
            # In small pieces with a breath between them: the board drops what arrives faster than it can take.
            for offset in range(0, len(frame), 1024):
                s.write(frame[offset:offset + 1024])
                s.flush()
                time.sleep(0.004)
            answer, end = b'', time.time() + 4
            while time.time() < end and b'image ' not in answer:
                answer += s.read(4096)
            show(answer)
        elif kind == 'until':
            seconds, _, wanted = arg.partition(':')
            end = time.time() + float(seconds)
            pending = b''
            found = False
            while time.time() < end and not found:
                pending += s.read(4096)
                while b'\n' in pending and not found:
                    line, _, pending = pending.partition(b'\n')
                    text = line.decode('utf-8', 'replace').rstrip()
                    if text.strip():
                        print(time.strftime('%H:%M:%S'), ' |', text[:200], flush=True)
                    found = wanted in text
            if not found:
                print('gave up waiting for:', wanted, flush=True)
                break
        elif kind in ('send', 'sendfile'):
            line = open(arg, encoding='utf-8').read().strip() if kind == 'sendfile' else arg
            s.write(line.encode('utf-8') + b'\n')
            s.flush()
        elif kind == 'shot':
            before = s.read(65536)
            show(before)
            s.write(b'shot\n')
            s.flush()
            buffer = b''
            header = None
            end = time.time() + 20
            while time.time() < end:
                buffer += s.read(65536)
                if header is None:
                    i = buffer.find(b'SHOT ')
                    j = buffer.find(b'\n', i) if i >= 0 else -1
                    if i >= 0 and j >= 0:
                        show(buffer[:i])
                        header = buffer[i:j].split()
                        buffer = buffer[j + 1:]
                if header is not None and len(buffer) >= int(header[3]):
                    break
            if header is None:
                print('no frame came back for', arg)
                show(buffer[:400])
                continue
            width, height, size = int(header[1]), int(header[2]), int(header[3])
            lit = png(arg, width, height, buffer[:size])
            print('saved', arg.split('/')[-1], width, 'x', height, 'non-zero bytes', lit)
    s.close()


main()
