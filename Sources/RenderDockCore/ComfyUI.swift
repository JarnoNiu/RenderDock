import Foundation

// A ComfyUI server running on this Mac, and what is in its queue.
//
// ComfyUI answers `GET /queue` on the port it listens on with the prompts that are running and the ones
// waiting. That is all that is read: one request to 127.0.0.1 per scan, and only while a ComfyUI process is
// there. Nothing is ever sent to it.
//
// What cannot be had this way is how far along the running prompt is. ComfyUI sends its step-by-step progress
// only to the browser tab that queued the prompt (its source says so: "to ensure message is only sent to the
// initiating client"), and joining under that tab's name would take its connection away from it. So a prompt
// shows as running, without a percentage, and the queue shows how many are done and how many are still to come.
// See docs/COMFYUI.md.
package enum ComfyUI {
    package static let defaultPort = 8188

    /// The port a process serves ComfyUI on, or nil if the process is not a ComfyUI server. Recognised by what
    /// it runs: a Python whose script is ComfyUI's `main.py` (in a folder, or with a path, that says ComfyUI).
    package static func port(processName: String, arguments: [String], cwd: String) -> Int? {
        guard processName.lowercased().hasPrefix("python") else { return nil }
        guard let script = arguments.dropFirst().first(where: { ($0 as NSString).lastPathComponent == "main.py" }) else { return nil }
        guard script.lowercased().contains("comfy") || cwd.lowercased().contains("comfy") else { return nil }
        if let text = TaskScanner.argValue(arguments, ["--port"]), let port = Int(text), (1...65_535).contains(port) { return port }
        return defaultPort
    }

    package struct Prompt: Equatable {
        /// The server's own running count for the prompt: what order it was queued in.
        package var number: Int
        package var id: String

        package init(number: Int, id: String) {
            self.number = number
            self.id = id
        }
    }

    package struct Queue: Equatable {
        package var running: [Prompt]
        package var pending: [Prompt]

        package init(running: [Prompt] = [], pending: [Prompt] = []) {
            self.running = running
            self.pending = pending
        }

        package var isEmpty: Bool { running.isEmpty && pending.isEmpty }
    }

    /// What `GET /queue` returns: `{"queue_running": [[number, prompt_id, …], …], "queue_pending": […]}`.
    /// Only the first two fields of each entry are read; the rest (the workflow itself) is left alone.
    package static func parseQueue(_ data: Data) -> Queue? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let running = object["queue_running"] as? [Any], let pending = object["queue_pending"] as? [Any] else { return nil }
        func prompts(_ list: [Any]) -> [Prompt] {
            list.compactMap { entry in
                guard let fields = entry as? [Any], fields.count >= 2, let id = fields[1] as? String, !id.isEmpty else { return nil }
                return Prompt(number: (fields[0] as? NSNumber)?.intValue ?? 0, id: id)
            }.sorted { $0.number < $1.number }
        }
        return Queue(running: prompts(running), pending: prompts(pending))
    }

    /// Asks the server on this Mac for its queue, and waits for the answer for at most `timeout` seconds.
    package static func fetchQueue(port: Int, timeout: TimeInterval = 0.8) -> Queue? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/queue") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.connectionProxyDictionary = [:]   // a proxy has no business between this app and this Mac
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var result: Queue?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count < 64 * 1024 * 1024 { result = parseQueue(data) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 0.2)
        return result
    }
}

/// Follows each server's queue from one look to the next. A prompt that was in the queue and no longer is has
/// finished (or was cancelled: the queue does not say which). The count starts over when the queue empties.
package final class ComfyTracker {
    package struct View: Equatable {
        package var done: [ComfyUI.Prompt]
        package var running: [ComfyUI.Prompt]
        package var pending: [ComfyUI.Prompt]
    }

    private var seen: [Int32: [ComfyUI.Prompt]] = [:]
    private var cache: [Int32: (at: Date, view: View?)] = [:]

    package init() {}

    /// What to show for a server, given its queue as just read (nil if it could not be read). Nil when there
    /// is nothing in the queue: an idle server is not a job.
    package func update(pid: Int32, queue: ComfyUI.Queue?) -> View? {
        guard let queue, !queue.isEmpty else {
            seen[pid] = nil
            return nil
        }
        var known = seen[pid] ?? []
        let ids = Set(known.map(\.id))
        for prompt in queue.running + queue.pending where !ids.contains(prompt.id) { known.append(prompt) }
        if known.count > 500 { known.removeFirst(known.count - 500) }
        seen[pid] = known
        let live = Set((queue.running + queue.pending).map(\.id))
        return View(done: known.filter { !live.contains($0.id) }.sorted { $0.number < $1.number }, running: queue.running, pending: queue.pending)
    }

    /// The same, asking the server itself, at most once every couple of seconds.
    package func view(pid: Int32, port: Int, now: Date = Date()) -> View? {
        if let kept = cache[pid], now.timeIntervalSince(kept.at) < 2.5 { return kept.view }
        let view = update(pid: pid, queue: ComfyUI.fetchQueue(port: port))
        cache[pid] = (now, view)
        return view
    }

    package func forget(except alive: Set<Int32>) {
        seen = seen.filter { alive.contains($0.key) }
        cache = cache.filter { alive.contains($0.key) }
    }
}
