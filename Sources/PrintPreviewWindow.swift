import AppKit

final class PrintPreviewWindow: NSWindowController {
    private let detail = NSTextField(labelWithString: "")
    private let pageNumber = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let canvas = NSView()
    private let picture = NSImageView()
    private let error = NSTextField(wrappingLabelWithString: "")
    private let previous = NSButton(title: "上一页", target: nil, action: nil)
    private let next = NSButton(title: "下一页", target: nil, action: nil)
    private let zoom = NSButton(title: "放大", target: nil, action: nil)
    private let confirm = NSButton(title: "确认打印", target: nil, action: nil)
    private var index = 0
    private var enlarged = false
    private let pages: [LabelPage]
    private let onConfirm: () -> Void
    private let onCancel: () -> Void

    init(title: String, pages: [LabelPage], failure: String?, confirm: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.pages = pages
        self.onConfirm = confirm
        self.onCancel = cancel
        let height = min(690, (NSScreen.main?.visibleFrame.height ?? 820) - 70)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: height),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "启锐打印预览"
        window.center()
        window.isReleasedWhenClosed = false

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.textColor = .secondaryLabelColor
        error.stringValue = failure ?? ""
        error.textColor = .systemRed
        error.isHidden = failure == nil

        picture.imageScaling = .scaleAxesIndependently
        picture.setAccessibilityLabel("标签打印图像")
        canvas.addSubview(picture)
        scroll.documentView = canvas
        scroll.borderType = .bezelBorder
        scroll.backgroundColor = .windowBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.isHidden = pages.isEmpty

        let cancelButton = NSButton(title: "取消任务", target: self, action: #selector(cancelJob))
        let buttons: [(NSButton, Selector)] = [(previous, #selector(previousPage)), (next, #selector(nextPage)),
                                                (zoom, #selector(toggleZoom)), (self.confirm, #selector(confirmJob))]
        for (button, action) in buttons {
            button.target = self
            button.action = action
        }
        self.confirm.isEnabled = failure == nil && !pages.isEmpty
        cancelButton.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [previous, pageNumber, next, zoom])
        let actions = NSStackView(views: [cancelButton, self.confirm])
        let controls = NSStackView(views: [footer, NSView(), actions])
        controls.distribution = .fill
        let body = NSStackView(views: [heading, detail, error, scroll, controls])
        body.orientation = .vertical
        body.alignment = .left
        body.spacing = 12
        body.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        body.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: content.topAnchor), body.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor), body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            heading.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40),
            error.widthAnchor.constraint(equalTo: heading.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: heading.widthAnchor),
            controls.widthAnchor.constraint(equalTo: heading.widthAnchor)
        ])
        if pages.isEmpty {
            footer.isHidden = true
            window.setContentSize(NSSize(width: 640, height: 150))
        }
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        renderPage()
    }

    private func renderPage() {
        guard !pages.isEmpty else { return }
        let page = pages[index]
        let total = pages.reduce(0) { $0 + $1.copies }
        detail.stringValue = "\(page.widthMM.formattedMM) × \(page.heightMM.formattedMM) mm   ·   共 \(total) 张"
        if page.copies > 1 { detail.stringValue += "   ·   本页 \(page.copies) 份" }
        pageNumber.stringValue = "\(index + 1) / \(pages.count)"
        previous.isEnabled = index > 0
        next.isEnabled = index + 1 < pages.count
        zoom.title = enlarged ? "适应窗口" : "放大"
        do {
            let image = try page.image()
            picture.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            let available = scroll.contentView.bounds.size
            let width = CGFloat(image.width)
            let height = CGFloat(image.height)
            let scale = enlarged ? 1 : max(0.01, min((available.width - 24) / width, (available.height - 24) / height))
            let size = NSSize(width: width * scale, height: height * scale)
            canvas.frame = NSRect(origin: .zero, size: NSSize(width: max(available.width, size.width),
                                                               height: max(available.height, size.height)))
            picture.frame = NSRect(x: (canvas.frame.width - size.width) / 2, y: (canvas.frame.height - size.height) / 2,
                                   width: size.width, height: size.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, canvas.frame.height - available.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        } catch {
            picture.image = nil
            self.error.stringValue = error.localizedDescription
            self.error.isHidden = false
            confirm.isEnabled = false
        }
    }

    @objc private func previousPage() {
        guard index > 0 else { return }
        index -= 1
        renderPage()
    }
    @objc private func nextPage() {
        guard index + 1 < pages.count else { return }
        index += 1
        renderPage()
    }
    @objc private func toggleZoom() { enlarged.toggle(); renderPage() }
    @objc private func confirmJob() { if confirm.isEnabled { onConfirm() } }
    @objc private func cancelJob() { onCancel() }
}

private extension Double {
    var formattedMM: String {
        abs(self - rounded()) <= 0.2 ? String(format: "%.0f", self) : String(format: "%.2f", self)
    }
}
