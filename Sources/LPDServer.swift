import Foundation
import Network

final class LPDServer {
    private let listener: NWListener
    private var current: LPDSession?
    private var blockedControl: String?
    private let sendPrint: (PrintJob, @escaping (Bool) -> Void) -> Void
    private let report: (String) -> Void

    init(port: UInt16, report: @escaping (String) -> Void, onReady: @escaping () -> Void = {},
         sendPrint: @escaping (PrintJob, @escaping (Bool) -> Void) -> Void) throws {
        self.sendPrint = sendPrint
        self.report = report
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                report("打印队列就绪 127.0.0.1:\(port)")
                onReady()
            case .failed(let error): report("打印队列无法启动 \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self, self.current == nil else { connection.cancel(); return }
            let session = LPDSession(connection,
                                     shouldAccept: { [weak self] name in self?.blockedControl != name },
                                     printJob: { [weak self] data, control, done in
                guard let self = self else { done(false); return }
                self.sendPrint(data) { success in
                    if !success { self.blockedControl = control }
                    done(success)
                }
            }, onClose: { [weak self] in self?.current = nil })
            self.current = session
            session.start()
        }
        listener.start(queue: .main)
    }
}

private final class LPDSession {
    private enum Step { case queue, controlHeader, controlBody(Int), dataHeader, dataBody(Int), delivering }
    private let connection: NWConnection
    private let shouldAccept: (String) -> Bool
    private let printJob: (PrintJob, String, @escaping (Bool) -> Void) -> Void
    private let onClose: () -> Void
    private var step: Step = .queue
    private var buffer = Data()
    private var controlName = ""
    private var dataName = ""
    private var title = ""
    private var closed = false

    init(_ connection: NWConnection, shouldAccept: @escaping (String) -> Bool,
         printJob: @escaping (PrintJob, String, @escaping (Bool) -> Void) -> Void, onClose: @escaping () -> Void) {
        self.connection = connection
        self.shouldAccept = shouldAccept
        self.printJob = printJob
        self.onClose = onClose
    }

    func start() {
        connection.start(queue: .main)
        read()
        DispatchQueue.main.asyncAfter(deadline: .now() + 175) { [weak self] in self?.close() }
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] bytes, _, eof, error in
            guard let self = self, !self.closed else { return }
            if error != nil { self.close(); return }
            if let bytes = bytes { self.buffer.append(bytes) }
            if eof { self.reject(); return }
            self.parse()
        }
    }

    private func parse() {
        switch step {
        case .queue:
            guard let line = takeLine() else { return }
            guard line == Data([2] + Array("qr888".utf8)) else { reject(); return }
            step = .controlHeader
            respond(0)
        case .controlHeader:
            guard let line = takeLine() else { return }
            guard let (size, name) = header(line, command: 2, prefix: "cfA", maxSize: 16_384),
                  shouldAccept(name) else { reject(); return }
            controlName = name
            dataName = "dfA" + String(name.dropFirst(3))
            step = .controlBody(size)
            respond(0)
        case .controlBody(let size):
            guard let control = takeBody(size) else { return }
            let fields = String(decoding: control, as: UTF8.self).split(separator: "\n")
            if let field = fields.first(where: { $0.first == "J" }) {
                title = String(field.dropFirst().prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            step = .dataHeader
            respond(0)
        case .dataHeader:
            guard let line = takeLine() else { return }
            guard let (size, name) = header(line, command: 3, prefix: "dfA", maxSize: 16 * 1024 * 1024),
                  name == dataName else { reject(); return }
            step = .dataBody(size)
            respond(0)
        case .dataBody(let size):
            guard let job = takeBody(size) else { return }
            guard buffer.isEmpty,
                  job.drop(while: { $0 == 0 }).starts(with: Data("SIZE ".utf8)),
                  job.suffix(96).range(of: Data("\r\nPRINT ".utf8)) != nil else { reject(); return }
            step = .delivering
            printJob(PrintJob(title: title, data: job), controlName) { [weak self] success in
                self?.respond(success ? 0 : 1, final: true)
            }
        case .delivering:
            break
        }
    }

    private func takeLine() -> Data? {
        guard let end = buffer.firstIndex(of: 10) else {
            if buffer.count > 512 { reject() } else { read() }
            return nil
        }
        guard buffer.distance(from: buffer.startIndex, to: end) <= 512 else { reject(); return nil }
        let result = Data(buffer[..<end])
        buffer.removeFirst(result.count + 1)
        return result
    }

    private func takeBody(_ size: Int) -> Data? {
        guard buffer.count >= size + 1 else { read(); return nil }
        guard buffer[buffer.index(buffer.startIndex, offsetBy: size)] == 0 else { reject(); return nil }
        let result = Data(buffer.prefix(size))
        buffer.removeFirst(size + 1)
        return result
    }

    private func header(_ line: Data, command: UInt8, prefix: String, maxSize: Int) -> (Int, String)? {
        guard line.first == command, let arguments = String(data: line.dropFirst(), encoding: .utf8) else { return nil }
        let parts = arguments.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, let size = Int(parts[0]), size > 0, size <= maxSize,
              parts[1].hasPrefix(prefix), parts[1].count <= 128 else { return nil }
        return (size, String(parts[1]))
    }

    private func respond(_ byte: UInt8, final: Bool = false) {
        guard !closed else { return }
        connection.send(content: Data([byte]), completion: .contentProcessed { [weak self] error in
            guard let self = self, !self.closed else { return }
            if final || error != nil { self.close() } else if self.buffer.isEmpty { self.read() } else { self.parse() }
        })
    }

    private func reject() { respond(1, final: true) }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose()
    }
}
