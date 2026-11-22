import Combine
import Foundation

/// The app's log: the last lines on screen (Settings), all of it in a file that
/// can be shared or found in the Files app. It holds what the app did and the
/// words it heard; never a mail's text, a key or an address with a token.
@MainActor
final class Log: ObservableObject {
    static let shared = Log()

    @Published private(set) var lines: [String] = []
    let file: URL

    private var handle: FileHandle?
    private let stamp = DateFormatter()

    private init() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        file = folder.appendingPathComponent("mailpilot-lens.log")
        stamp.dateFormat = "HH:mm:ss.SSS"
        // A new file once the old one passed 1 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber, size.intValue > 1_000_000 {
            try? FileManager.default.removeItem(at: file)
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
    }

    func add(_ text: String, at: Date = Date()) {
        let line = "\(stamp.string(from: at)) \(text)"
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        if let data = (line + "\n").data(using: .utf8) { try? handle?.write(contentsOf: data) }
    }

    func clear() {
        lines = []
    }

    /// Logs from any thread.
    nonisolated static func say(_ text: String) {
        let at = Date()
        Task { @MainActor in Log.shared.add(text, at: at) }
    }
}
