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

package struct AdapterRules: Codable, Equatable {
    package var adapters: [LeafAdapter]
    /// For queue scripts that take `scene:shot` arguments: a file whose existence (newer than the queue's start)
    /// means that shot is finished. Template with {cwd}, {scene}, {shot}. Without it, shots before the current one count as done.
    package var queueDoneFile: String?

    package init(adapters: [LeafAdapter] = [], queueDoneFile: String? = nil) {
        self.adapters = adapters
        self.queueDoneFile = queueDoneFile
    }

    enum CodingKeys: String, CodingKey { case adapters, queueDoneFile }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        adapters = try c.decodeIfPresent([LeafAdapter].self, forKey: .adapters) ?? []
        queueDoneFile = try c.decodeIfPresent(String.self, forKey: .queueDoneFile)
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
