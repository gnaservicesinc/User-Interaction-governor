import AppKit
import AVFoundation
import AVKit
import Darwin
import Foundation
import GovernorCore
import UIGRendererSupport

if CommandLine.arguments.dropFirst() == ["--version"] {
    print("uig-renderer \(governorVersion)")
    exit(0)
}

private final class EventWriter: @unchecked Sendable {
    private let lock = NSLock()

    func send(_ event: RendererEvent) {
        guard var data = try? governorJSONEncoder().encode(event) else { return }
        data.append(0x0A)
        lock.lock()
        try? FileHandle.standardOutput.write(contentsOf: data)
        lock.unlock()
    }
}

private struct StepResponse {
    var outcome: String
    var closeReason: String
    var status: Int?
    var buttonNumber: Int?
    var buttonString: String?
    var filePath: String?
    var mediaType: String?
    var loopsRan: Int?
    var escaped: Bool?
    var value: String?
    var confirmed: Bool?
    var error: StructuredError?
}

private final class RendererController: NSObject, NSApplicationDelegate {
    let request: RendererRequest
    let writer = EventWriter()
    var index = 0
    var results: [StepResult] = []
    var firstShownAt: Date?
    var firstShownUptime: TimeInterval?
    var currentShownAt: Date?
    var currentShownUptime: TimeInterval?
    var activeOwner: AnyObject?
    var stopped = false

    init(request: RendererRequest) { self.request = request }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        showCurrentStep()
        DispatchQueue.global(qos: .utility).async {
            _ = FileHandle.standardInput.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard !self.stopped else { return }
                self.stopped = true
                NSApp.terminate(nil)
            }
        }
    }

    private func showCurrentStep() {
        guard request.steps.indices.contains(index) else { finishTopLevel(outcome: "completed", error: nil); return }
        let step = request.steps[index]
        let progress = request.steps.count > 1 ? "Step \(index + 1) of \(request.steps.count)" : nil
        switch step.uiType {
        case .display:
            activeOwner = StandardDialog.display(step: step, progress: progress, shown: didShow, completion: complete)
        case .choice:
            activeOwner = StandardDialog.choice(step: step, progress: progress, shown: didShow, completion: complete)
        case .entry:
            activeOwner = StandardDialog.entry(step: step, progress: progress, shown: didShow, completion: complete)
        case .confirm:
            activeOwner = StandardDialog.confirm(step: step, progress: progress, shown: didShow, completion: complete)
        case .file:
            activeOwner = FileDialog(step: step, shown: didShow, completion: complete)
        case .media:
            let media = MediaDialog(step: step, progress: progress, shown: didShow, completion: complete, startupFailure: failBeforePresentation)
            activeOwner = media
            media.start()
        }
    }

    private func didShow() {
        guard currentShownAt == nil, !stopped else { return }
        let now = Date()
        currentShownAt = now
        currentShownUptime = ProcessInfo.processInfo.systemUptime
        if firstShownAt == nil {
            firstShownAt = now
            firstShownUptime = currentShownUptime
        }
        writer.send(RendererEvent(kind: .shown, uuid: request.uuid, runNumber: request.runNumber, workerToken: request.workerToken, stepIndex: index, shownAt: TimeStamp.string(now), stepResult: nil, result: nil, error: nil))
    }

    private func complete(_ response: StepResponse) {
        guard !stopped, request.steps.indices.contains(index) else { return }
        let now = Date()
        var result = StepResult(index: index, uiType: request.steps[index].uiType, outcome: response.outcome)
        result.closeReason = response.closeReason
        result.status = response.status
        result.shownAt = currentShownAt.map(TimeStamp.string)
        result.finishedAt = TimeStamp.string(now)
        if let start = currentShownUptime { result.length = milliseconds(ProcessInfo.processInfo.systemUptime - start) }
        result.buttonNumber = response.buttonNumber
        result.buttonString = response.buttonString
        result.filePath = response.filePath
        result.mediaType = response.mediaType
        result.loopsRan = response.loopsRan
        result.escaped = response.escaped
        result.value = response.value
        result.confirmed = response.confirmed
        result.error = response.error.map(ResultError.init)
        results.append(result)
        writer.send(RendererEvent(kind: .stepCompleted, uuid: request.uuid, runNumber: request.runNumber, workerToken: request.workerToken, stepIndex: index, shownAt: nil, stepResult: result, result: nil, error: nil))
        let advances = response.outcome == "accepted" || response.outcome == "completed"
        if advances, index + 1 < request.steps.count {
            index += 1
            currentShownAt = nil
            currentShownUptime = nil
            activeOwner = nil
            showCurrentStep()
            return
        }
        for skippedIndex in (index + 1)..<request.steps.count {
            var skipped = StepResult(index: skippedIndex, uiType: request.steps[skippedIndex].uiType, outcome: "skipped")
            skipped.skipReason = "previous_step_stopped"
            results.append(skipped)
        }
        let topOutcome: String
        switch response.outcome {
        case "accepted", "completed": topOutcome = "completed"
        case "cancelled": topOutcome = "cancelled"
        case "dismissed": topOutcome = "dismissed"
        default: topOutcome = "failed"
        }
        finishTopLevel(outcome: topOutcome, error: response.error)
    }

    private func failBeforePresentation(_ error: StructuredError) {
        guard !stopped else { return }
        writer.send(RendererEvent(kind: .failed, uuid: request.uuid, runNumber: request.runNumber, workerToken: request.workerToken, stepIndex: index, shownAt: nil, stepResult: nil, result: nil, error: error))
        stopped = true
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private func finishTopLevel(outcome: String, error: StructuredError?) {
        guard !stopped else { return }
        stopped = true
        let now = Date()
        let length = firstShownUptime.map { milliseconds(ProcessInfo.processInfo.systemUptime - $0) }
        let result = ResultDocument(
            uuid: request.uuid, runNumber: request.runNumber, outcome: outcome,
            startedAt: firstShownAt.map(TimeStamp.string), finishedAt: TimeStamp.string(now),
            length: length, error: error.map(ResultError.init), steps: results.sorted { $0.index < $1.index }
        )
        writer.send(RendererEvent(kind: .completed, uuid: request.uuid, runNumber: request.runNumber, workerToken: request.workerToken, stepIndex: nil, shownAt: nil, stepResult: nil, result: result, error: nil))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSApp.terminate(nil) }
    }
}

private final class GovernorWindow: NSWindow {
    var escapeHandler: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escapeHandler?() }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 { escapeHandler?(); return }
        super.sendEvent(event)
    }
}

private final class StandardDialog: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private let step: StepDefinition
    private let completion: (StepResponse) -> Void
    private let shown: () -> Void
    private var finished = false
    private var window: GovernorWindow!
    private var inputField: NSTextField?
    private var inputTextView: NSTextView?
    private var errorLabel: NSTextField?

    private init(step: StepDefinition, progress: String?, shown: @escaping () -> Void, completion: @escaping (StepResponse) -> Void) {
        self.step = step
        self.shown = shown
        self.completion = completion
        super.init()
        let height: CGFloat = usesScrollableChoices ? 520 : (step.uiType == .entry && step.entryType == "multiline" ? 430 : 320)
        window = GovernorWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.title = step.title ?? Self.defaultTitle(step)
        window.escapeHandler = { [weak self] in self?.dismiss(escape: true) }
        window.contentView = buildContent(progress: progress)
        window.center()
    }

    static func display(step: StepDefinition, progress: String?, shown: @escaping () -> Void, completion: @escaping (StepResponse) -> Void) -> StandardDialog {
        let owner = StandardDialog(step: step, progress: progress, shown: shown, completion: completion)
        owner.present()
        return owner
    }

    static func choice(step: StepDefinition, progress: String?, shown: @escaping () -> Void, completion: @escaping (StepResponse) -> Void) -> StandardDialog {
        let owner = StandardDialog(step: step, progress: progress, shown: shown, completion: completion)
        owner.present()
        return owner
    }

    static func entry(step: StepDefinition, progress: String?, shown: @escaping () -> Void, completion: @escaping (StepResponse) -> Void) -> StandardDialog {
        let owner = StandardDialog(step: step, progress: progress, shown: shown, completion: completion)
        owner.present()
        return owner
    }

    static func confirm(step: StepDefinition, progress: String?, shown: @escaping () -> Void, completion: @escaping (StepResponse) -> Void) -> StandardDialog {
        let owner = StandardDialog(step: step, progress: progress, shown: shown, completion: completion)
        owner.present()
        return owner
    }

    private static func defaultTitle(_ step: StepDefinition) -> String {
        switch step.uiType {
        case .confirm: return "Confirm"
        case .entry: return "Provide a value"
        default: return "Notice"
        }
    }

    private func messageText() -> String {
        if let message = step.message { return message }
        switch step.entryType {
        case "number": return "Enter a number"
        case "multiline": return "Enter your message"
        default: return "Enter text"
        }
    }

    private var usesScrollableChoices: Bool {
        step.uiType == .choice && (step.buttons.count > 4 || step.buttons.contains(where: { $0.count > 24 }))
    }

    private func buildContent(progress: String?) -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        if let progress {
            let label = NSTextField(labelWithString: progress)
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabelColor
            root.addArrangedSubview(label)
        }
        let (scroll, message) = RendererLayout.makeScrollableTextView(
            text: messageText(), editable: false, height: 96, border: .noBorder
        )
        message.textContainerInset = NSSize(width: 0, height: 4)
        message.setAccessibilityLabel("Message")
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true

        if step.uiType == .entry { addEntry(to: root) }
        let buttons = makeButtons()
        root.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        return root
    }

    private func addEntry(to root: NSStackView) {
        if step.entryType == "multiline" {
            let (scroll, textView) = RendererLayout.makeScrollableTextView(
                text: step.defaultValue ?? "", editable: true, height: 120, border: .bezelBorder
            )
            textView.delegate = self
            textView.setAccessibilityLabel("Value")
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
            root.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
            inputTextView = textView
        } else {
            let field = NSTextField(string: step.defaultValue ?? "")
            field.placeholderString = step.entryType == "number" ? "Number" : "Value"
            field.delegate = self
            field.setAccessibilityLabel("Value")
            root.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
            inputField = field
        }
        let error = NSTextField(labelWithString: "")
        error.textColor = .systemRed
        error.isHidden = true
        error.maximumNumberOfLines = 2
        root.addArrangedSubview(error)
        error.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40).isActive = true
        errorLabel = error
    }

    private func makeButtons() -> NSView {
        let row = NSStackView()
        row.orientation = usesScrollableChoices ? .vertical : .horizontal
        row.alignment = usesScrollableChoices ? .width : .centerY
        row.distribution = .fillEqually
        row.spacing = 10
        switch step.uiType {
        case .display:
            row.addArrangedSubview(button(step.button ?? "OK", action: #selector(acceptDisplay), key: "\r"))
        case .choice:
            for (index, label) in step.buttons.enumerated() {
                let control = button(label, action: #selector(choose(_:)), key: index == 0 ? "\r" : nil)
                control.tag = index
                control.toolTip = label
                control.cell?.wraps = true
                control.cell?.lineBreakMode = .byWordWrapping
                row.addArrangedSubview(control)
            }
        case .entry:
            row.addArrangedSubview(button("Cancel", action: #selector(cancel), key: "\u{1b}"))
            let done = button(step.button ?? "Done", action: #selector(submitEntry), key: "\r")
            if step.entryType == "multiline" { done.keyEquivalentModifierMask = [.control] }
            row.addArrangedSubview(done)
        case .confirm:
            row.addArrangedSubview(button(step.cancelLabel ?? "Cancel", action: #selector(cancelConfirm), key: "\u{1b}"))
            row.addArrangedSubview(button(step.confirmLabel ?? "Confirm", action: #selector(confirm), key: nil))
        default: break
        }
        if usesScrollableChoices {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            row.frame = NSRect(x: 0, y: 0, width: 480, height: CGFloat(step.buttons.count * 36))
            row.autoresizingMask = [.width]
            scroll.documentView = row
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
            scroll.setAccessibilityLabel("Choices")
            return scroll
        }
        return row
    }

    private func button(_ title: String, action: Selector, key: String?) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        control.bezelStyle = .rounded
        control.setAccessibilityLabel(title)
        if let key { control.keyEquivalent = key }
        return control
    }

    private func present() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if step.uiType == .confirm, let cancel = window.contentView?.subviewsRecursive.compactMap({ $0 as? NSButton }).first {
            window.makeFirstResponder(cancel)
        } else if let input = inputField { window.makeFirstResponder(input) }
        else if let text = inputTextView { window.makeFirstResponder(text) }
        DispatchQueue.main.async { [weak self] in if self?.window.isVisible == true { self?.shown() } }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss(escape: false)
        return false
    }

    private func finish(_ response: StepResponse) {
        guard !finished else { return }
        finished = true
        window.orderOut(nil)
        completion(response)
    }

    private func dismiss(escape: Bool) {
        let extraMedia: (String?, Int?, Bool?) = (nil, nil, nil)
        finish(StepResponse(outcome: "dismissed", closeReason: escape ? "escape" : "window_close", status: -1, buttonNumber: step.uiType == .choice ? -1 : nil, buttonString: nil, filePath: nil, mediaType: extraMedia.0, loopsRan: extraMedia.1, escaped: extraMedia.2, value: nil, confirmed: nil, error: nil))
    }

    @objc private func acceptDisplay() { finish(StepResponse(outcome: "accepted", closeReason: "button", status: 1)) }
    @objc private func choose(_ sender: NSButton) { finish(StepResponse(outcome: "accepted", closeReason: "button", status: 1, buttonNumber: sender.tag, buttonString: sender.title)) }
    @objc private func cancel() { finish(StepResponse(outcome: "cancelled", closeReason: "cancel_button", status: 0, value: nil)) }
    @objc private func cancelConfirm() { finish(StepResponse(outcome: "cancelled", closeReason: "cancel_button", status: 0, confirmed: false)) }
    @objc private func confirm() { finish(StepResponse(outcome: "accepted", closeReason: "button", status: 1, confirmed: true)) }

    @objc private func submitEntry() {
        var value = inputTextView?.string ?? inputField?.stringValue ?? ""
        value = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        do {
            try DefinitionValidator.validateEntry(value, step: step)
            if step.entryType == "number" { value = try DefinitionValidator.normalizedDecimal(value) }
            finish(StepResponse(outcome: "accepted", closeReason: "button", status: 1, value: value))
        } catch let error as StructuredError {
            errorLabel?.stringValue = error.message
            errorLabel?.isHidden = false
            if let inputField { window.makeFirstResponder(inputField) }
            else if let inputTextView { window.makeFirstResponder(inputTextView) }
            NSSound.beep()
        } catch { NSSound.beep() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { submitEntry(); return true }
        return false
    }
}

private extension NSView {
    var subviewsRecursive: [NSView] { subviews + subviews.flatMap(\.subviewsRecursive) }
}

private final class FileDialog: NSObject, NSOpenSavePanelDelegate {
    private let step: StepDefinition
    private let shown: () -> Void
    private let completion: (StepResponse) -> Void
    private var panel: NSSavePanel!

    init(step: StepDefinition, shown: @escaping () -> Void, completion: @escaping (StepResponse) -> Void) {
        self.step = step
        self.shown = shown
        self.completion = completion
        super.init()
        if step.mode == "open" {
            let open = NSOpenPanel()
            open.canChooseFiles = true
            open.canChooseDirectories = false
            open.allowsMultipleSelection = false
            panel = open
        } else {
            let save = NSSavePanel()
            save.canCreateDirectories = true
            if let filename = step.filename { save.nameFieldStringValue = filename }
            panel = save
        }
        panel.title = step.title ?? (step.mode == "open" ? "Open file" : "Save file")
        panel.directoryURL = URL(fileURLWithPath: step.directory ?? FileManager.default.homeDirectoryForCurrentUser.path, isDirectory: true)
        panel.delegate = self
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = self.panel.url {
                self.completion(StepResponse(outcome: "accepted", closeReason: "button", status: 1, filePath: url.standardizedFileURL.path))
            } else {
                self.completion(StepResponse(outcome: "cancelled", closeReason: "cancel_button", status: 0, filePath: nil))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in if self?.panel.isVisible == true { self?.shown() } }
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return true }
        return filenameMatchesFilters(url.lastPathComponent, filters: step.filters)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard filenameMatchesFilters(url.lastPathComponent, filters: step.filters) else {
            throw StructuredError("INVALID_ARGUMENT", "Choose a filename matching: " + step.filters.joined(separator: ", "))
        }
    }
}

private final class MediaDialog: NSObject, NSWindowDelegate, @unchecked Sendable {
    private let step: StepDefinition
    private let progress: String?
    private let shown: () -> Void
    private let completion: (StepResponse) -> Void
    private let startupFailure: (StructuredError) -> Void
    private var window: GovernorWindow?
    private var player: AVPlayer?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var timer: Timer?
    private var loopsRan = 0
    private var escaped = false
    private var finished = false

    init(step: StepDefinition, progress: String?, shown: @escaping () -> Void, completion: @escaping (StepResponse) -> Void, startupFailure: @escaping (StructuredError) -> Void) {
        self.step = step
        self.progress = progress
        self.shown = shown
        self.completion = completion
        self.startupFailure = startupFailure
    }

    func start() {
        guard let path = step.path else { startupFailure(StructuredError("UNSUPPORTED_MEDIA", "missing media path")); return }
        if step.mediaType == "image" { startImage(path); return }
        startAV(path)
    }

    private func makeWindow(defaultSize: NSSize) -> GovernorWindow {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let fitted = RendererLayout.fittedMediaWindowSize(
            defaultSize: defaultSize,
            requestedWidth: step.width,
            requestedHeight: step.height,
            visibleSize: visible
        )
        let window = GovernorWindow(contentRect: NSRect(origin: .zero, size: fitted), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = step.title ?? URL(fileURLWithPath: step.path ?? "Media").lastPathComponent
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.escapeHandler = { [weak self] in self?.escaped = true; self?.finishDismissed(reason: "escape") }
        window.center()
        self.window = window
        return window
    }

    private func startImage(_ path: String) {
        guard let image = NSImage(contentsOfFile: path), image.isValid else { startupFailure(StructuredError("UNSUPPORTED_MEDIA", "image could not be decoded")); return }
        let size = image.size.width > 0 && image.size.height > 0 ? image.size : NSSize(width: 640, height: 480)
        let window = makeWindow(defaultSize: NSSize(width: max(360, size.width), height: max(240, size.height + 48)))
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        if let progress {
            let label = NSTextField(labelWithString: progress)
            label.textColor = .secondaryLabelColor
            root.addArrangedSubview(label)
        }
        let view = NSImageView()
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setAccessibilityLabel(window.title)
        root.addArrangedSubview(view)
        let close = NSButton(title: "Close", target: self, action: #selector(closeMedia))
        root.addArrangedSubview(close)
        window.contentView = root
        present(window)
        if let autoClose = step.autoClose {
            timer = Timer.scheduledTimer(withTimeInterval: autoClose, repeats: false) { [weak self] _ in self?.finishCompleted(reason: "timeout") }
        }
    }

    private func startAV(_ path: String) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let mediaType: AVMediaType = step.mediaType == "video" ? .video : .audio
        let owner = self
        Task { [owner] in
            do {
                let tracks = try await asset.loadTracks(withMediaType: mediaType)
                await MainActor.run {
                    guard !owner.finished else { return }
                    guard !tracks.isEmpty else {
                        owner.finished = true
                        owner.startupFailure(StructuredError("UNSUPPORTED_MEDIA", "file does not contain a \(owner.step.mediaType ?? "requested") track"))
                        return
                    }
                    owner.preparePlayer(asset)
                }
            } catch {
                await MainActor.run {
                    guard !owner.finished else { return }
                    owner.finished = true
                    owner.startupFailure(StructuredError("UNSUPPORTED_MEDIA", error.localizedDescription))
                }
            }
        }
    }

    private func preparePlayer(_ asset: AVAsset) {
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.volume = Float(step.volume ?? 100) / 100
        self.player = player
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                if item.status == .failed {
                    let error = StructuredError("UNSUPPORTED_MEDIA", item.error?.localizedDescription ?? "media could not be decoded")
                    if self.window == nil { self.startupFailure(error); self.finished = true }
                    else { self.finish(StepResponse(outcome: "failed", closeReason: "renderer_error", status: nil, mediaType: self.step.mediaType, loopsRan: self.loopsRan, escaped: self.escaped, error: error)) }
                } else if item.status == .readyToPlay, self.window == nil {
                    self.presentPlayer(player, item: item)
                }
            }
        }
    }

    private func presentPlayer(_ player: AVPlayer, item: AVPlayerItem) {
        let video = step.mediaType == "video"
        let window = makeWindow(defaultSize: video ? NSSize(width: 720, height: 480) : NSSize(width: 520, height: 150))
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        if let progress {
            let label = NSTextField(labelWithString: progress)
            label.textColor = .secondaryLabelColor
            root.addArrangedSubview(label)
        }
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .minimal
        playerView.videoGravity = .resizeAspect
        playerView.setAccessibilityLabel(window.title)
        playerView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        playerView.setContentHuggingPriority(.defaultLow, for: .vertical)
        playerView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        playerView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(playerView)
        let close = NSButton(title: "Close", target: self, action: #selector(closeMedia))
        root.addArrangedSubview(close)
        window.contentView = root
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in self?.playbackEnded() }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            guard let self else { return }
            let detail = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "media playback failed"
            self.finish(StepResponse(outcome: "failed", closeReason: "renderer_error", status: nil, mediaType: self.step.mediaType, loopsRan: self.loopsRan, escaped: self.escaped, error: StructuredError("UNSUPPORTED_MEDIA", detail)))
        }
        player.play()
        present(window)
    }

    private func present(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in if self?.window?.isVisible == true { self?.shown() } }
    }

    private func playbackEnded() {
        loopsRan += 1
        if step.forever || loopsRan < (step.plays ?? 1) {
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in self?.player?.play() }
        } else { finishCompleted(reason: "playback_complete") }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { finishDismissed(reason: "window_close"); return false }
    @objc private func closeMedia() { finishCompleted(reason: "button") }

    private func finishCompleted(reason: String) {
        finish(StepResponse(outcome: "completed", closeReason: reason, status: 1, mediaType: step.mediaType, loopsRan: step.mediaType == "image" ? 0 : loopsRan, escaped: false))
    }

    private func finishDismissed(reason: String) {
        finish(StepResponse(outcome: "dismissed", closeReason: reason, status: -1, mediaType: step.mediaType, loopsRan: step.mediaType == "image" ? 0 : loopsRan, escaped: escaped))
    }

    private func finish(_ response: StepResponse) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        window?.orderOut(nil)
        completion(response)
    }
}

guard let line = readLine(), let data = line.data(using: .utf8),
      let request = try? governorJSONDecoder().decode(RendererRequest.self, from: data) else {
    exit(2)
}

private let application = NSApplication.shared
private let delegate = RendererController(request: request)
application.delegate = delegate
application.run()
