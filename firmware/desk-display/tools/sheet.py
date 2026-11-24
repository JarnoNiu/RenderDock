"""Puts board frames side by side: sheet.py OUT.png COLUMNS IN.png [IN.png …]

Reads plain 480 x 480 PNG files (8 bits a channel, RGB or RGBA), so it needs nothing installed.
"""
import struct
import sys
import zlib

SIZE = 480
GAP = 12


def read(path):
    """A PNG as rows of RGB bytes: 8 bits a channel, RGB or RGBA, not interlaced (what console.py and a browser write)."""
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
    if (width, height) != (SIZE, SIZE) or depth != 8 or colour not in (2, 6) or interlace:
        raise SystemExit('%s: not a plain %d x %d PNG' % (path, SIZE, SIZE))
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
        previous = line
        rows.append(bytes(line) if size == 3 else bytes(v for i, v in enumerate(line) if i % 4 != 3))
    return rows


def main():
    out, columns, files = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
    count = (len(files) + columns - 1) // columns
    width = columns * SIZE + (columns + 1) * GAP
    height = count * SIZE + (count + 1) * GAP
    grey = bytes((40, 40, 40))
    canvas = [bytearray(grey * width) for _ in range(height)]
    for i, name in enumerate(files):
        x = GAP + (i % columns) * (SIZE + GAP)
        y = GAP + (i // columns) * (SIZE + GAP)
        for row, pixels in enumerate(read(name)):
            canvas[y + row][x * 3:(x + SIZE) * 3] = pixels

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)

    body = b''.join(b'\x00' + bytes(row) for row in canvas)
    with open(out, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(body, 6)) + chunk(b'IEND', b''))


main()
