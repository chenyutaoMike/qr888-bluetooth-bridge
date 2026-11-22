import AppKit

final class QueueSetup {
    private enum State { case ready, missing, conflict }

    private let config: QueueConfiguration
    private let report: (String) -> Void
    private let worker = DispatchQueue(label: "org.labelbridge.qr888.setup", qos: .userInitiated)
    private var busy = false
    private let driverURL = URL(string: "https://qrprt.com/download.html")!
    private let admin = "/usr/sbin/lpadmin"
    private let filter = "/Library/Printers/AiYin/Filter/rastertolabel"

    init(config: QueueConfiguration, report: @escaping (String) -> Void) {
        self.config = config
        self.report = report
    }

    func show(onlyIfMissing: Bool = false, onReady: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        worker.async {
            let state = Result { try self.state() }
            DispatchQueue.main.async {
                self.busy = false
                switch state {
                case .success(.ready):
                    if !onlyIfMissing {
                        if self.dialog("系统打印队列已就绪", "在各 App 的打印窗口里选择「\(self.config.title)」。",
                                       buttons: ["选择蓝牙打印机", "关闭"]) == .alertFirstButtonReturn { onReady() }
                    }
                case .success(.conflict):
                    self.notify("已有同名打印队列", "系统已有名为 \(self.config.name) 的队列，但地址不同。请在「打印机与扫描仪」核对后再添加。")
                case .success(.missing):
                    self.offerInstall(onReady: onReady)
                case .failure(let error):
                    self.notify("无法查询系统打印队列", error.localizedDescription)
                }
            }
        }
    }

    private var driverPPD: String? {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: filter) else { return nil }
        return ["/Library/Printers/AiYin/PPDs/QR-888XPro.ppd",
                "/Library/Printers/PPDs/Contents/Resources/QR-888XPro.ppd"].first { files.isReadableFile(atPath: $0) }
    }

    private func state() throws -> State {
        let scheduler = try run("/usr/bin/lpstat", ["-h", QueueConfiguration.cupsSocket, "-r"])
        let stopped = ["not running", "没有运行", "未运行"].contains { scheduler.text.localizedCaseInsensitiveContains($0) }
        guard scheduler.status == 0, !stopped else { throw SetupError(scheduler.text) }
        let current = try run("/usr/bin/lpstat", ["-h", QueueConfiguration.cupsSocket, "-v", config.name])
        if current.status != 0 { return .missing }
        return config.matches(current.text) ? .ready : .conflict
    }

    private func offerInstall(onReady: @escaping () -> Void) {
        guard let ppd = driverPPD else {
            if dialog("需要启锐 macOS 驱动", "从启锐官网下载「启锐MacOS驱动」并安装，再回来用菜单栏「启锐 → 设置系统打印机」。",
                      buttons: ["打开官方驱动下载", "稍后"]) == .alertFirstButtonReturn {
                NSWorkspace.shared.open(driverURL)
            }
            return
        }
        if dialog("添加系统打印机", "添加「\(config.title)」，默认纸张 100 × 100 mm。应用提交的任务会先打开预览，确认后才发送至蓝牙。",
                  buttons: ["添加打印机", "稍后"]) == .alertFirstButtonReturn {
            install(ppd: ppd, elevate: false, onReady: onReady)
        }
    }

    private func install(ppd: String, elevate: Bool, onReady: @escaping () -> Void) {
        busy = true
        worker.async {
            let result = Result { () -> CommandResult in
                switch try self.state() {
                case .ready: return CommandResult(status: 0, text: "")
                case .conflict: throw SetupError("同名队列正在使用其他地址。")
                case .missing: break
                }
                let arguments = self.config.installArguments(ppd: ppd)
                if elevate {
                    let command = ([self.admin] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
                    let script = "on run argv\n do shell script (item 1 of argv) with administrator privileges\nend run"
                    return try self.run("/usr/bin/osascript", ["-e", script, command])
                }
                return try self.run(self.admin, arguments)
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let command) where command.status == 0:
                    self.report("系统打印队列已就绪")
                    onReady()
                case .success(let command):
                    let text = command.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.report("添加打印机失败：\(text)")
                    let needsAdmin = ["Forbidden", "Unauthorized", "not authorized", "Password", "Authentication", "client-error-not-authorized", "权限", "授权", "密码", "认证"]
                        .contains { text.localizedCaseInsensitiveContains($0) }
                    if !elevate && needsAdmin,
                       self.dialog("需要管理员授权", "macOS 要求管理员账户来添加本机的打印机队列。",
                                   buttons: ["使用管理员授权", "取消"]) == .alertFirstButtonReturn {
                        self.install(ppd: ppd, elevate: true, onReady: onReady)
                    } else if elevate || !needsAdmin {
                        self.notify("添加打印机失败", text)
                    }
                case .failure(let error):
                    self.notify("添加打印机失败", error.localizedDescription)
                }
            }
        }
    }

    private struct CommandResult { let status: Int32; let text: String }

    private func run(_ path: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LANG": "C", "LC_ALL": "C"]) { _, value in value }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }

    private struct SetupError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message.isEmpty ? "系统打印服务不可用。" : message }
    }

    private func notify(_ title: String, _ message: String) { _ = dialog(title, message, buttons: ["好"]) }

    private func dialog(_ title: String, _ message: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
