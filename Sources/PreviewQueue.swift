import AppKit

final class PreviewQueue {
    private let spool: PrintSpool
    private let report: (String) -> Void
    private let queueChanged: (Int) -> Void
    private let canSend: () -> Bool
    private let send: (Data, @escaping (Bool) -> Void) -> Void
    private let decoder = DispatchQueue(label: "local.qirui.preview.decode", qos: .userInitiated)
    private var window: PrintPreviewWindow?
    private var loading = false
    private(set) var sending = false
    private var checking = false

    init(spool: PrintSpool, report: @escaping (String) -> Void, queueChanged: @escaping (Int) -> Void,
         canSend: @escaping () -> Bool, send: @escaping (Data, @escaping (Bool) -> Void) -> Void) {
        self.spool = spool
        self.report = report
        self.queueChanged = queueChanged
        self.canSend = canSend
        self.send = send
    }

    func restore() {
        if !spool.interrupted.isEmpty {
            report("上次退出时有 \(spool.interrupted.count) 个任务正在发送，未自动重打。")
            showAlert("有打印任务曾中断", "请确认打印机的实际出纸，再决定是否重新提交。")
            for file in spool.interrupted {
                do { try spool.remove(file) }
                catch { report("清理中断任务失败：\(error.localizedDescription)") }
            }
        }
        showPending()
    }

    func accept(_ job: PrintJob, done: (Bool) -> Void) {
        do {
            try spool.enqueue(job)
            done(true)
            report("打印任务已接收，等待确认")
            advance()
        } catch {
            done(false)
            report("无法保存待预览任务：\(error.localizedDescription)")
            showAlert("接收打印任务失败", error.localizedDescription)
        }
    }

    func showPending() {
        if let window = window { window.present() } else { advance() }
    }

    func check(_ run: (@escaping (Bool) -> Void) -> Void) {
        guard !checking, !sending, spool.pending.isEmpty else {
            report("请先处理当前打印任务")
            return
        }
        checking = true
        run { [weak self] _ in
            self?.checking = false
            self?.advance()
        }
    }

    private func advance() {
        queueChanged(spool.pending.count)
        guard !sending, !loading, !checking, window == nil, let url = spool.pending.first else { return }
        loading = true
        decoder.async { [weak self] in
            guard let self = self else { return }
            let job = Result { try self.spool.read(url) }
            let pages = job.flatMap { job in Result { try LabelPage.parse(job.data) } }
            DispatchQueue.main.async {
                self.loading = false
                let ready = try? job.get()
                let jobTitle = ready?.title ?? ""
                let title = jobTitle.isEmpty ? "标签打印任务" : jobTitle
                let error: Error?
                if case .failure(let failure) = pages { error = failure } else { error = nil }
                let preview = PrintPreviewWindow(title: title, pages: (try? pages.get()) ?? [],
                                                 failure: error?.localizedDescription,
                                                 confirm: { [weak self] in
                    if let ready = ready { self?.confirm(url, job: ready) }
                }, cancel: { [weak self] in self?.cancel(url) })
                self.window = preview
                preview.present()
            }
        }
    }

    private func cancel(_ url: URL) {
        do {
            try spool.remove(url)
            hidePreview()
            report("已取消打印任务")
            advance()
        } catch {
            showAlert("取消任务失败", error.localizedDescription)
        }
    }

    private func confirm(_ url: URL, job: PrintJob) {
        guard canSend() else { return }
        let active: URL
        do { active = try spool.start(url) }
        catch { showAlert("无法开始打印", error.localizedDescription); return }
        sending = true
        hidePreview()
        queueChanged(spool.pending.count)
        send(job.data) { [weak self] success in
            guard let self = self else { return }
            do { try self.spool.remove(active) }
            catch { self.report("无法清理打印任务：\(error.localizedDescription)") }
            if !success {
                self.showAlert("蓝牙打印发送失败", "请查看实际出纸和菜单栏的打印记录，再决定是否重新提交。")
            }
            self.sending = false
            self.advance()
        }
    }

    private func hidePreview() {
        window?.window?.orderOut(nil)
        window = nil
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
