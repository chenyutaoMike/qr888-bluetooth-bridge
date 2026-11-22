import Foundation

struct PrintJob: Codable {
    let title: String
    let data: Data
}

final class PrintSpool {
    private let directory: URL
    private let files = FileManager.default
    private(set) var pending: [URL]
    let interrupted: [URL]

    init(directory: URL) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        self.directory = directory
        let jobs = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles]).map { directory.appendingPathComponent($0.lastPathComponent) }
        self.pending = jobs.filter { $0.pathExtension == "pending" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        self.interrupted = jobs.filter { $0.pathExtension == "printing" }
    }

    @discardableResult func enqueue(_ job: PrintJob) throws -> URL {
        let stamp = String(format: "%020.6f", Date().timeIntervalSince1970)
        let url = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString).pending")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(job).write(to: url, options: .atomic)
        pending.append(url)
        return url
    }

    func read(_ url: URL) throws -> PrintJob {
        try PropertyListDecoder().decode(PrintJob.self, from: Data(contentsOf: url))
    }

    func start(_ url: URL) throws -> URL {
        let active = url.deletingPathExtension().appendingPathExtension("printing")
        try files.moveItem(at: url, to: active)
        pending.removeAll { $0 == url }
        return active
    }

    func remove(_ url: URL) throws {
        try files.removeItem(at: url)
        pending.removeAll { $0 == url }
    }
}
