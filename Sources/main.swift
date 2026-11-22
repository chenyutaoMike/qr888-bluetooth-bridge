import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: LPDServer?
    private var printer: BluetoothPrinter?
    private var status: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var previewItem: NSMenuItem?
    private var preview: PreviewQueue?
    private var setup: QueueSetup?
    private var listenerReady = false
    private var picking = false
    private var logURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let capture = args.count == 3 && args[1] == "--capture-dir"
        let setupTest = args.count == 3 && args[1] == "--setup-test-dir"
        let previewTest = setupTest || (args.count == 3 && args[1] == "--preview-test-dir")
        let config = previewTest ? QueueConfiguration.test : .production
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let directory = capture || previewTest ? URL(fileURLWithPath: args[2], isDirectory: true) :
            library.appendingPathComponent("Logs/QR888OpenBridge", isDirectory: true)
        if !capture { makeMenu(hasSetup: !previewTest || setupTest) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let log = directory.appendingPathComponent("bridge.log")
            logURL = log
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if !capture {
                let report: (String) -> Void = { [weak self] in self?.report($0) }
                if !previewTest || setupTest {
                    printer = BluetoothPrinter(report: report)
                    setup = QueueSetup(config: config, report: report)
                }
                let folder = previewTest ? directory : library.appendingPathComponent("Application Support/QR888OpenBridge", isDirectory: true)
                let spool = try PrintSpool(directory: folder.appendingPathComponent("Pending", isDirectory: true))
                preview = PreviewQueue(spool: spool, report: report,
                                       queueChanged: { [weak self] in self?.updatePending($0) },
                                       canSend: { [weak self] in
                    guard let self = self else { return false }
                    if previewTest { return true }
                    guard let printer = self.printer, !printer.isBusy else { return false }
                    if printer.selectedID != nil { return true }
                    self.choosePrinter()
                    return false
                }) { [weak self] data, done in
                    guard let self = self else { done(false); return }
                    if previewTest { self.capture(data, directory: directory, done: done) }
                    else if let printer = self.printer { printer.run(data, completion: done) }
                    else { done(false) }
                }
            }
            server = try LPDServer(port: capture ? 19151 : config.port, report: { [weak self] in self?.report($0) },
                                   onReady: { [weak self] in self?.serverBecameReady() }) { [weak self] job, done in
                guard let self = self else { done(false); return }
                self.report("收到完整打印任务 \(job.data.count) 字节")
                if capture { self.capture(job.data, directory: directory, done: done) }
                else if let preview = self.preview { preview.accept(job, done: done) }
                else { done(false) }
            }
            if !capture { DispatchQueue.main.async { [weak self] in self?.preview?.restore() } }
        } catch {
            report(error.localizedDescription)
        }
    }

    private func serverBecameReady() {
        listenerReady = true
        setup?.show(onlyIfMissing: true) { [weak self] in self?.choosePrinter() }
    }

    @objc private func setupPrinter() {
        guard listenerReady else {
            message("打印桥尚未就绪", "请查看菜单栏的状态和打印记录。如果此 Mac 上已有其他版本的打印桥在运行，请先退出旧版本。")
            return
        }
        setup?.show { [weak self] in self?.choosePrinter() }
    }

    @objc private func choosePrinter() {
        guard let printer = printer, !picking, !printer.isBusy, preview?.sending != true else { return }
        picking = true
        printer.findPrinters { [weak self, weak printer] devices in
            guard let self = self, let printer = printer else { return }
            defer { self.picking = false }
            if devices.isEmpty {
                self.report("未发现 QR-888XPro")
                self.message("没有找到 QR-888XPro", "打开打印机和 Mac 蓝牙，在「隐私与安全性 → 蓝牙」允许本 App，并关闭标签管家等占用蓝牙的工具。然后从菜单再扫描一次。")
                return
            }
            let alert = NSAlert()
            alert.messageText = "选择蓝牙打印机"
            alert.informativeText = "选择这台 Mac 要使用的 QR-888XPro。当前：\(printer.selectedName ?? "尚未选择")。"
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 285, height: 28), pullsDown: false)
            picker.setAccessibilityLabel("附近的 QR-888XPro 打印机")
            for device in devices {
                let sameName = devices.contains { $0.name == device.name && $0.identifier != device.identifier }
                let label = sameName ? "\(device.name)（\(device.identifier.uuidString.suffix(8))）" : device.name
                picker.addItem(withTitle: label)
            }
            if let index = devices.firstIndex(where: { $0.identifier == printer.selectedID }) {
                picker.selectItem(at: index)
            } else if devices.count > 1 {
                picker.insertItem(withTitle: "请选择一台打印机", at: 0)
                picker.selectItem(at: 0)
            }
            let placeholder = picker.numberOfItems > devices.count
            alert.accessoryView = picker
            alert.addButton(withTitle: "选用这台打印机")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                let index = picker.indexOfSelectedItem - (placeholder ? 1 : 0)
                if devices.indices.contains(index) {
                    printer.select(devices[index])
                } else {
                    self.message("请选择打印机", "可从菜单栏再次打开选择列表。")
                }
            }
        }
    }

    @objc private func probe() {
        guard let printer = printer else { return }
        guard printer.selectedID != nil else { choosePrinter(); return }
        preview?.check { printer.run(completion: $0) }
    }

    private func capture(_ data: Data, directory: URL, done: (Bool) -> Void) {
        do {
            try data.write(to: directory.appendingPathComponent(UUID().uuidString + ".tspl"), options: .atomic)
            done(true)
        } catch {
            report(error.localizedDescription)
            done(false)
        }
    }

    @objc private func showPreview() { preview?.showPending() }
    @objc private func showSample() {
        if let sample = Bundle.main.url(forResource: "test-label-100x100", withExtension: "pdf") {
            NSWorkspace.shared.open(sample)
        }
    }
    @objc private func showLog() { if let url = logURL { NSWorkspace.shared.open(url) } }
    @objc private func quit() { NSApp.terminate(nil) }

    private func updatePending(_ count: Int) {
        previewItem?.title = count > 0 ? "查看待预览任务（\(count)）" : "没有待预览任务"
        previewItem?.isEnabled = count > 0
    }

    private func makeMenu(hasSetup: Bool) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "启锐"
        let menu = NSMenu()
        menu.autoenablesItems = false
        let line = NSMenuItem(title: "启动中", action: nil, keyEquivalent: "")
        menu.addItem(line)
        let preview = NSMenuItem(title: "没有待预览任务", action: #selector(showPreview), keyEquivalent: "")
        preview.target = self
        preview.isEnabled = false
        menu.addItem(preview)
        menu.addItem(.separator())
        previewItem = preview
        var actions = [("打开 100 × 100 mm 测试标签", #selector(showSample)), ("查看打印记录", #selector(showLog)), ("退出打印桥", #selector(quit))]
        if hasSetup {
            actions.insert(contentsOf: [("设置系统打印机…", #selector(setupPrinter)), ("选择蓝牙打印机…", #selector(choosePrinter)),
                                        ("检查蓝牙连接", #selector(probe))], at: 0)
        }
        for (title, action) in actions {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        status = item
        statusLine = line
    }

    private func message(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func report(_ message: String) {
        statusLine?.title = message
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let url = logURL, let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        }
        fputs(line, stderr)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
