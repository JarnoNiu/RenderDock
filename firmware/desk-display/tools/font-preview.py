"""Draws lines of text from fonts.bin into a PNG, the way the firmware does, to check the file without a board.

  font-preview.py FONTS.bin OUT.png FACE[+FALLBACK]:TEXT [FACE[+FALLBACK]:TEXT …]

A character the first face lacks is looked for in the fallback face.
"""
import struct
import sys
import zlib


class Face:
    def __init__(self, blob, record):
        self.id, self.size, self.ascent, self.descent, self.count, self.index, self.data = struct.unpack('<HHhhIII', record)
        self.blob = blob

    def glyph(self, character):
        low, high = 0, self.count - 1
        while low <= high:
            middle = (low + high) // 2
            at = self.index + middle * 12
            code = struct.unpack_from('<H', self.blob, at)[0]
            if code == character:
                _, width, height, left, top, advance, _, offset = struct.unpack_from('<HBBbbBBI', self.blob, at)
                return width, height, left, top, advance, self.data + offset
            if code < character:
                low = middle + 1
            else:
                high = middle - 1
        return None


def load(path):
    blob = open(path, 'rb').read()
    assert blob[:4] == b'RDF1'
    count = struct.unpack_from('<H', blob, 4)[0]
    return {f.id: f for f in (Face(blob, blob[8 + 20 * i:28 + 20 * i]) for i in range(count))}


def main():
    faces = load(sys.argv[1])
    lines = []
    for item in sys.argv[3:]:
        spec, _, text = item.partition(':')
        ids = [int(x) for x in spec.split('+')]
        lines.append(([faces[i] for i in ids], text))
    width = 900
    height = sum(f[0].size + 22 for f, _ in lines) + 20
    canvas = [bytearray(width) for _ in range(height)]
    y = 10
    for chain, text in lines:
        baseline = y + chain[0].ascent
        pen = 12
        for character in text:
            found = None
            for face in chain:
                found = face.glyph(ord(character))
                if found:
                    break
            if not found:
                pen += chain[0].size // 2
                continue
            w, h, left, top, advance, at = found
            blob = chain[0].blob
            for row in range(h):
                for column in range(w):
                    n = row * w + column
                    value = blob[at + n // 2]
                    value = (value >> 4) if n % 2 == 0 else (value & 15)
                    px, py = pen + left + column, baseline - top + row
                    if 0 <= px < width and 0 <= py < height:
                        canvas[py][px] = max(canvas[py][px], value * 17)
            pen += advance
        y += chain[0].size + 22

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)

    body = b''.join(b'\x00' + bytes(row) for row in canvas)
    with open(sys.argv[2], 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 0, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(body, 6)) + chunk(b'IEND', b''))


main()
