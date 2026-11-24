import Foundation

/// Detection rules for things that are not a plain Blender render: a compositing step, a custom encoder,
/// whatever your pipeline runs. Read from `~/Library/Application Support/RenderDock/adapters.json`.
/// With no file there are no extra rules. See docs/ADAPTERS.md.
package struct LeafAdapter: Codable, Equatable {
    package struct TotalSource: Codable, Equatable {
        /// Count the entries of `countOf` (an array or an object) in this JSON file…
        package var jsonFile: String?
        package var countOf: String?
        /// …or read the number from this command-line argument.
        package var arg: String?
    }

    /// For your own reference; shown nowhere.
    package var name: String
    /// The executable's name, e.g. "node". Case-insensitive.
    package var process: String
    /// Arguments that must all be present. A file name also matches a path that ends in it.
    package var args: [String]?
    /// Skip a matching process that has a descendant with this name: it is only the parent of the real work.
    package var notAbove: String?
    /// rendering (default) | compositing | encoding | finishing
    package var state: String?
    /// What to call it. Template; default is the usual naming (scene/shot arguments, then the process name).
    package var title: String?
    /// Folder where finished frames appear. Template.
    package var frames: String?
    package var total: TotalSource?
    /// The step empties `frames` when it starts: ignore what is in there until the folder is newer than the process.
    package var freshDir: Bool?

    package func matches(process name: String, args actual: [String]) -> Bool {
        guard name.lowercased() == process.lowercased() else { return false }
        return (args ?? []).allSatisfy { wanted in actual.contains { $0 == wanted || $0.hasSuffix("/" + wanted) } }
    }

    package var itemState: ItemState {
        switch state?.lowercased() {
        case "compositing": return .compositing
        case "encoding": return .encoding
        case "finishing": return .finishing
        default: return .rendering
        }
    }
}

/// How a queue script's command line lists what it is going to render, and how a running process is tied to
/// one of the items listed. The rule RenderDock starts with is `QueueRule.standard`: items written `scene:shot`.
/// More can be added in `adapters.json`; see docs/ADAPTERS.md.
package struct QueueRule: Codable, Equatable {
    /// For your own reference; shown nowhere.
    package var name: String?
    /// Only for a script with this file name, e.g. "render_all.sh". Without it, any script.
    package var script: String?
    /// How one item is written among the script's arguments: a template with named parts, e.g. `{scene}:{shot}`.
    package var item: String
    /// A process is rendering an item when it carries these arguments with these values (templates of the item's parts)…
    package var flags: [String: String]?
    /// …or, when it does not carry all of them, when one of its arguments contains this text (a template).
    /// This is also how a step that follows the render is recognised as still belonging to the item.
    package var contains: String?
    /// What to call an item (a template). Without it: the parts joined by " · ", leaving out a part that only repeats the one before.
    package var title: String?
    /// A file whose existence, newer than the queue's start, means the item is finished. A template with {cwd} and the item's parts.
    package var doneFile: String?

    package init(name: String? = nil, script: String? = nil, item: String, flags: [String: String]? = nil, contains: String? = nil,
                 title: String? = nil, doneFile: String? = nil) {
        self.name = name
        self.script = script
        self.item = item
        self.flags = flags
        self.contains = contains
        self.title = title
        self.doneFile = doneFile
    }

    /// The convention RenderDock has always read: `scene:shot` on the queue script's command line, a render
    /// started with `--scene … --shot …` (or with `scene-shot` somewhere in its arguments).
    package static let standard = QueueRule(name: "scene:shot", item: "{scene}:{shot}", flags: ["--scene": "{scene}", "--shot": "{shot}"],
                                            contains: "{scene}-{shot}")

    /// One item of a queue: the parts of it that the template names.
    package struct Item: Equatable {
        package var fields: [String: String]
        /// The parts in the order the template has them.
        package var values: [String]
        /// Names the item within its queue: the parts joined by "-".
        package var key: String { values.joined(separator: "-") }
    }

    private enum Piece: Equatable {
        case text(String)
        case part(String)
    }

    /// The template cut into fixed text and named parts. Empty if it names no part or is not well formed.
    private var pieces: [Piece] {
        var out: [Piece] = []
        var rest = item[...]
        while let open = rest.firstIndex(of: "{") {
            if open > rest.startIndex { out.append(.text(String(rest[..<open]))) }
            guard let close = rest[open...].firstIndex(of: "}") else { return [] }
            let name = String(rest[rest.index(after: open)..<close])
            // Two parts with nothing between them could not be told apart.
            if name.isEmpty { return [] }
            if case .part = out.last { return [] }
            out.append(.part(name))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        return out.contains { if case .part = $0 { return true } else { return false } } ? out : []
    }

    /// The item an argument stands for, or nil if the argument is not written the way the template says.
    /// A part is letters, digits, "-", "_" and "." only, and the first part has at least one letter, so that
    /// a time (`12:30`) or an address (`http://…`) is not taken for an item.
    package func parse(_ argument: String) -> Item? {
        let pieces = pieces
        guard !pieces.isEmpty else { return nil }
        var rest = argument[...]
        var fields: [String: String] = [:]
        var values: [String] = []
        for (index, piece) in pieces.enumerated() {
            switch piece {
            case .text(let text):
                guard rest.hasPrefix(text) else { return nil }
                rest = rest.dropFirst(text.count)
            case .part(let name):
                let value: Substring
                if index + 1 < pieces.count, case .text(let next) = pieces[index + 1] {
                    guard let stop = rest.range(of: next) else { return nil }
                    value = rest[..<stop.lowerBound]
                    rest = rest[stop.lowerBound...]
                } else {
                    value = rest
                    rest = rest[rest.endIndex...]
                }
                guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }),
                      fields[name] == nil else { return nil }
                fields[name] = String(value)
                values.append(String(value))
            }
        }
        guard rest.isEmpty, values.first?.contains(where: \.isLetter) == true else { return nil }
        return Item(fields: fields, values: values)
    }

    /// A template with the item's parts put in. Nil if it names a part the item does not have.
    package func fill(_ template: String, _ item: Item) -> String? {
        AdapterRules.expand(template, args: [], cwd: "", extra: item.fields)
    }

    package func title(for item: Item) -> String {
        if let title, let filled = fill(title, item) { return filled }
        var shown: [String] = []
        for value in item.values {
            if let before = shown.last, before == value || before.hasSuffix("-" + value) { continue }
            shown.append(value)
        }
        return shown.joined(separator: " · ")
    }

    /// Whether a process with these arguments is rendering this item.
    package func matches(arguments: [String], _ item: Item) -> Bool {
        if let flags, !flags.isEmpty {
            let carried = flags.compactMap { flag, template in TaskScanner.argValue(arguments, [flag]).map { ($0, template) } }
            if carried.count == flags.count { return carried.allSatisfy { value, template in fill(template, item) == value } }
        }
        return follows(arguments: arguments, item)
    }

    /// Whether a process with these arguments is some step of this item's (by the text the rule says its arguments contain).
    package func follows(arguments: [String], _ item: Item) -> Bool {
        guard let contains, let text = fill(contains, item), !text.isEmpty else { return false }
        return arguments.contains { $0.contains(text) }
    }

    /// Whether this rule is for a script with these arguments, and if so which of them list its items.
    package func items(in arguments: [String]) -> [Item] {
        func isScript(_ a: String) -> Bool { script.map { a == $0 || a.hasSuffix("/" + $0) } ?? false }
        if script != nil, !arguments.contains(where: isScript) { return [] }
        return arguments.filter { !$0.hasPrefix("-") && !isScript($0) }.compactMap(parse)
    }
}

package struct AdapterRules: Codable, Equatable {
    package var adapters: [LeafAdapter]
    /// For queue scripts that take `scene:shot` arguments: a file whose existence (newer than the queue's start)
    /// means that shot is finished. Template with {cwd}, {scene}, {shot}. Without it, shots before the current one count as done.
    package var queueDoneFile: String?
    /// Other ways a queue script may list its items. Tried before the standard one.
    package var queues: [QueueRule]?
    /// False to stop reading `scene:shot` arguments as a queue. Read by default.
    package var standardQueue: Bool?
    /// False to leave a ComfyUI server on this Mac alone (its queue is otherwise read from 127.0.0.1 while it has one).
    package var comfyui: Bool?

    package init(adapters: [LeafAdapter] = [], queueDoneFile: String? = nil, queues: [QueueRule]? = nil, standardQueue: Bool? = nil) {
        self.adapters = adapters
        self.queueDoneFile = queueDoneFile
        self.queues = queues
        self.standardQueue = standardQueue
    }

    enum CodingKeys: String, CodingKey { case adapters, queueDoneFile, queues, standardQueue, comfyui }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        adapters = try c.decodeIfPresent([LeafAdapter].self, forKey: .adapters) ?? []
        queueDoneFile = try c.decodeIfPresent(String.self, forKey: .queueDoneFile)
        queues = try c.decodeIfPresent([QueueRule].self, forKey: .queues)
        standardQueue = try c.decodeIfPresent(Bool.self, forKey: .standardQueue)
        comfyui = try c.decodeIfPresent(Bool.self, forKey: .comfyui)
    }

    /// The queue rules in force, in the order they are tried: the file's own, then the standard one (with
    /// `queueDoneFile` as its done-file) unless the file switches it off.
    package var queueRules: [QueueRule] {
        var standard = QueueRule.standard
        standard.doneFile = queueDoneFile
        return (queues ?? []) + (standardQueue == false ? [] : [standard])
    }

    /// Override with the RENDERDOCK_ADAPTERS environment variable (used when testing).
    package static var file: URL {
        if let custom = ProcessInfo.processInfo.environment["RENDERDOCK_ADAPTERS"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RenderDock/adapters.json")
    }

    /// A missing or unreadable file means no extra rules; a broken file never stops the scan.
    package static func load(from url: URL = file) -> AdapterRules {
        guard let data = try? Data(contentsOf: url), let rules = try? JSONDecoder().decode(AdapterRules.self, from: data) else {
            return AdapterRules()
        }
        return rules
    }

    /// Fills a template: `{cwd}`, `{--flag}` (the value of that command-line argument), and any `extra` names.
    /// Returns nil when a placeholder has no value, so a half-filled path is never used.
    package static func expand(_ template: String, args: [String], cwd: String, extra: [String: String] = [:]) -> String? {
        var out = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { return nil }
            let key = String(rest[rest.index(after: open)..<close])
            let value: String?
            if key == "cwd" {
                value = cwd.isEmpty ? nil : cwd
            } else if key.hasPrefix("-") {
                value = TaskScanner.argValue(args, [key])
            } else {
                value = extra[key]
            }
            guard let v = value, !v.isEmpty else { return nil }
            out += v
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}
