//
//  WindowManager.swift
//  Amethyst
//
//  Created by Ian Ynda-Hummel on 5/14/16.
//  Copyright © 2016 Ian Ynda-Hummel. All rights reserved.
//

import AppKit
import Carbon
import Foundation
import RxSwift
import Silica
import SwiftyJSON

@_silgen_name("SLSMainConnectionID")
private func mainSLSConnectionID() -> Int32

@_silgen_name("SLSSpaceSetCompatID") @discardableResult
private func setSpaceCompatID(_ connection: Int32, _ spaceID: UInt64, _ workspace: Int32) -> CGError

@_silgen_name("SLSSetWindowListWorkspace") @discardableResult
private func setWindowListWorkspace(
    _ connection: Int32,
    _ windowIDs: UnsafeMutablePointer<CGWindowID>,
    _ windowCount: Int32,
    _ workspace: Int32
) -> CGError

enum TrackingError: Error {
    case unreliableFloating
    case unknownScreen
    case unknownSpace
    case alreadyTracked
}

enum WindowControlError: LocalizedError {
    case invalidRequest(String)
    case windowManagerUnavailable
    case windowNotFound(CGWindowID)
    case spacesUnavailable
    case desktopOutOfRange(Int, Int)
    case sourceSpaceUnknown(CGWindowID)
    case backgroundMoveUnavailable
    case moveFailed(CGWindowID, Int)
    case windowsOnDifferentSpaces(CGWindowID, CGWindowID)

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            return message
        case .windowManagerUnavailable:
            return "window manager is unavailable"
        case let .windowNotFound(windowID):
            return "window \(windowID) is not tracked by Amethyst"
        case .spacesUnavailable:
            return "macOS desktops are unavailable"
        case let .desktopOutOfRange(desktop, count):
            return "desktop \(desktop) does not exist; this Mac currently has \(count) desktops"
        case let .sourceSpaceUnknown(windowID):
            return "could not determine the current desktop for window \(windowID)"
        case .backgroundMoveUnavailable:
            return "macOS 15 blocks background moves of other apps' windows; no desktop was switched"
        case let .moveFailed(windowID, desktop):
            return "window \(windowID) did not reach desktop \(desktop)"
        case let .windowsOnDifferentSpaces(windowID, otherWindowID):
            return "windows \(windowID) and \(otherWindowID) are not on the same desktop"
        }
    }
}

/**
 The tolerant interval between the click and the application of a mouse move from focus.
 
 - Note:
 
 At the time of the check we confirm that the mouse is not _currently_ clicked. However, it is possible that the click happened faster than the focus notification could be processed so that when we process the focus the mouse is no longer clicked. In this case we could incorrectly move the mouse to the center of the focused window.
 
 This value is an approximation of the time between a fast click and the focus event being processed. For values larger than this we would expect the mouse to still be clicked.
 */
private let mouseMoveClickSpeedTolerance: TimeInterval = 0.3

final class WindowManager<Application: ApplicationType>: NSObject, Codable {
    typealias Window = Application.Window
    typealias Screen = Window.Screen

    struct PendingEvent {
        let screen: Screen
        let event: Change<Window>
    }

    private struct UndeterminedApplication {
        let application: NSRunningApplication
        let activationPolicyObservation: NSKeyValueObservation?
        let isFinishedLaunchingObservation: NSKeyValueObservation?

        func invalidate() {
            activationPolicyObservation?.invalidate()
            isFinishedLaunchingObservation?.invalidate()
        }
    }

    enum CodingKeys: String, CodingKey {
        case screens
    }

    let windowTransitionCoordinator: WindowTransitionCoordinator<WindowManager<Application>>
    let focusTransitionCoordinator: FocusTransitionCoordinator<WindowManager<Application>>

    private var applications: [pid_t: AnyApplication<Application>] = [:]
    private var applicationObservations: [pid_t: UndeterminedApplication] = [:]
    private var screens: Screens
    private let windows = Windows()
    private var lastReflowTime = Date()
    private var lastFocusDate: Date?
    private var pendingTabDetection: [Window.WindowID: Window] = [:]
    private var earlyFocusedWindows: Set<Window.WindowID> = []
    private var eventQueue: [PendingEvent] = []
    /// Last active (on-screen, current-space) window IDs per screen after a reflow.
    /// Used to detect silent departures (Mission Control drag, app self-move) that
    /// never deliver remove/space-change notifications — classic empty-pane gaps.
    private var lastActiveWindowIDsByScreen: [String: Set<CGWindowID>] = [:]
    private var activeWindowReconcileTimer: Timer?

    private lazy var mouseStateKeeper = MouseStateKeeper(delegate: self)
    private lazy var applicationEventHandler = ApplicationEventHandler(delegate: self)
    private let userConfiguration: UserConfiguration
    private let disposeBag = DisposeBag()

    init(userConfiguration: UserConfiguration) {
        self.userConfiguration = userConfiguration
        self.screens = Screens()
        self.windowTransitionCoordinator = WindowTransitionCoordinator<WindowManager<Application>>()
        self.focusTransitionCoordinator = FocusTransitionCoordinator<WindowManager<Application>>(userConfiguration: userConfiguration)
        super.init()
        initialize()
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.screens = try values.decode(Screens.self, forKey: .screens)
        self.userConfiguration = UserConfiguration.shared
        self.windowTransitionCoordinator = WindowTransitionCoordinator<WindowManager<Application>>()
        self.focusTransitionCoordinator = FocusTransitionCoordinator<WindowManager<Application>>(userConfiguration: userConfiguration)
        super.init()
        initialize()
    }

    private func initialize() {
        windowTransitionCoordinator.target = self
        focusTransitionCoordinator.target = self

        addWorkspaceNotificationObserver(NSWorkspace.didHideApplicationNotification, selector: #selector(applicationDidHide(_:)))
        addWorkspaceNotificationObserver(NSWorkspace.didUnhideApplicationNotification, selector: #selector(applicationDidUnhide(_:)))
        addWorkspaceNotificationObserver(NSWorkspace.activeSpaceDidChangeNotification, selector: #selector(activeSpaceDidChange(_:)))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        installApplicationMonitor()
        startActiveWindowReconcileTimer()

        reevaluateWindows()
        screens.updateScreens(windowManager: self)
    }

    deinit {
        activeWindowReconcileTimer?.invalidate()
        activeWindowReconcileTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    private func startActiveWindowReconcileTimer() {
        activeWindowReconcileTimer?.invalidate()
        // 1s is enough to close empty-pane gaps without fighting interactive drag.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reconcileActiveWindowsIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        activeWindowReconcileTimer = timer
    }

    func moveWindow(
        withCGID windowID: CGWindowID,
        toDesktop desktop: Int,
        completion: @escaping (Result<String, WindowControlError>) -> Void
    ) {
        guard let spaces = CGSpacesInfo<Window>.spacesForAllScreens(includeOnlyUserSpaces: true) else {
            completion(.failure(.spacesUnavailable))
            return
        }

        let targetIndex = desktop - 1
        guard spaces.indices.contains(targetIndex) else {
            completion(.failure(.desktopOutOfRange(desktop, spaces.count)))
            return
        }
        guard let sourceSpaceID = CGWindowsInfo<Window>.windowSpace(windowID) else {
            completion(.failure(.sourceSpaceUnknown(windowID)))
            return
        }
        guard let sourceIndex = spaces.firstIndex(where: { $0.id == sourceSpaceID }) else {
            completion(.failure(.sourceSpaceUnknown(windowID)))
            return
        }

        if sourceIndex == targetIndex {
            completion(.success("window \(windowID) is already on desktop \(desktop)"))
            return
        }

        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 {
            completion(.failure(.backgroundMoveUnavailable))
            return
        }

        let targetSpaceID = spaces[targetIndex].id
        let connection = mainSLSConnectionID()

        if #available(macOS 14.5, *) {
            // Since macOS 14.5, moving a window without visiting either Space
            // requires temporarily assigning the target Space a workspace ID.
            // This is the same narrow SkyLight operation used by Hammerspoon.
            let temporaryWorkspace: Int32 = 0x79616265
            var mutableWindowID = windowID
            let assignResult = setSpaceCompatID(connection, UInt64(targetSpaceID), temporaryWorkspace)
            let moveResult = setWindowListWorkspace(connection, &mutableWindowID, 1, temporaryWorkspace)
            let resetResult = setSpaceCompatID(connection, UInt64(targetSpaceID), 0)
            log.debug(
                "Background Space move: window=\(windowID) target=\(targetSpaceID) " +
                    "connection=\(connection) results=\(assignResult.rawValue),\(moveResult.rawValue),\(resetResult.rawValue)"
            )
        } else {
            let windowIDs = CGWindowsInfo<Window>.windowIDsArray(windowID)
            CGSMoveWindowsToManagedSpace(connection, windowIDs, targetSpaceID)
        }

        verifyBackgroundMove(
            windowID: windowID,
            targetSpaceID: targetSpaceID,
            desktop: desktop,
            attemptsRemaining: 12,
            completion: completion
        )
    }

    func swapWindows(
        withCGID windowID: CGWindowID,
        otherWindowID: CGWindowID,
        completion: @escaping (Result<String, WindowControlError>) -> Void
    ) {
        guard let window = controlWindow(withCGID: windowID) else {
            completion(.failure(.windowNotFound(windowID)))
            return
        }
        guard let otherWindow = controlWindow(withCGID: otherWindowID) else {
            completion(.failure(.windowNotFound(otherWindowID)))
            return
        }
        guard
            let windowSpace = CGWindowsInfo<Window>.windowSpace(windowID),
            let otherWindowSpace = CGWindowsInfo<Window>.windowSpace(otherWindowID),
            windowSpace == otherWindowSpace
        else {
            completion(.failure(.windowsOnDifferentSpaces(windowID, otherWindowID)))
            return
        }

        executeTransition(.switchWindows(window, otherWindow))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            completion(.success("swapped windows \(windowID) and \(otherWindowID)"))
        }
    }

    private func verifyBackgroundMove(
        windowID: CGWindowID,
        targetSpaceID: CGSSpaceID,
        desktop: Int,
        attemptsRemaining: Int,
        completion: @escaping (Result<String, WindowControlError>) -> Void
    ) {
        if CGWindowsInfo<Window>.windowSpace(windowID) == targetSpaceID {
            windows.regenerateActiveIDCache()
            markAllScreensForReflow()
            completion(.success("moved window \(windowID) to desktop \(desktop) without switching desktops"))
            return
        }
        guard attemptsRemaining > 0 else {
            completion(.failure(.moveFailed(windowID, desktop)))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else {
                completion(.failure(.windowManagerUnavailable))
                return
            }
            self.verifyBackgroundMove(
                windowID: windowID,
                targetSpaceID: targetSpaceID,
                desktop: desktop,
                attemptsRemaining: attemptsRemaining - 1,
                completion: completion
            )
        }
    }

    private func controlWindow(withCGID windowID: CGWindowID) -> Window? {
        if let trackedWindow = windows.windows.first(where: { $0.cgID() == windowID }) {
            return trackedWindow
        }

        let descriptions = CGWindowsInfo<Window>(
            options: .optionIncludingWindow,
            windowID: windowID
        )?.descriptions
        let ownerPID = descriptions?.first(where: { description in
            guard let number = description[kCGWindowNumber as String] as? NSNumber else {
                return false
            }
            return number.uint32Value == windowID
        }).flatMap { description in
            (description[kCGWindowOwnerPID as String] as? NSNumber).map { pid_t($0.int32Value) }
        }

        guard let ownerPID else {
            return nil
        }

        if let application = applications[ownerPID] {
            application.dropWindowsCache()
            if let window = application.windows().first(where: { $0.cgID() == windowID }) {
                return window
            }
        }

        guard let runningApplication = NSRunningApplication(processIdentifier: ownerPID) else {
            return nil
        }
        let application = Application(runningApplication: runningApplication)
        return application.windows().first(where: { $0.cgID() == windowID })
    }

    /// Detect when the live on-screen active set drifts from the last reflow without
    /// Amethyst receiving a remove/space event (e.g. Mission Control window move).
    @objc private func reconcileActiveWindowsIfNeeded() {
        guard userConfiguration.tilingEnabled else {
            return
        }

        // Do not reflow mid-drag / mid-resize or while a reflow just finished applying frames.
        switch mouseStateKeeper.state {
        case .pointing, .doneDragging:
            break
        default:
            return
        }
        guard Date().timeIntervalSince(lastReflowTime) > mouseStateKeeper.dragRaceThresholdSeconds * 2 else {
            return
        }

        windows.regenerateActiveIDCache()

        for screenManager in screens.screenManagers {
            guard let screen = screenManager.screen, let screenID = screen.screenID() else {
                continue
            }

            let activeIDs = Set(windows.activeWindows(onScreen: screen).map { $0.cgID() })
            let previousIDs = lastActiveWindowIDsByScreen[screenID]

            // First observation after launch: seed without forcing a duplicate reflow.
            guard let previousIDs else {
                lastActiveWindowIDsByScreen[screenID] = activeIDs
                continue
            }

            guard previousIDs != activeIDs else {
                continue
            }

            log.debug(
                "Active window set drift: screen=\(screenID) " +
                    "previous=\(previousIDs.sorted()) current=\(activeIDs.sorted()) — reflowing"
            )
            // Update immediately so we do not thrash every tick while the reflow is queued.
            lastActiveWindowIDsByScreen[screenID] = activeIDs
            markScreenForReflow(screen)
        }
    }

    func reset() {
        screens = Screens()
        reevaluateWindows()
        screens.updateScreens(windowManager: self)
    }

    private func addWorkspaceNotificationObserver(_ name: NSNotification.Name, selector: Selector) {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationCenter.addObserver(self, selector: selector, name: name, object: nil)
    }

    @objc func applicationActivated(_ sender: AnyObject) {
        guard let focusedWindow = Window.currentlyFocused(), let screen = focusedWindow.screen() else {
            return
        }
        markScreenForReflow(screen)
//        doMouseFollowsFocus(focusedWindow: focusedWindow)
    }

    @objc func applicationDidLaunch(_ notification: Notification) {
        guard let launchedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        add(runningApplication: launchedApplication)
    }

    @objc func applicationDidTerminate(_ notification: Notification) {
        guard let terminatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        guard let application = applicationWithPID(terminatedApplication.processIdentifier) else {
            return
        }

        remove(application: application)
    }

    @objc func applicationDidHide(_ notification: Notification) {
        guard let hiddenApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        guard let application = applicationWithPID(hiddenApplication.processIdentifier) else {
            return
        }

        deactivate(application: application)
    }

    @objc func applicationDidUnhide(_ notification: Notification) {
        guard let unhiddenApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        guard let application = applicationWithPID(unhiddenApplication.processIdentifier) else {
            return
        }

        application.dropWindowsCache()
        for window in application.windows() {
            add(window: window)
        }
        activate(application: application)
    }

    @objc func activeSpaceDidChange(_ notification: Notification) {
        // Update spaces across screens so that events get distributed to the correct layouts
        screens.updateSpaces()

        for pendingEvent in eventQueue {
            distributeEventToScreen(pendingEvent.screen, change: pendingEvent.event)
        }
        eventQueue.removeAll()

        pendingTabDetection.removeAll()
        earlyFocusedWindows.removeAll()

        for runningApplication in NSWorkspace.shared.runningApplications {
            let pid = runningApplication.processIdentifier
            guard let application = applicationWithPID(pid) else {
                continue
            }

            application.dropWindowsCache()

            for window in application.windows() {
                add(window: window)
            }
        }

        windows.regenerateActiveIDCache()
        markAllScreensForReflow()
    }

    @objc func screenParametersDidChange(_ notification: Notification) {
        screens.updateScreens(windowManager: self)
    }
}

extension WindowManager: ApplicationEventHandlerDelegate {
    private func installApplicationMonitor() {
        let target = GetApplicationEventTarget()
        let launchedEventSpec = EventTypeSpec(eventClass: OSType(kEventClassApplication), eventKind: OSType(kEventAppLaunched))
        let terminatedEventSpec = EventTypeSpec(eventClass: OSType(kEventClassApplication), eventKind: OSType(kEventAppTerminated))
        var eventSpecs = [launchedEventSpec, terminatedEventSpec]
        let eventHandler = UnsafeMutableRawPointer(Unmanaged.passUnretained(applicationEventHandler).toOpaque())
        let error = InstallEventHandler(target, applicationEventHandlerUPP, 2, &eventSpecs, eventHandler, nil)

        if error != noErr {
            log.error("error installing app launch monitor: \(error)")
        }
    }

    func add(applicationWithPID pid: pid_t) {
        guard let runningApplication = NSRunningApplication(processIdentifier: pid) else {
            log.warning("process launched with no application: \(pid)")
            return
        }

        add(runningApplication: runningApplication)
    }

    func remove(applicationWithPID pid: pid_t) {
        guard let application = applicationWithPID(pid) else {
            log.warning("process terminated with no application: \(pid)")
            return
        }

        remove(application: application)
    }
}

extension WindowManager {
    func preferencesDidClose() {
        DispatchQueue.main.async {
            self.focusTransitionCoordinator.focusScreen(at: 0)
        }
    }

    func focusedScreenManager() -> ScreenManager<WindowManager<Application>>? {
        return screens.focusedScreenManager()
    }

    fileprivate func applicationWithPID(_ pid: pid_t) -> AnyApplication<Application>? {
        return applications[pid]
    }

    fileprivate func add(application: AnyApplication<Application>) {
        guard applications[application.pid()] == nil else {
            for window in application.windows() {
                add(window: window)
            }
            return
        }

        ApplicationObservation(application: application, delegate: self)
            .addObservers()
            .subscribe(
                onCompleted: { [weak self] in
                    self?.applications[application.pid()] = application

                    for window in application.windows() {
                        self?.add(window: window)
                    }
                }
            )
            .disposed(by: disposeBag)
    }

    fileprivate func remove(application: AnyApplication<Application>) {
        for window in application.windows() {
            remove(window: window)
        }
        applications.removeValue(forKey: application.pid())
    }

    fileprivate func activate(application: AnyApplication<Application>) {
        windows.activateApplication(withPID: application.pid())
        windows.regenerateActiveIDCache()
        markAllScreensForReflow()
    }

    fileprivate func deactivate(application: AnyApplication<Application>) {
        windows.deactivateApplication(withPID: application.pid())
        markAllScreensForReflow()
    }

    fileprivate func remove(window: Window) {
        log.debug("Removing window: \(window)")
        pendingTabDetection.removeValue(forKey: window.id())
        earlyFocusedWindows.remove(window.id())
        distributeEventToAllScreens(.remove(window: window))
        markAllScreensForReflow()
        windows.regenerateActiveIDCache()
        windows.remove(window: window)
    }

    func toggleFloatForFocusedWindow() {
        guard let focusedWindow = Window.currentlyFocused(), let screen = focusedWindow.screen() else {
            return
        }

        guard windows.windows(onScreen: screen).contains(focusedWindow) else {
            let windowChange: Change<Window> = .add(window: focusedWindow)
            add(window: focusedWindow)
            guard windows.window(withID: focusedWindow.id()) != nil else {
                return
            }
            windows.setFloating(false, forWindow: focusedWindow)
            distributeEventToScreen(screen, change: windowChange)
            markScreenForReflow(screen)
            return
        }

        let windowChange: Change = windows.isWindowFloating(focusedWindow) ? .add(window: focusedWindow) : .remove(window: focusedWindow)
        windows.setFloating(!windows.isWindowFloating(focusedWindow), forWindow: focusedWindow)
        distributeEventToScreen(screen, change: windowChange)
        markScreenForReflow(screen)
    }

    func distributeEventToScreen(_ screen: Screen, change: Change<Window>) {
        screens.distributeEventToScreen(screen, change: change)
    }

    func distributeEventToAllScreens(_ change: Change<Window>) {
        screens.distributeEventToAllScreens(change: change)
    }

    func markScreenForReflow(_ screen: Screen) {
        screens.markScreenForReflow(screen)
    }

    func markAllScreensForReflow() {
        screens.markAllScreensForReflow()
    }

    func displayCurrentLayout() {
        for screenManager in screens.screenManagers {
            screenManager.displayLayoutHUD()
        }
    }

    func displayWindowCountHUD() {
        guard userConfiguration.enablesWindowCountHUD() else {
            return
        }

        for screenManager in screens.screenManagers {
            let currentCount = userConfiguration.windowMaxCount() ?? 0
            let countText = currentCount == 0 ? "Unlimited" : "\(currentCount)"
            let title = "Window Max Count: \(countText)"
            screenManager.displayCustomHUD(title: title)
        }
    }

    func add(runningApplication: NSRunningApplication) {
        switch runningApplication.isManageable {
        case .manageable:
            let application = AnyApplication(Application(runningApplication: runningApplication))
            add(application: application)
        case .undetermined:
            monitorUndeterminedApplication(runningApplication)
        case .unmanageable:
            break
        }
    }

    func monitorUndeterminedApplication(_ runningApplication: NSRunningApplication) {
        let pid = runningApplication.processIdentifier

        if let previousApplication = applicationObservations[pid] {
            previousApplication.invalidate()
            applicationObservations.removeValue(forKey: pid)
        }

        let activationPolicyObservation = runningApplication.observe(\.activationPolicy) { [weak self] runningApplication, change in
            guard case .setting = change.kind else {
                return
            }

            if runningApplication.activationPolicy == .regular {
                self?.applicationObservations[runningApplication.processIdentifier]?.invalidate()
                self?.applicationObservations.removeValue(forKey: runningApplication.processIdentifier)
                self?.add(runningApplication: runningApplication)
            }
        }

        let isFinishedLaunchingObservation = runningApplication.observe(\.isFinishedLaunching) { [weak self] runningApplication, change in
            guard case .setting = change.kind else {
                return
            }

            if runningApplication.isFinishedLaunching {
                self?.applicationObservations[runningApplication.processIdentifier]?.invalidate()
                self?.applicationObservations.removeValue(forKey: runningApplication.processIdentifier)
                self?.add(runningApplication: runningApplication)
            }
        }

        applicationObservations[pid] = UndeterminedApplication(
            application: runningApplication,
            activationPolicyObservation: activationPolicyObservation,
            isFinishedLaunchingObservation: isFinishedLaunchingObservation
        )
    }

    func reevaluateWindows() {
        for runningApplication in NSWorkspace.shared.runningApplications {
            add(runningApplication: runningApplication)
        }
        markAllScreensForReflow()
    }

    private func add(window: Window, afterWindow otherWindow: Window? = nil) {
        log.debug("Adding window: \(window)")
        guard window.shouldBeManaged() else {
            log.debug("Window should not be managed: \(window)")
            return
        }

        guard let application = applicationWithPID(window.pid()) else {
            log.error("Tried to add a window without an application: \(window)")
            return
        }

        defer {
            windows.regenerateActiveIDCache()
        }

        guard !windows.isWindowTracked(window) else {
            log.debug("Window was already tracked: \(window)")
            return
        }

        ApplicationObservation(application: application, delegate: self)
            .addObserversForWindow(window)
            .map { try self.determineFloatForWindow(window, application: application, force: false) }
            .retry { error in
                error.enumerated().flatMap { count, error -> Observable<Int> in
                    guard error is TrackingError, count < 6 else {
                        return .error(error)
                    }

                    log.debug("error in determining float for window: \(window) - \(error)")
                    return .timer(.milliseconds((count ^ 2 * 100)), scheduler: MainScheduler.instance)
                }
            }
            .catch { error in
                guard error is TrackingError else {
                    throw error
                }
                log.debug("forcing float for window: \(window)")
                try self.determineFloatForWindow(window, application: application, force: true)
                return .just(())
            }
            .map { try self.track(window: window, application: application, afterWindow: otherWindow) }
            .retry { error in
                error.enumerated().flatMap { count, error -> Observable<Int> in
                    guard error is TrackingError, count < 6 else {
                        return .error(error)
                    }

                    log.debug("encountered an error trying to track window: \(error)")
                    return .timer(.milliseconds((count ^ 2 * 100)), scheduler: MainScheduler.instance)
                }
            }
            .subscribe()
            .disposed(by: disposeBag)
    }

    private func determineFloatForWindow(_ window: Window, application: AnyApplication<Application>, force: Bool) throws {
        switch application.defaultFloatForWindow(window) {
        case .unreliable where !force:
            throw TrackingError.unreliableFloating
        case .reliable(.floating), .unreliable(.floating):
            windows.setFloating(true, forWindow: window)
        case .reliable(.notFloating), .unreliable(.notFloating):
            windows.setFloating(false, forWindow: window)
        }
    }

    private func track(window: Window, application: AnyApplication<Application>, afterWindow otherWindow: Window? = nil) throws {
        guard !windows.isWindowTracked(window) else {
            log.warning("Trying to track a window that is already tracked: \(window)")
            throw TrackingError.alreadyTracked
        }

        guard let screen = window.screen() else {
            throw TrackingError.unknownScreen
        }

        guard CGWindowsInfo.windowSpace(window) != nil else {
            throw TrackingError.unknownSpace
        }

        if let otherWindow = otherWindow {
            _ = windows.replace(window: window, withWindow: otherWindow)
            distributeEventToScreen(screen, change: .tabChange(window: window, previousWindow: otherWindow))
        } else {
            windows.add(window: window, atFront: userConfiguration.sendNewWindowsToMainPane())

            // Only send .add to layouts if the window is on the currently active space.
            // Windows tracked during a space change for a different space should not
            // generate .add events — doing so gives layouts stale data for windows
            // that aren't visible on the current space.
            let windowSpace = CGWindowsInfo.windowSpace(window)
            let currentSpaceID = CGSpacesInfo<Window>.currentSpaceForScreen(screen)?.id
            let isOnCurrentSpace: Bool
            if let currentSpaceID, let windowSpace {
                isOnCurrentSpace = currentSpaceID == windowSpace
            } else {
                isOnCurrentSpace = true
            }

            if isOnCurrentSpace {
                let windowChange: Change = windows.isWindowFloating(window) ? .unknown : .add(window: window)
                distributeEventToScreen(screen, change: windowChange)
            }
        }

        markScreenForReflow(screen)
    }

    /**
     This function is a best effort to detect changes between native macOS tabs.
     
     - Description:
        Each "tab" is an independent window, but the underlying system relates them in some way that we do not have access to. The heuristic is to find a window from the same application that has recently left the screen, and swap them.
     
        This performs pretty well in steady state, but can be a bit wonky when finding the existing tabs depending on how quick the transitions are.

     - Parameters:
        - window: the window that might be a tab change.
     */
    func swapInTab(window: Window) {
        guard let screen = window.screen() else {
            return
        }

        // We do this to avoid triggering tab swapping when just switching focus between apps.
        // If the window's app is not running by this point then it's not a tab switch.
        guard let runningApp = NSRunningApplication(processIdentifier: window.pid()), runningApp.isActive else {
            return
        }

        // We take the windows that are being tracked so we can properly detect when a tab switch is a new tab.
        // It is important here to compute isActive and isOnScreen as soon as possible for improved accuracy.
        let applicationWindows = windows.windows(forApplicationWithPID: window.pid())
            .map { ($0, windows.isWindowActive($0), $0.isOnScreen()) }

        var string = "\n\tNew Window: \(window)"
        applicationWindows.forEach { string += "\n\tExisting window: \($0)" }
        log.debug(string)

        for (existingWindow, isActive, isOnScreen) in applicationWindows {
            guard existingWindow != window else {
                log.debug("Windows are the same:\n\tNew: \(window)\n\t\(existingWindow)")
                continue
            }

            // The window needs to have been active _at some point_, but must not be currently on screen.
            let didLeaveScreen = (isActive || windows.isWindowActive(existingWindow)) && !existingWindow.isOnScreen()
            let isInvalid = existingWindow.cgID() == kCGNullWindowID

            log.debug("""
            Considering window: \(existingWindow)
            isActive: \(isActive), isOnScreen: \(isOnScreen), isInvalid: \(isInvalid), managed: \(existingWindow.shouldBeManaged())
            Recomputed isActive: \(windows.isWindowActive(existingWindow)), isOnScreen: \(existingWindow.isOnScreen())
            """)

            // The window needs to have either left the screen and therefore is being replaced
            // or be invalid and therefore being removed and can be replaced.
            guard didLeaveScreen || isInvalid else {
                log.debug("Window candidate discarded: \(existingWindow)")
                continue
            }

            // We have to make sure that we haven't had a focus change too recently as that could mean
            // the window is already active, but just became focused by swapping window focus.
            // The time is in seconds, and too long a time ends up with quick switches triggering tabs to incorrectly
            // swap.
            let changeInterval = lastFocusDate.flatMap { abs($0.timeIntervalSinceNow) }
            if let changeInterval = changeInterval, abs(changeInterval) < 0.1 && !isInvalid {
                log.debug("""
                Window candidate discarded: \(existingWindow)
                lastFocusChange: \(lastFocusDate?.description ?? "nil") now: \(changeInterval) isInvalid: \(isInvalid)
                """)
                continue
            }

            log.debug("Selected existing window: \(existingWindow)")

            guard windows.isWindowTracked(window) else {
                // If the window isn't tracked we add it in relation to the existing one.
                pendingTabDetection.removeValue(forKey: window.id())
                earlyFocusedWindows.remove(window.id())
                add(window: window, afterWindow: existingWindow)
                return
            }

            // If we get here, we are working with a window that has been previously added.
            // Instead of going through the whole add process, we can just swap the windows in order.
            pendingTabDetection.removeValue(forKey: window.id())
            earlyFocusedWindows.remove(window.id())
            windows.replace(window: existingWindow, withWindow: window)
            windows.regenerateActiveIDCache()

            // Note that the existing window moving out of screen will be tracked as a remove,
            // but the "adding" happens above, so we need to distribute the relevant change.
            distributeEventToScreen(screen, change: .tabChange(window: window, previousWindow: existingWindow))
            markScreenForReflow(screen)

            return
        }

        windows.regenerateActiveIDCache()
        if earlyFocusedWindows.remove(window.id()) != nil {
            // Focus notification already fired before we got here — the visual
            // transition is settled so call completeTabDetection directly.
            completeTabDetection(for: window, on: screen)
        } else {
            pendingTabDetection[window.id()] = window
        }
    }

    private func completeTabDetection(for window: Window, on screen: Screen) {
        windows.regenerateActiveIDCache()

        let applicationWindows = windows.windows(forApplicationWithPID: window.pid())

        for existingWindow in applicationWindows {
            guard existingWindow != window else { continue }

            let didLeaveScreen = windows.isWindowActive(existingWindow) && !existingWindow.isOnScreen()
            let isInvalid = existingWindow.cgID() == kCGNullWindowID

            guard didLeaveScreen || isInvalid else { continue }

            log.debug("completeTabDetection: selected candidate \(existingWindow) for \(window)")

            guard windows.isWindowTracked(window) else {
                pendingTabDetection.removeValue(forKey: window.id())
                earlyFocusedWindows.remove(window.id())
                add(window: window, afterWindow: existingWindow)
                return
            }

            pendingTabDetection.removeValue(forKey: window.id())
            earlyFocusedWindows.remove(window.id())
            windows.replace(window: existingWindow, withWindow: window)
            windows.regenerateActiveIDCache()
            distributeEventToScreen(screen, change: .tabChange(window: window, previousWindow: existingWindow))
            markScreenForReflow(screen)
            return
        }

        log.debug("completeTabDetection: no candidate found")
        add(window: window)
    }

    func onReflowInitiation() {
        mouseStateKeeper.handleReflowEvent()
    }

    func onReflowCompletion() {
//        if let focusedWindow = Window.currentlyFocused() {
//            doMouseFollowsFocus(focusedWindow: focusedWindow)
//        }

        // This handler will be executed by the Operation, in a queue.  Although async
        // (and although the docs say that it executes in a separate thread), I consider
        // this to be thread safe, at least safe enough, because we always want the
        // latest time that a reflow took place.
        mouseStateKeeper.handleReflowEvent()
        lastReflowTime = Date()

        // Snapshot the active set Amethyst just laid out so silent departures can be
        // detected by reconcileActiveWindowsIfNeeded().
        windows.regenerateActiveIDCache()
        for screenManager in screens.screenManagers {
            guard let screen = screenManager.screen, let screenID = screen.screenID() else {
                continue
            }
            lastActiveWindowIDsByScreen[screenID] = Set(
                windows.activeWindows(onScreen: screen).map { $0.cgID() }
            )
        }
    }

    func doMouseFollowsFocus(focusedWindow: Window) {
        guard UserConfiguration.shared.mouseFollowsFocus() else {
            return
        }

        guard NSEvent.pressedMouseButtons == 0 else {
            // If a mouse button is pressed, then the user is probably dragging something between windows. Do not move the mouse.
            return
        }

        // See the description of mouseMoveClickSpeedTolerance for details.
        if let interval = mouseStateKeeper.lastClick?.timeIntervalSinceNow, abs(interval) < mouseMoveClickSpeedTolerance {
            return
        }

        if focusTransitionCoordinator.recentlyTriggeredFocusFollowsMouse() {
            // If we have recently triggered focus-follows-mouse, then disable mouse-follows-focus. Otherwise, the moment
            // focus-follows-mouse is triggered, the mouse will jump to the center of the focused window.
            return
        }

        let windowFrame = focusedWindow.frame()
        let mouseCursorPoint = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let mouseMoveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: mouseCursorPoint, mouseButton: .left) {
            mouseMoveEvent.flags = CGEventFlags(rawValue: 0)
            mouseMoveEvent.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }
}

extension WindowManager: MouseStateKeeperDelegate {
    func recommendMainPaneRatio(_ ratio: CGFloat) {
        guard let screenManager: ScreenManager<WindowManager<Application>> = focusedScreenManager() else { return }

        screenManager.updateCurrentLayout { layout in
            if let panedLayout = layout as? PanedLayout {
                panedLayout.recommendMainPaneRatio(ratio)
            }
        }
    }

    func swapDraggedWindowWithDropzone(_ draggedWindow: Window) {
        guard let screen = draggedWindow.screen() else { return }

        let windows: [Window] = self.windows.windows(onScreen: screen)

        // need to flip mouse coordinate system to fit Amethyst https://stackoverflow.com/a/45289010/2063546
        let flippedPointerLocation = NSPointToCGPoint(NSEvent.mouseLocation)
        let unflippedY = Screen.globalHeight() - flippedPointerLocation.y + screen.frameIncludingDockAndMenu().origin.y
        let pointerLocation = NSPointToCGPoint(NSPoint(x: flippedPointerLocation.x, y: unflippedY))

        if let screenManager: ScreenManager<WindowManager<Application>> = focusedScreenManager(), let layout = screenManager.currentLayout {
            let windowSet = self.windows.windowSet(forWindowsOnScreen: screen)
            if let layoutWindow = layout.windowAtPoint(pointerLocation, of: windowSet, on: screen), let framedWindow = self.windows.window(withID: layoutWindow.id) {
                executeTransition(.switchWindows(draggedWindow, framedWindow))
                return
            }
        }

        // Ignore if there is no window at that point
        guard let secondWindow = WindowsInformation.alternateWindowForScreenAtPoint(pointerLocation, withWindows: windows, butNot: draggedWindow) else {
            return
        }
        executeTransition(.switchWindows(draggedWindow, secondWindow))
    }
}

// MARK: ApplicationObservationDelegate
extension WindowManager: ApplicationObservationDelegate {
    func application(_ application: AnyApplication<Application>, didAddWindow window: Window) {
        add(window: window)
    }

    func application(_ application: AnyApplication<Application>, didRemoveWindow window: Window) {
        remove(window: window)
    }

    func application(_ application: AnyApplication<Application>, didFocusWindow window: Window) {
        guard let screen = window.screen() else {
            return
        }

        lastFocusDate = Date()

        if pendingTabDetection.removeValue(forKey: window.id()) != nil {
            completeTabDetection(for: window, on: screen)
        } else if windows.isWindowTracked(window) {
            distributeEventToScreen(screen, change: .focusChanged(window: window))
            markScreenForReflow(screen)
        } else {
            // Focus notification arrived before the creation notification.
            // Record this so swapInTab can call completeTabDetection immediately
            // rather than deferring to a focus event that has already passed.
            log.debug("Focused untracked window before creation notification - recording early focus: \(window)")
            earlyFocusedWindows.insert(window.id())
        }

//        doMouseFollowsFocus(focusedWindow: window)
    }

    func application(_ application: AnyApplication<Application>, didFindPotentiallyNewWindow window: Window) {
        guard !windows.isWindowTracked(window) else {
            return
        }

        swapInTab(window: window)
    }

    func application(_ application: AnyApplication<Application>, didMoveWindow window: Window) {
        guard userConfiguration.mouseSwapsWindows() else {
            return
        }

        guard let screen = window.screen(), activeWindows(on: screen).contains(window) else {
            return
        }

        switch mouseStateKeeper.state {
        case .dragging:
            // be aware of last reflow time, again to prevent race condition
            let reflowEndInterval = Date().timeIntervalSince(lastReflowTime)
            guard reflowEndInterval > mouseStateKeeper.dragRaceThresholdSeconds else { break }

            // record window and wait for mouse up
            mouseStateKeeper.state = .moving(window: window)
        case let .doneDragging(lmbUpMoment):
            mouseStateKeeper.state = .pointing // flip state first to prevent race condition

            // if mouse button recently came up, assume window move is related
            let dragEndInterval = Date().timeIntervalSince(lmbUpMoment)
            guard dragEndInterval < mouseStateKeeper.dragRaceThresholdSeconds else { break }

            mouseStateKeeper.swapDraggedWindowWithDropzone(window)
        default:
            break
        }
    }

    func application(_ application: AnyApplication<Application>, didResizeWindow window: Window) {
        guard userConfiguration.mouseResizesWindows() else {
            return
        }

        guard let screen = window.screen(), activeWindows(on: screen).contains(window) else {
            return
        }

        guard
            let screenManager: ScreenManager<WindowManager<Application>> = focusedScreenManager(),
            let layout = screenManager.currentLayout,
            layout is PanedLayout
        else {
            return
        }

        guard let oldFrame = layout.assignedFrame(window, of: windows.windowSet(forActiveWindowsOnScreen: screen), on: screen) else {
            return
        }

        let ratio = oldFrame.impliedMainPaneRatio(windowFrame: window.frame())

        switch mouseStateKeeper.state {
        case .dragging, .resizing:
            // record window and wait for mouse up
            mouseStateKeeper.state = .resizing(screen: screen, ratio: ratio)
        case let .doneDragging(lmbUpMoment):
            // if mouse button recently came up, assume window resize is related
            let dragEndInterval = Date().timeIntervalSince(lmbUpMoment)
            if dragEndInterval < mouseStateKeeper.dragRaceThresholdSeconds {
                mouseStateKeeper.state = .pointing // flip state first to prevent race condition

                if let screenManager: ScreenManager<WindowManager<Application>> = focusedScreenManager() {
                    screenManager.updateCurrentLayout { layout in
                        if let panedLayout = layout as? PanedLayout {
                            panedLayout.recommendMainPaneRatio(ratio)
                        }
                    }
                }
            }
        default:
            break
        }
    }

    func applicationDidActivate(_ application: AnyApplication<Application>) {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(applicationActivated(_:)),
            object: nil
        )
        perform(#selector(applicationActivated(_:)), with: nil, afterDelay: 0.2)
    }
}

// MARK: Transition Coordination
extension WindowManager {
    func screen(at index: Int) -> Screen? {
        return screenManager(at: index)?.screen
    }

    func screenManager(at screenIndex: Int) -> ScreenManager<WindowManager<Application>>? {
        guard screenIndex > -1 && screenIndex < screens.screenManagers.count else {
            return nil
        }

        return screens.screenManagers[screenIndex]
    }

    func screenManager(for screen: Screen) -> ScreenManager<WindowManager<Application>>? {
        return screens.screenManagers.first { $0.screen?.screenID() == screen.screenID() }
    }

    func screenManagerIndex(for screen: Screen) -> Int? {
        return screens.screenManagers.firstIndex { $0.screen?.screenID() == screen.screenID() }
    }
}

// MARK: Window Transition
extension WindowManager: WindowTransitionTarget {
    func executeTransition(_ transition: WindowTransition<Window>) {
        switch transition {
        case let .switchWindows(window, otherWindow):
            guard windows.swap(window: window, withWindow: otherWindow) else {
                return
            }

            distributeEventToAllScreens(.windowSwap(window: window, otherWindow: otherWindow))
            markAllScreensForReflow()
        case let .moveWindowToScreen(window, screen):
            // Capture source before move — after moveScaled, window.screen() is the target.
            let sourceScreen = window.screen()
            window.moveScaled(to: screen)
            if let sourceScreen, sourceScreen.screenID() != screen.screenID() {
                // Source must get remove + reflow; previously both went to the target,
                // leaving the origin screen with stale frame sizes (empty pane gaps).
                distributeEventToScreen(sourceScreen, change: .remove(window: window))
                markScreenForReflow(sourceScreen)
            }
            distributeEventToScreen(screen, change: .add(window: window))
            markScreenForReflow(screen)
            window.focus()
        case let .moveWindowToSpaceAtIndex(window, spaceIndex, sourceSpaceIndex):
            guard
                let screen = window.screen(),
                let spaces = CGSpacesInfo<Window>.spacesForAllScreens(includeOnlyUserSpaces: true),
                spaceIndex < spaces.count
            else {
                return
            }

            let targetSpace = spaces[spaceIndex]
            guard let targetScreen = CGSpacesInfo<Window>.screenForSpace(space: targetSpace) else {
                return
            }
            distributeEventToScreen(screen, change: .remove(window: window))
            markScreenForReflow(screen)
            eventQueue.append(PendingEvent(screen: targetScreen, event: .add(window: window)))
            window.move(toSpaceAtIndex: UInt(spaceIndex + 1))
            if targetScreen.screenID() != screen.screenID() {
                // necessary to set frame here as window is expected to be at origin relative to targe screen when moved, can be improved.
                window.moveScaled(to: targetScreen)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if !UserConfiguration.shared.followWindowsThrownBetweenSpaces() {
                    SISystemWideElement.switch(toSpace: UInt(sourceSpaceIndex + 1))
                }
            }
        case .resetFocus:
            if let screen = screens.screenManagers.first?.screen {
                executeTransition(.focusScreen(screen))
            }
        }
    }

    func isWindowFloating(_ window: Window) -> Bool {
        return windows.isWindowFloating(window)
    }

    func currentLayout() -> Layout<Application.Window>? {
        return focusedScreenManager()?.currentLayout
    }

    func activeWindows(on screen: Screen) -> [Window] {
        return windows.activeWindows(onScreen: screen).filter { window in
            return window.shouldBeManaged() && !self.windows.isWindowFloating(window)
        }
    }

    func nextScreenIndexClockwise(from screen: Screen) -> Int {
        guard let screenManagerIndex = self.screenManagerIndex(for: screen) else {
            return -1
        }

        return (screenManagerIndex + 1) % (screens.screenManagers.count)
    }

    func nextScreenIndexCounterClockwise(from screen: Screen) -> Int {
        guard let screenManagerIndex = self.screenManagerIndex(for: screen) else {
            return -1
        }

        return (screenManagerIndex == 0 ? screens.screenManagers.count - 1 : screenManagerIndex - 1)
    }

    func lastMainWindowForCurrentSpace() -> Window? {
        guard let currentFocusedSpace = CGSpacesInfo<Window>.currentFocusedSpace(),
              let lastMainWindow = windows.lastMainWindows[currentFocusedSpace.id]
        else {
            return nil
        }
        return lastMainWindow
    }
}

// MARK: Focus Transition
extension WindowManager: FocusTransitionTarget {
    func windows(onScreen screen: Screen) -> [Window] {
        return windows.activeWindows(onScreen: screen)
    }

    func executeTransition(_ transition: FocusTransition<Window>) {
        switch transition {
        case let .focusWindow(window):
            window.focus()
        case let .focusScreen(screen):
            screen.focusScreen()
        }
    }

    func lastFocusedWindow(on screen: Screen) -> Window? {
        return screens.screenManagers.first { $0.screen?.screenID() == screen.screenID() }?.lastFocusedWindow
    }

    func nextWindowIDClockwise(on screen: Screen) -> Window.WindowID? {
        return screenManager(for: screen)?.nextWindowIDClockwise()
    }

    func nextWindowIDCounterClockwise(on screen: Screen) -> Window.WindowID? {
        return screenManager(for: screen)?.nextWindowIDCounterClockwise()
    }
}

extension WindowManager: ScreenManagerDelegate {
    func applyWindowLimit(forScreenManager screenManager: ScreenManager<WindowManager<Application>>, minimizingIn range: (Int) -> Range<Int>) {
        guard let screen = screenManager.screen else {
            return
        }

        let windows = screenManager.currentLayout is FloatingLayout
            ? self.windows(onScreen: screen).filter { $0.shouldBeManaged() }
            : activeWindows(on: screen)
        windows[range(windows.count)].forEach {
            $0.minimize()
        }
    }

    func activeWindowSet(forScreenManager screenManager: ScreenManager<WindowManager<Application>>) -> WindowSet<Window> {
        // Always use a fresh on-screen ID cache so reflows exclude windows that
        // left the space without a remove notification.
        windows.regenerateActiveIDCache()
        return windows.windowSet(forActiveWindowsOnScreen: screenManager.screen!)
    }
}

extension WindowManager where Application == SIApplication {
    /// A durable description of top-level windows across every Space.
    ///
    /// WindowManager supplies exact titles for windows it has already seen. The CG
    /// window list fills in windows on Spaces that have not been visited since launch,
    /// so a snapshot never silently collapses to the current Space.
    func contextWindowSnapshot() -> [[String: Any]] {
        var trackedWindows: [CGWindowID: AXWindow] = [:]
        for window in windows.windows {
            trackedWindows[window.cgID()] = window
        }
        guard let descriptions = CGWindowsInfo<AXWindow>(options: .optionAll, windowID: 0)?.descriptions else {
            return []
        }

        let displayTop = NSScreen.screens.map(\.frame.maxY).max() ?? 0

        return descriptions.compactMap { description in
            guard let number = description[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = description[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = description[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let bounds = description[kCGWindowBounds as String] as? [String: AnyObject],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else {
                return nil
            }

            let windowID = CGWindowID(number.uint32Value)
            let pid = pid_t(ownerPID.int32Value)
            let runningApplication = NSRunningApplication(processIdentifier: pid)
            guard runningApplication?.isManageable == .manageable else { return nil }

            let trackedWindow = trackedWindows[windowID]
            // Chrome and other apps expose short tab-strip/helper surfaces as layer-zero
            // windows. Retain any known AX window, but discard unknown slivers.
            guard trackedWindow != nil || (width >= 200 && height >= 150) else { return nil }

            let frame = CGRect(x: x, y: y, width: width, height: height)
            let cocoaFrame = CGRect(x: x, y: displayTop - y - height, width: width, height: height)
            let inferredScreen = NSScreen.screens.max { left, right in
                left.frame.intersection(cocoaFrame).area < right.frame.intersection(cocoaFrame).area
            }
            let trackedScreen: AMScreen? = trackedWindow?.screen()
            let isOnScreen = (description[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let title = trackedWindow?.title() ?? description[kCGWindowName as String] as? String ?? ""
            var record: [String: Any] = [
                "app": runningApplication?.localizedName ?? applications[pid]?.title() ?? "unknown",
                "title": title,
                "pid": Int(pid),
                "window_id": Int(windowID),
                "screen": trackedScreen?.screen.localizedName ?? inferredScreen?.localizedName ?? "unknown",
                "frame": [
                    "x": frame.origin.x,
                    "y": frame.origin.y,
                    "width": frame.size.width,
                    "height": frame.size.height,
                ],
                "focused": trackedWindow?.isFocused() ?? false,
                "active": trackedWindow?.isActive() ?? isOnScreen,
                "floating": trackedWindow.map { windows.isWindowFloating($0) } ?? false,
            ]
            if let bundleIdentifier = runningApplication?.bundleIdentifier {
                record["bundle"] = bundleIdentifier
            }
            if let space = CGWindowsInfo<AXWindow>.windowSpace(windowID) {
                record["space"] = space
            }
            return record
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
