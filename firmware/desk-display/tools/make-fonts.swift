// Turns the fetched font files into the one file of drawn letters the desk display reads (fonts.bin).
//
//   swiftc -O tools/make-fonts.swift -o .pio/make-fonts && .pio/make-fonts fonts .pio/fonts.bin
//
// The device has no way to draw a font file itself, so every character is drawn here, once for each size the
// screens use, with sixteen levels of grey per pixel. Uses the Mac's own text engine (CoreText), so this tool
// runs on macOS only; the file it writes is the same everywhere.
//
// The file, little-endian:
//   "RDF1", number of faces (2 bytes), 2 bytes unused
//   for each face, 20 bytes: id, size in pixels, ascent, descent (2 bytes each), number of glyphs (4),
//                            where its index starts (4), where its pixels start (4)
//   an index per face, sorted by character, 12 bytes each: character (2), width, height (1 each),
//                            left, top (1 each, signed: where the box sits from the pen and the baseline),
//                            advance (1), unused (1), where its pixels start within the face (4)
//   the pixels: four bits each, row after row, each glyph rounded up to a whole byte
import CoreGraphics
import CoreText
import Foundation

struct Glyph {
    var character: UInt16
    var width = 0, height = 0, left = 0, top = 0, advance = 0
    var pixels: [UInt8] = []   // one value 0…15 per pixel
}

func load(_ path: String, size: CGFloat, weight: Double? = nil) -> CTFont {
    guard let found = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL) as? [CTFontDescriptor],
          var descriptor = found.first else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    if let weight {
        // 0x77676874 is "wght", the weight axis of a variable font.
        let axes = [NSNumber(value: 0x77676874): NSNumber(value: weight)]
        descriptor = CTFontDescriptorCreateCopyWithAttributes(descriptor, [kCTFontVariationAttribute: axes] as CFDictionary)
    }
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
}

func draw(_ font: CTFont, _ character: UInt16) -> Glyph? {
    var unit = [UniChar(character)]
    var glyph = [CGGlyph(0)]
    guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1), glyph[0] != 0 else { return nil }
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
    var box = CGRect.zero
    CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &box, 1)
    var out = Glyph(character: character)
    out.advance = min(255, max(0, Int(advance.width.rounded())))
    if box.width <= 0 || box.height <= 0 { return out }   // a space: it only moves the pen

    let left = Int(floor(box.minX)) - 1, bottom = Int(floor(box.minY)) - 1
    let width = Int(ceil(box.maxX)) + 1 - left, height = Int(ceil(box.maxY)) + 1 - bottom
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(gray: 1, alpha: 1)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setShouldSmoothFonts(false)
    var position = CGPoint(x: CGFloat(-left), y: CGFloat(-bottom))
    CTFontDrawGlyphs(font, &glyph, &position, 1, context)
    let data = context.data!.bindMemory(to: UInt8.self, capacity: width * height)

    // Cut away the empty margin.
    var x0 = width, x1 = -1, y0 = height, y1 = -1
    for y in 0..<height {
        for x in 0..<width where data[y * width + x] >= 9 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
    }
    if x1 < 0 { return out }
    out.width = x1 - x0 + 1
    out.height = y1 - y0 + 1
    guard out.width <= 255, out.height <= 255 else { return nil }
    out.left = left + x0
    out.top = (bottom + height) - y0   // rows above the baseline at which the box starts
    out.pixels.reserveCapacity(out.width * out.height)
    for y in y0...y1 {
        for x in x0...x1 { out.pixels.append(UInt8((Int(data[y * width + x]) * 15 + 127) / 255)) }
    }
    return out
}

/// The characters of GB 2312 (6,763 Chinese characters and its symbols), as Unicode.
func gb2312() -> Set<UInt16> {
    let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    var out = Set<UInt16>()
    for high in 0xA1...0xF7 {
        for low in 0xA1...0xFE {
            guard let text = String(data: Data([UInt8(high), UInt8(low)]), encoding: encoding), text.unicodeScalars.count == 1,
                  let scalar = text.unicodeScalars.first, scalar.value < 0xE000 || (scalar.value > 0xF8FF && scalar.value < 0xFFFD) else { continue }
            out.insert(UInt16(scalar.value))
        }
    }
    return out
}

let ascii = Set((0x20...0x7E).map { UInt16($0) })
let extras = Set("…·•—–≈℃°×÷±→←↑↓✓✕“”‘’「」『』《》【】、。，；：？！（）％".unicodeScalars.map { UInt16($0.value) })
let everything = gb2312().union(ascii).union(extras)
let latin = ascii.union(Set("…·•—–≈°×±✓".unicodeScalars.map { UInt16($0.value) }))
let digits = Set("0123456789:%≈".unicodeScalars.map { UInt16($0.value) })
// The words on the two answer buttons, which have a size of their own.
let buttonWords = Set("拒绝允许一次已".unicodeScalars.map { UInt16($0.value) })

struct Face {
    let id: UInt16
    let file: String
    let size: CGFloat
    var weight: Double? = nil
    let characters: Set<UInt16>
}

// Ids: tens say the family, units the size. 1x Chinese text (Source Han Sans; 13 is only the words on the buttons);
// 2x rounded, Nunito; 3x rounded, M PLUS.
// Rounded: x0, x1, x2 are 26, 30 and 38 pixels; x3 and x4 are the large numerals, 118 and (for three digits) 92.
let faces = [
    Face(id: 10, file: "source-han-sans/SourceHanSansCN-Medium.otf", size: 26, characters: everything),
    Face(id: 11, file: "source-han-sans/SourceHanSansCN-Medium.otf", size: 30, characters: everything),
    Face(id: 12, file: "source-han-sans/SourceHanSansCN-Bold.otf", size: 38, characters: everything),
    Face(id: 13, file: "source-han-sans/SourceHanSansCN-Bold.otf", size: 34, characters: buttonWords),
    Face(id: 20, file: "nunito/Nunito-wght.ttf", size: 26, weight: 700, characters: latin),
    Face(id: 21, file: "nunito/Nunito-wght.ttf", size: 30, weight: 700, characters: latin),
    Face(id: 22, file: "nunito/Nunito-wght.ttf", size: 38, weight: 700, characters: latin),
    Face(id: 23, file: "nunito/Nunito-wght.ttf", size: 118, weight: 800, characters: digits),
    Face(id: 24, file: "nunito/Nunito-wght.ttf", size: 92, weight: 800, characters: digits),
    Face(id: 30, file: "mplus-rounded-1c/MPLUSRounded1c-Bold.ttf", size: 26, characters: latin),
    Face(id: 31, file: "mplus-rounded-1c/MPLUSRounded1c-Bold.ttf", size: 30, characters: latin),
    Face(id: 32, file: "mplus-rounded-1c/MPLUSRounded1c-Bold.ttf", size: 38, characters: latin),
    Face(id: 33, file: "mplus-rounded-1c/MPLUSRounded1c-Bold.ttf", size: 118, characters: digits),
    Face(id: 34, file: "mplus-rounded-1c/MPLUSRounded1c-Bold.ttf", size: 92, characters: digits),
]

guard CommandLine.arguments.count == 3 else {
    print("usage: make-fonts FONTS_DIR OUT.bin")
    exit(1)
}
let root = CommandLine.arguments[1]

func put<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
}

var indexes: [Data] = [], pixels: [Data] = [], headers: [(Face, CTFont, Int)] = []
for face in faces {
    let font = load(root + "/" + face.file, size: face.size, weight: face.weight)
    var index = Data(), body = Data()
    var count = 0
    for character in face.characters.sorted() {
        guard let glyph = draw(font, character) else { continue }
        put(glyph.character, into: &index)
        index.append(UInt8(glyph.width)); index.append(UInt8(glyph.height))
        index.append(UInt8(bitPattern: Int8(clamping: glyph.left))); index.append(UInt8(bitPattern: Int8(clamping: glyph.top)))
        index.append(UInt8(glyph.advance)); index.append(0)
        put(UInt32(body.count), into: &index)
        var byte: UInt8 = 0
        for (i, value) in glyph.pixels.enumerated() {
            if i % 2 == 0 { byte = value << 4 } else { body.append(byte | value) }
        }
        if glyph.pixels.count % 2 == 1 { body.append(byte) }
        count += 1
    }
    indexes.append(index); pixels.append(body); headers.append((face, font, count))
    print("face \(face.id): \(face.file) at \(Int(face.size)) px, \(count) glyphs, \(index.count + body.count) bytes")
}

var out = Data("RDF1".utf8)
put(UInt16(faces.count), into: &out)
put(UInt16(0), into: &out)
var offset = 8 + 20 * faces.count
for (i, (face, font, count)) in headers.enumerated() {
    put(face.id, into: &out)
    put(UInt16(face.size), into: &out)
    put(Int16(CTFontGetAscent(font).rounded()), into: &out)
    put(Int16(CTFontGetDescent(font).rounded()), into: &out)
    put(UInt32(count), into: &out)
    put(UInt32(offset), into: &out)
    put(UInt32(offset + indexes[i].count), into: &out)
    offset += indexes[i].count + pixels[i].count
}
for i in 0..<faces.count {
    out.append(indexes[i])
    out.append(pixels[i])
}
try! out.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("wrote \(CommandLine.arguments[2]): \(out.count) bytes")
