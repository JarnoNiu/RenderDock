import Foundation

/// Reads one thing out of a `.blend` file: the frame range each scene is set to render, and which scene is
/// the active one. That is what `blender -b file.blend -a` renders when the command line gives no range.
///
/// The file is only ever mapped for reading. A `.blend` describes its own layout (the "DNA" block near its
/// end lists every struct and field), so nothing here depends on a Blender version: the fields are looked up
/// by name. What cannot be read gives nil, and the job is then shown without a total, as before:
/// a compressed file (Blender's "Compress" option; this reads no zstd or gzip), a big-endian one, a damaged one.
package enum BlendFile {
    package struct FrameRange: Equatable {
        package var start: Int
        package var end: Int
        package var step: Int

        package init(start: Int, end: Int, step: Int) {
            self.start = start
            self.end = end
            self.step = step
        }

        /// The frames this range renders. Nil for a range that makes no sense (end before start, millions of frames).
        package var frames: Set<Int>? {
            guard end >= start, step >= 1, (end - start) / step < 2_000_000 else { return nil }
            return Set(stride(from: start, through: end, by: step))
        }
    }

    package struct SceneRange: Equatable {
        package var name: String
        package var range: FrameRange
        /// The scene the file was saved with in front: the one rendered when no `-S` names another.
        package var active: Bool
    }

    /// The range of the named scene, or of the active one. Nil if the file cannot be read or has no such scene.
    package static func frameRange(at path: String, scene: String? = nil) -> FrameRange? {
        guard let all = scenes(at: path) else { return nil }
        if let scene { return all.first { $0.name == scene }?.range }
        return (all.first { $0.active } ?? (all.count == 1 ? all.first : nil))?.range
    }

    /// Every scene in the file with its range.
    package static func scenes(at path: String) -> [SceneRange]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) else { return nil }
        return scenes(in: data)
    }

    // MARK: the file

    /// How the file lays out the heading of each block. Two generations: the one Blender 5 writes, and the
    /// one before it (in a 64-bit and a 32-bit form).
    private struct Layout {
        var headerSize: Int
        var blockHeadSize: Int
        var pointerSize: Int
        var large: Bool
    }

    private static func layout(of data: Data) -> Layout? {
        guard data.count > 32, data.prefix(7) == Data("BLENDER".utf8) else { return nil }
        let eighth = data[data.startIndex + 7]
        if eighth == UInt8(ascii: "_") || eighth == UInt8(ascii: "-") {
            // "BLENDER" + pointer size + byte order + three digits of version. Little-endian only.
            guard data[data.startIndex + 8] == UInt8(ascii: "v") else { return nil }
            let wide = eighth == UInt8(ascii: "-")
            return Layout(headerSize: 12, blockHeadSize: wide ? 24 : 20, pointerSize: wide ? 8 : 4, large: false)
        }
        // "BLENDER" + the header's own size in two digits + "-" + the format's version in two digits + "v" + four digits.
        guard let size = Int(String(decoding: data[(data.startIndex + 7)..<(data.startIndex + 9)], as: UTF8.self)), size >= 17, size <= 64,
              data[data.startIndex + 9] == UInt8(ascii: "-"),
              let format = Int(String(decoding: data[(data.startIndex + 10)..<(data.startIndex + 12)], as: UTF8.self)), format == 1,
              data[data.startIndex + 12] == UInt8(ascii: "v") else { return nil }
        return Layout(headerSize: size, blockHeadSize: 32, pointerSize: 8, large: true)
    }

    private struct Block {
        var code: [UInt8]
        var structIndex: Int
        var address: UInt64
        var body: Range<Int>
    }

    /// Little-endian integers at an offset from the start of the data. Nil past the end.
    private static func int32(_ data: Data, _ at: Int) -> Int? {
        guard at >= 0, at + 4 <= data.count else { return nil }
        let i = data.startIndex + at
        return Int(Int32(bitPattern: UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24))
    }

    private static func int16(_ data: Data, _ at: Int) -> Int? {
        guard at >= 0, at + 2 <= data.count else { return nil }
        let i = data.startIndex + at
        return Int(Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8))
    }

    private static func unsigned(_ data: Data, _ at: Int, size: Int) -> UInt64? {
        guard at >= 0, at + size <= data.count else { return nil }
        var value: UInt64 = 0
        for k in 0..<size { value |= UInt64(data[data.startIndex + at + k]) << UInt64(8 * k) }
        return value
    }

    /// The blocks that matter here (the scenes, the file's globals, the DNA), found by walking every block's heading.
    private static func blocks(in data: Data, _ layout: Layout) -> [Block]? {
        var found: [Block] = []
        var at = layout.headerSize
        var walked = 0
        while at + layout.blockHeadSize <= data.count {
            walked += 1
            if walked > 50_000_000 { return nil }
            let code = Array(data[(data.startIndex + at)..<(data.startIndex + at + 4)])
            let length: Int, structIndex: Int, address: UInt64
            if layout.large {
                guard let s = int32(data, at + 4), let a = unsigned(data, at + 8, size: 8), let l = unsigned(data, at + 16, size: 8), l < UInt64(Int.max / 2) else { return nil }
                structIndex = s
                address = a
                length = Int(l)
            } else {
                guard let l = int32(data, at + 4), l >= 0, let a = unsigned(data, at + 8, size: layout.pointerSize),
                      let s = int32(data, at + 8 + layout.pointerSize) else { return nil }
                length = l
                address = a
                structIndex = s
            }
            let start = at + layout.blockHeadSize
            guard length >= 0, start + length <= data.count else { return nil }
            if code == Array("ENDB".utf8) { break }
            if code == Array("DNA1".utf8) || code == Array("GLOB".utf8) || code == [UInt8(ascii: "S"), UInt8(ascii: "C"), 0, 0] {
                found.append(Block(code: code, structIndex: structIndex, address: address, body: start..<(start + length)))
            }
            at = start + length
        }
        return found
    }

    // MARK: the file's own description of its structs

    private struct DNA {
        var typeNames: [String]
        var typeSizes: [Int]
        /// Each struct: its type, and its fields as (type, name), in the order they lie in memory.
        var structs: [(type: Int, fields: [(type: Int, name: String)])]
        var pointerSize: Int

        func structIndex(named name: String) -> Int? {
            structs.firstIndex { typeNames.indices.contains($0.type) && typeNames[$0.type] == name }
        }

        /// A field's size in bytes: a pointer, or its type's size, times the lengths of its array brackets.
        func size(ofField name: String, type: Int) -> Int? {
            var count = 1
            var rest = name[...]
            while let open = rest.firstIndex(of: "[") {
                guard let close = rest[open...].firstIndex(of: "]"), let n = Int(rest[rest.index(after: open)..<close]), n >= 0, n < 1 << 24 else { return nil }
                count *= n
                rest = rest[rest.index(after: close)...]
            }
            if name.hasPrefix("*") || name.hasPrefix("(*") { return pointerSize * count }
            guard typeSizes.indices.contains(type) else { return nil }
            return typeSizes[type] * count
        }

        /// Where a field lies in its struct, its type, and its name as declared (with any `*` and brackets).
        func field(_ wanted: String, inStruct index: Int) -> (offset: Int, type: Int, declared: String)? {
            guard structs.indices.contains(index) else { return nil }
            var offset = 0
            for f in structs[index].fields {
                let bare = f.name.prefix { $0 != "[" }.drop { $0 == "*" || $0 == "(" }
                if bare == wanted { return (offset, f.type, f.name) }
                guard let size = size(ofField: f.name, type: f.type) else { return nil }
                offset += size
            }
            return nil
        }
    }

    private static func dna(in whole: Data, body: Range<Int>, pointerSize: Int) -> DNA? {
        let data = whole.subdata(in: (whole.startIndex + body.lowerBound)..<(whole.startIndex + body.upperBound))
        var at = 0
        func tag(_ text: String) -> Bool {
            guard at + 4 <= data.count, data[at..<(at + 4)] == Data(text.utf8) else { return false }
            return true
        }
        func strings(_ name: String) -> [String]? {
            guard tag(name), let count = int32(data, at + 4), count >= 0, count < 1 << 22 else { return nil }
            at += 8
            var out: [String] = []
            out.reserveCapacity(count)
            for _ in 0..<count {
                guard let end = data[at...].firstIndex(of: 0) else { return nil }
                out.append(String(decoding: data[at..<end], as: UTF8.self))
                at = end + 1
            }
            at = (at + 3) & ~3
            return out
        }
        guard tag("SDNA") else { return nil }
        at += 4
        guard let names = strings("NAME"), let types = strings("TYPE"), tag("TLEN") else { return nil }
        at += 4
        var sizes: [Int] = []
        for _ in types {
            guard let size = int16(data, at) else { return nil }
            sizes.append(size)
            at += 2
        }
        at = (at + 3) & ~3
        guard tag("STRC"), let count = int32(data, at + 4), count >= 0, count < 1 << 20 else { return nil }
        at += 8
        var structs: [(type: Int, fields: [(type: Int, name: String)])] = []
        for _ in 0..<count {
            guard let type = int16(data, at), let fieldCount = int16(data, at + 2), fieldCount >= 0 else { return nil }
            at += 4
            var fields: [(type: Int, name: String)] = []
            for _ in 0..<fieldCount {
                guard let t = int16(data, at), let n = int16(data, at + 2), names.indices.contains(n) else { return nil }
                fields.append((t, names[n]))
                at += 4
            }
            structs.append((type, fields))
        }
        return DNA(typeNames: types, typeSizes: sizes, structs: structs, pointerSize: pointerSize)
    }

    // MARK: putting it together

    static func scenes(in data: Data) -> [SceneRange]? {
        guard let layout = layout(of: data), let blocks = blocks(in: data, layout),
              let dnaBlock = blocks.first(where: { $0.code == Array("DNA1".utf8) }),
              let dna = dna(in: data, body: dnaBlock.body, pointerSize: layout.pointerSize),
              let sceneStruct = dna.structIndex(named: "Scene"), let idStruct = dna.structIndex(named: "ID"),
              let render = dna.field("r", inStruct: sceneStruct), let renderStruct = dna.structs.firstIndex(where: { $0.type == render.type }),
              let first = dna.field("sfra", inStruct: renderStruct), let last = dna.field("efra", inStruct: renderStruct),
              let id = dna.field("id", inStruct: sceneStruct), let name = dna.field("name", inStruct: idStruct),
              let nameLength = dna.size(ofField: name.declared, type: name.type) else { return nil }
        let step = dna.field("frame_step", inStruct: renderStruct)

        // The active scene is the one the file's globals point at, by the address it had in memory when saved.
        var current: UInt64?
        if let globals = blocks.first(where: { $0.code == Array("GLOB".utf8) }), let globalStruct = dna.structIndex(named: "FileGlobal"),
           let pointer = dna.field("curscene", inStruct: globalStruct) {
            current = unsigned(data, globals.body.lowerBound + pointer.offset, size: layout.pointerSize)
        }

        var out: [SceneRange] = []
        for block in blocks where block.code == [UInt8(ascii: "S"), UInt8(ascii: "C"), 0, 0] {
            let base = block.body.lowerBound
            guard block.structIndex == sceneStruct,
                  let start = int32(data, base + render.offset + first.offset), let end = int32(data, base + render.offset + last.offset),
                  base + id.offset + name.offset + nameLength <= block.body.upperBound else { continue }
            let jump = step.flatMap { int32(data, base + render.offset + $0.offset) } ?? 1
            let raw = data[(data.startIndex + base + id.offset + name.offset)..<(data.startIndex + base + id.offset + name.offset + nameLength)]
            // A data-block's name is stored with a two-letter code in front: "SC" for a scene.
            let full = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            out.append(SceneRange(name: full.hasPrefix("SC") ? String(full.dropFirst(2)) : full,
                                  range: FrameRange(start: start, end: end, step: max(1, jump)), active: block.address == current))
        }
        return out.isEmpty ? nil : out
    }
}
