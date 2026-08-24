//
//  ContextCapture.swift
//  Amethyst
//
//  Native replacement for the Hammerspoon context + attention capture pipeline.
//  Writes the existing ~/.context/YYYY-MM-DD.jsonl schema so hscontext,
//  attention, focus-time, context-search, life-timeline, and life-metrics keep
//  working without a second Accessibility-privileged automation app.
//

import Cocoa
import CoreGraphics
import Foundation

final class ContextCapture: NSObject {
    static let shared = ContextCapture()

    /// Supplied by WindowManager so snapshots include tracked background-Space windows,
    /// not just the windows AX happens to expose on the active Space.
    var windowSnapshotProvider: (() -> [[String: Any]])?

    private let contextDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".context", isDirectory: true)
    private let writerQueue = DispatchQueue(label: "com.amethyst.context-capture.writer")
    private let pulseInterval: TimeInterval = 15
    private let idleThreshold: TimeInterval = 120

    private var inputTap: CFMachPort?
    private var inputTapSource: CFRunLoopSource?
    private var inputTapRetryTimer: Timer?
    private var focusTimer: Timer?
    private var pulseTimer: Timer?
    private var idleTimer: Timer?
    private var lastFocusFingerprint: String?
    private var lastWindowSnapshotFingerprint: String?
    private var isIdle = false
    private var keys = 0
    private var clicks = 0
    private var scrolls = 0
    private var started = false

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private override init() {
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true

        do {
            try FileManager.default.createDirectory(at: contextDirectory, withIntermediateDirectories: true)
        } catch {
            log.error("Context capture could not create directory: \(error)")
            return
        }

        setUpWorkspaceObservers()
        setUpInputTap()
        setUpTimers()

        append(event: "startup", data: ["capture": "amethyst"])
        captureFocus(force: true)
        emitActivityPulse()
        captureWindowSnapshot(force: true)
        checkIdle()
        log.info("Context capture started: ~/.context (focus 1s, activity/window snapshots 15s, idle 120s)")
    }

    private func setUpWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(activeSpaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(screenDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screenDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionDidResignActive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionDidBecomeActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    private func setUpTimers() {
        focusTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.captureFocus()
        }
        pulseTimer = Timer(timeInterval: pulseInterval, repeats: true) { [weak self] _ in
            self?.emitActivityPulse()
            self?.captureWindowSnapshot()
        }
        idleTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }

        if let focusTimer { RunLoop.main.add(focusTimer, forMode: .common) }
        if let pulseTimer { RunLoop.main.add(pulseTimer, forMode: .common) }
        if let idleTimer { RunLoop.main.add(idleTimer, forMode: .common) }
    }

    private func setUpInputTap() {
        let eventTypes: [CGEventType] = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let capture = Unmanaged<ContextCapture>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = capture.inputTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            capture.recordInput(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        inputTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let inputTap else {
            log.error("Context capture input tap unavailable (Accessibility permission?); retrying")
            if inputTapRetryTimer == nil {
                inputTapRetryTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                    guard let self, self.inputTap == nil else { return }
                    self.setUpInputTap()
                }
                if let inputTapRetryTimer { RunLoop.main.add(inputTapRetryTimer, forMode: .common) }
            }
            return
        }
        inputTapRetryTimer?.invalidate()
        inputTapRetryTimer = nil
        inputTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, inputTap, 0)
        if let inputTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), inputTapSource, .commonModes)
        }
        CGEvent.tapEnable(tap: inputTap, enable: true)
    }

    private func recordInput(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            let modifierKeyCodes: Set<Int64> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
            if !modifierKeyCodes.contains(event.getIntegerValueField(.keyboardEventKeycode)) {
                keys += 1
            }
        case .scrollWheel:
            scrolls += 1
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            clicks += 1
        default:
            break
        }
    }

    private func focusedInfo() -> [String: Any] {
        let application = NSWorkspace.shared.frontmostApplication
        let window = AXWindow.currentlyFocused()
        let appName = application?.localizedName ?? "unknown"
        let screenName = window?.screen()?.screen.localizedName ?? "unknown"

        var data: [String: Any] = [
            "app": appName,
            "title": window?.title() ?? "",
            "screen": screenName,
        ]
        if let bundle = application?.bundleIdentifier {
            data["bundle"] = bundle
        }
        if let window, let space = CGWindowsInfo<AXWindow>.windowSpace(window) {
            data["space"] = space
        }
        return data
    }

    private func captureFocus(force: Bool = false) {
        let info = focusedInfo()
        let fingerprint = [
            info["app"] as? String ?? "",
            info["title"] as? String ?? "",
            info["screen"] as? String ?? "",
            String(info["space"] as? Int ?? -1),
        ].joined(separator: "\u{1f}")
        guard force || fingerprint != lastFocusFingerprint else { return }
        lastFocusFingerprint = fingerprint
        append(event: "focus", data: info)
    }

    private func emitActivityPulse() {
        var data = focusedInfo()
        data["keys"] = keys
        data["clicks"] = clicks
        data["scrolls"] = scrolls
        data["idle_s"] = Int(idleSeconds())
        data["pulse_s"] = Int(pulseInterval)
        if let problem = currentProblemName() {
            data["problem"] = problem
        }
        keys = 0
        clicks = 0
        scrolls = 0
        append(event: "activity", data: data)
    }

    /// Records every manageable top-level window across all Spaces. Focus events only
    /// describe the window Zach touched; this snapshot preserves the background layout
    /// needed to reconstruct the desktop after an unexpected restart.
    private func captureWindowSnapshot(force: Bool = false) {
        var snapshot = windowSnapshotProvider?() ?? []

        snapshot.sort { lhs, rhs in
            let leftSpace = lhs["space"] as? Int ?? Int.max
            let rightSpace = rhs["space"] as? Int ?? Int.max
            if leftSpace != rightSpace { return leftSpace < rightSpace }
            let leftApp = lhs["app"] as? String ?? ""
            let rightApp = rhs["app"] as? String ?? ""
            if leftApp != rightApp { return leftApp < rightApp }
            return (lhs["window_id"] as? Int ?? 0) < (rhs["window_id"] as? Int ?? 0)
        }

        guard JSONSerialization.isValidJSONObject(snapshot),
              let encoded = try? JSONSerialization.data(withJSONObject: snapshot),
              let fingerprint = String(data: encoded, encoding: .utf8) else {
            log.error("Context capture could not encode window snapshot")
            return
        }
        guard force || fingerprint != lastWindowSnapshotFingerprint else { return }
        lastWindowSnapshotFingerprint = fingerprint
        append(event: "window_snapshot", data: ["windows": snapshot])
    }

    private func checkIdle() {
        let seconds = idleSeconds()
        if seconds >= idleThreshold, !isIdle {
            isIdle = true
            append(event: "idle_start", data: ["idle_seconds": Int(seconds)])
        } else if seconds < idleThreshold, isIdle {
            isIdle = false
            append(event: "idle_end")
        }
    }

    private func idleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private func currentProblemName() -> String? {
        let url = contextDirectory.appendingPathComponent("current-problem.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String,
              !name.isEmpty else {
            return nil
        }
        return name
    }

    private func append(event: String, data: [String: Any] = [:]) {
        var record = data
        record["ts"] = Self.timestampFormatter.string(from: Date())
        record["event"] = event

        guard JSONSerialization.isValidJSONObject(record),
              let encoded = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: encoded, encoding: .utf8) else {
            log.error("Context capture could not encode event: \(event)")
            return
        }
        line += "\n"
        let directory = contextDirectory

        writerQueue.async {
            let file = directory.appendingPathComponent(Self.localDateString() + ".jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: file) else {
                log.error("Context capture could not open: \(file.path)")
                return
            }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                if let bytes = line.data(using: .utf8) {
                    try handle.write(contentsOf: bytes)
                }
            } catch {
                log.error("Context capture write failed: \(error)")
            }
        }
    }

    private static func localDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    @objc private func applicationActivated(_ notification: Notification) {
        captureFocus(force: true)
    }

    @objc private func activeSpaceChanged(_ notification: Notification) {
        let info = focusedInfo()
        var data: [String: Any] = ["screen": info["screen"] ?? "unknown"]
        if let space = info["space"] {
            data["space"] = space
        }
        append(event: "space", data: data)
        captureFocus(force: true)
        captureWindowSnapshot()
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        captureWindowSnapshot(force: true)
        append(event: "sleep")
    }

    @objc private func systemDidWake(_ notification: Notification) {
        isIdle = false
        append(event: "wake")
        captureFocus(force: true)
    }

    @objc private func screenDidSleep(_ notification: Notification) {
        append(event: "screen_sleep")
    }

    @objc private func screenDidWake(_ notification: Notification) {
        append(event: "screen_wake")
    }

    @objc private func sessionDidResignActive(_ notification: Notification) {
        captureWindowSnapshot(force: true)
        append(event: "lock")
    }

    @objc private func sessionDidBecomeActive(_ notification: Notification) {
        isIdle = false
        append(event: "unlock")
        captureFocus(force: true)
    }
}
