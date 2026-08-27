//
//  AppDelegate.swift
//  Amethyst
//
//  Created by Ian Ynda-Hummel on 5/8/16.
//  Copyright © 2016 Ian Ynda-Hummel. All rights reserved.
//

import CoreServices
import Foundation
import LoginServiceKit
import RxCocoa
import RxSwift
import Silica
import Sparkle
import SwiftyBeaver

class AppDelegate: NSObject, NSApplicationDelegate {
    static let windowManagerEncodingKey = "EncodedWindowManager"

    @IBOutlet var preferencesWindowController: PreferencesWindowController?

    fileprivate var windowManager: WindowManager<SIApplication>?
    private var hotKeyManager: HotKeyManager<SIApplication>?
    private var accessibilityPermissionTimer: Timer?
    private var controlRequestObserver: NSObjectProtocol?

    fileprivate var statusItem: NSStatusItem?
    @IBOutlet var statusItemMenu: NSMenu?
    @IBOutlet var versionMenuItem: NSMenuItem?
    @IBOutlet var startAtLoginMenuItem: NSMenuItem?
    @IBOutlet var toggleGlobalTilingMenuItem: NSMenuItem?
    @IBOutlet var layoutsMenuItem: NSMenuItem?

    private var isFirstLaunch = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        let persistentLogFileURL = configurePersistentLogging()

        #if DEBUG
            log.addDestination(ConsoleDestination())
        #endif

        if CommandLine.arguments.contains("--log") {
            let destination = ConsoleDestination()
            destination.useNSLog = true
            log.addDestination(destination)
        }

        log.info("Logging is enabled")
        log.debug("Debug logging is enabled")
        log.info("Persistent log file: \(persistentLogFileURL?.path ?? "unavailable")")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        log.info(
            "Amethyst launch: version=\(version) build=\(build) " +
                "pid=\(ProcessInfo.processInfo.processIdentifier) arguments=\(CommandLine.arguments)"
        )

        UserConfiguration.shared.delegate = self
        UserConfiguration.shared.load()

        #if RELEASE
            let appcastURLString = { () -> String? in
                if UserConfiguration.shared.useCanaryBuild() {
                    return Bundle.main.infoDictionary?["SUCanaryFeedURL"] as? String
                } else {
                    return Bundle.main.infoDictionary?["SUFeedURL"] as? String
                }
            }()!

            SUUpdater.shared().feedURL = URL(string: appcastURLString)
        #endif

        preferencesWindowController?.window?.level = .floating

        if let encodedWindowManager = UserDefaults.standard.data(forKey: AppDelegate.windowManagerEncodingKey), UserConfiguration.shared.restoreLayoutsOnLaunch() {
            let decoder = JSONDecoder()
            windowManager = try? decoder.decode(WindowManager<SIApplication>.self, from: encodedWindowManager)
        }

        windowManager = windowManager ?? WindowManager(userConfiguration: UserConfiguration.shared)
        hotKeyManager = HotKeyManager(userConfiguration: UserConfiguration.shared)

        hotKeyManager?.setUpWithWindowManager(windowManager!, configuration: UserConfiguration.shared, appDelegate: self)
        setUpControlInterface()
        monitorAccessibilityPermissionIfNeeded()
        ContextCapture.shared.windowSnapshotProvider = { [weak self] in
            return self?.windowManager?.contextWindowSnapshot() ?? []
        }
        ContextCapture.shared.start()
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as! String
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as! String
        let statusItemImage = NSImage(named: "icon-statusitem")
        statusItemImage?.isTemplate = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.image = statusItemImage
        statusItem?.menu = statusItemMenu
        statusItem?.highlightMode = true

        let hideMenuBarIcon: Bool = UserConfiguration.shared.hideMenuBarIcon()
        statusItem?.isVisible = !hideMenuBarIcon

        versionMenuItem?.title = "Version \(shortVersion) (\(version))"
        toggleGlobalTilingMenuItem?.title = "Disable"

        startAtLoginMenuItem?.state = (LoginServiceKit.isExistLoginItems(at: Bundle.main.bundlePath) ? .on : .off)

        // Set up status item menu delegate to refresh layouts when main menu is opened
        statusItemMenu?.delegate = self
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isFirstLaunch else {
            isFirstLaunch = false
            return
        }

        showPreferencesWindow(self)
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityPermissionTimer?.invalidate()
        if let controlRequestObserver {
            DistributedNotificationCenter.default().removeObserver(controlRequestObserver)
        }

        defer {
            log.info("Amethyst terminating")
            _ = log.flush(secondTimeout: 2)
        }

        guard let windowManager = windowManager else {
            return
        }

        do {
            let encoder = JSONEncoder()
            let encodedWindowManager = try encoder.encode(windowManager)
            UserDefaults.standard.set(encodedWindowManager, forKey: AppDelegate.windowManagerEncodingKey)
        } catch {
            log.error("Failed to encode window manager: \(error)")
        }
    }

    private func setUpControlInterface() {
        controlRequestObserver = DistributedNotificationCenter.default().addObserver(
            forName: AmethystControl.requestNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleControlRequest(notification)
        }
    }

    private func handleControlRequest(_ notification: Notification) {
        guard let command = notification.userInfo?[AmethystControl.commandKey] as? String else {
            return
        }

        let requestID = notification.userInfo?[AmethystControl.requestIDKey] as? String ?? ""
        do {
            guard let windowManager else {
                respondToControlRequest(requestID: requestID, result: .failure(.windowManagerUnavailable))
                return
            }

            switch command {
            case AmethystControl.moveWindowCommand:
                let request = try WindowMoveControlRequest(userInfo: notification.userInfo)
                windowManager.moveWindow(withCGID: request.windowID, toDesktop: request.desktop) { [weak self] result in
                    self?.respondToControlRequest(requestID: request.requestID, result: result)
                }
            case AmethystControl.swapWindowsCommand:
                let request = try WindowSwapControlRequest(userInfo: notification.userInfo)
                windowManager.swapWindows(
                    withCGID: request.windowID,
                    otherWindowID: request.otherWindowID
                ) { [weak self] result in
                    self?.respondToControlRequest(requestID: request.requestID, result: result)
                }
            default:
                return
            }
        } catch {
            respondToControlRequest(
                requestID: requestID,
                result: .failure(.invalidRequest(error.localizedDescription))
            )
        }
    }

    private func respondToControlRequest(requestID: String, result: Result<String, WindowControlError>) {
        let success: Bool
        let message: String
        switch result {
        case let .success(value):
            success = true
            message = value
        case let .failure(error):
            success = false
            message = error.localizedDescription
        }

        DistributedNotificationCenter.default().postNotificationName(
            AmethystControl.responseNotification,
            object: nil,
            userInfo: [
                AmethystControl.requestIDKey: requestID,
                AmethystControl.successKey: NSNumber(value: success),
                AmethystControl.messageKey: message,
            ],
            deliverImmediately: true
        )
    }

    @IBAction func toggleStartAtLogin(_ sender: AnyObject) {
        if startAtLoginMenuItem?.state == .off {
            LoginServiceKit.addLoginItems(at: Bundle.main.bundlePath)
        } else {
            LoginServiceKit.removeLoginItems(at: Bundle.main.bundlePath)
        }
        startAtLoginMenuItem?.state = (LoginServiceKit.isExistLoginItems(at: Bundle.main.bundlePath) ? .on : .off)
    }

    @IBAction func toggleGlobalTiling(_ sender: AnyObject) {
        UserConfiguration.shared.tilingEnabled = !UserConfiguration.shared.tilingEnabled
        windowManager?.markAllScreensForReflow()
    }

    @IBAction func resetLayouts(_ sender: AnyObject) {
        UserDefaults.standard.removeObject(forKey: AppDelegate.windowManagerEncodingKey)
        windowManager?.reset()
    }

    @IBAction func relaunch(_ sender: AnyObject) {
        AppManager.relaunch()
    }

    @IBAction func showPreferencesWindow(_ sender: AnyObject) {
        guard let isVisible = preferencesWindowController?.window?.isVisible, !isVisible else {
            return
        }

        preferencesWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        presentDotfileWarningIfNecessary()
    }

    @IBAction func checkForUpdates(_ sender: AnyObject) {
        #if RELEASE
            SUUpdater.shared().checkForUpdates(sender)
        #endif
    }

    private func presentDotfileWarningIfNecessary() {
        let shouldWarn = !UserDefaults.standard.bool(forKey: "disable-dotfile-conflict-warning")
        if shouldWarn && UserConfiguration.shared.hasCustomConfiguration() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Warning"
            alert.informativeText = "You have a .amethyst file, which can override in-app preferences. You may encounter unexpected behavior."
            alert.showsSuppressionButton = true
            alert.runModal()

            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: "disable-dotfile-conflict-warning")
            }
        }
    }

    private func monitorAccessibilityPermissionIfNeeded() {
        guard !UserConfiguration.shared.hasAccessibilityPermissions,
              accessibilityPermissionTimer == nil else {
            return
        }

        log.info("Accessibility permission is unavailable; monitoring for approval")

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard UserConfiguration.shared.confirmAccessibilityPermissions(prompt: false) else {
                return
            }

            timer.invalidate()
            self?.accessibilityPermissionTimer = nil
            UserConfiguration.shared.hasAccessibilityPermissions = true
        }
        accessibilityPermissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func populateLayoutsMenu() {
        guard let layoutsMenuItem = layoutsMenuItem,
              let submenu = layoutsMenuItem.submenu else {
            return
        }

        // Clear existing items
        submenu.removeAllItems()

        // Get screen manager: try focused screen first, then screen under mouse cursor
        let screenManager: ScreenManager<WindowManager<SIApplication>>? = {
            if let focused = windowManager?.focusedScreenManager() {
                return focused
            }
            // Fallback to screen containing mouse cursor (useful when clicking menu bar)
            let mouseLocation = NSEvent.mouseLocation
            if let nsScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
                let amScreen = AMScreen(screen: nsScreen)
                return windowManager?.screenManager(for: amScreen)
            }
            return nil
        }()

        guard let screenManager = screenManager else {
            let errorItem = NSMenuItem(title: "Unable to determine current screen", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            submenu.addItem(errorItem)
            return
        }

        // Get layouts from the screen manager (not from global config)
        let layouts = screenManager.layoutsInfo

        // Check if no layouts are available and return early
        if layouts.isEmpty {
            let noLayoutsItem = NSMenuItem(title: "No layouts enabled", action: nil, keyEquivalent: "")
            noLayoutsItem.isEnabled = false
            submenu.addItem(noLayoutsItem)
            return
        }

        // Add menu items for each layout in the screen manager
        for layoutInfo in layouts {
            let menuItem = NSMenuItem(title: layoutInfo.name, action: #selector(selectLayout(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = layoutInfo.key
            menuItem.state = layoutInfo.isSelected ? .on : .off

            submenu.addItem(menuItem)
        }
    }

    @IBAction func selectLayout(_ sender: NSMenuItem) {
        guard let layoutKey = sender.representedObject as? String,
              let windowManager = windowManager,
              let screenManager = windowManager.focusedScreenManager() else {
            return
        }

        screenManager.selectLayout(layoutKey)
        // Menu will be refreshed automatically when next opened via NSMenuDelegate
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        windowManager?.preferencesDidClose()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Refresh layouts menu when main status item menu is about to open
        if menu == statusItemMenu {
            populateLayoutsMenu()
        }
    }
}

extension AppDelegate: UserConfigurationDelegate {
    func configurationGlobalTilingDidChange(_ userConfiguration: UserConfiguration) {
        var statusItemImage: NSImage?
        if UserConfiguration.shared.tilingEnabled == true {
            statusItemImage = NSImage(named: "icon-statusitem")
            toggleGlobalTilingMenuItem?.title = "Disable Tiling"
        } else {
            statusItemImage = NSImage(named: "icon-statusitem-disabled")
            toggleGlobalTilingMenuItem?.title = "Enable Tiling"
        }
        statusItemImage?.isTemplate = true
        statusItem?.image = statusItemImage
    }

    func configurationAccessibilityPermissionsDidChange(_ userConfiguration: UserConfiguration) {
        guard userConfiguration.hasAccessibilityPermissions else {
            monitorAccessibilityPermissionIfNeeded()
            return
        }

        accessibilityPermissionTimer?.invalidate()
        accessibilityPermissionTimer = nil
        log.info("Accessibility permission became available; rebuilding window observations")
        windowManager?.reevaluateWindows()
    }
}
