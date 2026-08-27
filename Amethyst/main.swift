//
//  main.swift
//  Amethyst
//
//  Created by Ian Ynda-Hummel on 2/24/20.
//  Copyright © 2020 Ian Ynda-Hummel. All rights reserved.
//

import ArgumentParser
import Cocoa
import CoreGraphics

enum AmethystControl {
    static let requestNotification = Notification.Name("com.amethyst.control.request")
    static let responseNotification = Notification.Name("com.amethyst.control.response")

    static let commandKey = "command"
    static let requestIDKey = "request_id"
    static let windowIDKey = "window_id"
    static let otherWindowIDKey = "other_window_id"
    static let desktopKey = "desktop"
    static let successKey = "success"
    static let messageKey = "message"

    static let moveWindowCommand = "move-window"
    static let swapWindowsCommand = "swap-windows"
    static let minimumDesktop = 1
    static let maximumDesktop = 19
}

enum WindowMoveControlRequestError: LocalizedError {
    case missingRequestID
    case invalidWindowID
    case invalidDesktop

    var errorDescription: String? {
        switch self {
        case .missingRequestID:
            return "control request is missing request_id"
        case .invalidWindowID:
            return "control request has an invalid window_id"
        case .invalidDesktop:
            return "desktop must be between \(AmethystControl.minimumDesktop) and \(AmethystControl.maximumDesktop)"
        }
    }
}

struct WindowMoveControlRequest: Equatable {
    let requestID: String
    let windowID: CGWindowID
    let desktop: Int

    init(userInfo: [AnyHashable: Any]?) throws {
        guard let requestID = userInfo?[AmethystControl.requestIDKey] as? String, !requestID.isEmpty else {
            throw WindowMoveControlRequestError.missingRequestID
        }

        let rawWindowID = (userInfo?[AmethystControl.windowIDKey] as? NSNumber)?.uint64Value ?? 0
        guard rawWindowID > 0, rawWindowID <= UInt64(UInt32.max) else {
            throw WindowMoveControlRequestError.invalidWindowID
        }

        let desktop = (userInfo?[AmethystControl.desktopKey] as? NSNumber)?.intValue ?? 0
        guard (AmethystControl.minimumDesktop...AmethystControl.maximumDesktop).contains(desktop) else {
            throw WindowMoveControlRequestError.invalidDesktop
        }

        self.requestID = requestID
        self.windowID = CGWindowID(rawWindowID)
        self.desktop = desktop
    }
}

enum WindowSwapControlRequestError: LocalizedError {
    case missingRequestID
    case invalidWindowID
    case invalidOtherWindowID
    case identicalWindowIDs

    var errorDescription: String? {
        switch self {
        case .missingRequestID:
            return "control request is missing request_id"
        case .invalidWindowID:
            return "control request has an invalid window_id"
        case .invalidOtherWindowID:
            return "control request has an invalid other_window_id"
        case .identicalWindowIDs:
            return "window-id and other-window-id must be different"
        }
    }
}

struct WindowSwapControlRequest: Equatable {
    let requestID: String
    let windowID: CGWindowID
    let otherWindowID: CGWindowID

    init(userInfo: [AnyHashable: Any]?) throws {
        guard let requestID = userInfo?[AmethystControl.requestIDKey] as? String, !requestID.isEmpty else {
            throw WindowSwapControlRequestError.missingRequestID
        }

        let rawWindowID = (userInfo?[AmethystControl.windowIDKey] as? NSNumber)?.uint64Value ?? 0
        guard rawWindowID > 0, rawWindowID <= UInt64(UInt32.max) else {
            throw WindowSwapControlRequestError.invalidWindowID
        }
        let rawOtherWindowID = (userInfo?[AmethystControl.otherWindowIDKey] as? NSNumber)?.uint64Value ?? 0
        guard rawOtherWindowID > 0, rawOtherWindowID <= UInt64(UInt32.max) else {
            throw WindowSwapControlRequestError.invalidOtherWindowID
        }
        guard rawWindowID != rawOtherWindowID else {
            throw WindowSwapControlRequestError.identicalWindowIDs
        }

        self.requestID = requestID
        self.windowID = CGWindowID(rawWindowID)
        self.otherWindowID = CGWindowID(rawOtherWindowID)
    }
}

struct Arguments: ParsableArguments {}

struct Amethyst: ParsableCommand {
    static var configuration: CommandConfiguration = CommandConfiguration(
        subcommands: [Debug.self, App.self, Control.self],
        defaultSubcommand: App.self
    )
}

struct Control: ParsableCommand {
    static var configuration: CommandConfiguration = CommandConfiguration(
        abstract: "Control the running Amethyst process.",
        subcommands: [MoveWindow.self, SwapWindows.self]
    )
}

struct MoveWindow: ParsableCommand {
    static var configuration: CommandConfiguration = CommandConfiguration(
        commandName: "move-window",
        abstract: "Move an exact window to a numbered macOS desktop without switching desktops."
    )

    @Option(help: "CG window ID shown by `Amethyst debug windows` or `window-layout`.")
    var windowID: UInt32

    @Option(help: "One-based macOS desktop number.")
    var desktop: Int

    @Option(help: "Seconds to wait for the running Amethyst process.")
    var timeout: Double = 8

    mutating func run() throws {
        guard (AmethystControl.minimumDesktop...AmethystControl.maximumDesktop).contains(desktop) else {
            throw ValidationError(
                "desktop must be between \(AmethystControl.minimumDesktop) and \(AmethystControl.maximumDesktop)"
            )
        }
        guard windowID > 0 else {
            throw ValidationError("window-id must be greater than zero")
        }
        guard timeout > 0, timeout <= 30 else {
            throw ValidationError("timeout must be greater than zero and no more than 30 seconds")
        }

        let message = try runControlCommand(
            userInfo: [
                AmethystControl.commandKey: AmethystControl.moveWindowCommand,
                AmethystControl.windowIDKey: NSNumber(value: windowID),
                AmethystControl.desktopKey: NSNumber(value: desktop),
            ],
            timeout: timeout
        )
        print(message)
    }
}

struct SwapWindows: ParsableCommand {
    static var configuration: CommandConfiguration = CommandConfiguration(
        commandName: "swap-windows",
        abstract: "Swap two exact windows in the current Amethyst layout."
    )

    @Option(help: "First CG window ID shown by `window-layout`.")
    var windowID: UInt32

    @Option(help: "Second CG window ID shown by `window-layout`.")
    var otherWindowID: UInt32

    @Option(help: "Seconds to wait for the running Amethyst process.")
    var timeout: Double = 8

    mutating func run() throws {
        guard windowID > 0, otherWindowID > 0 else {
            throw ValidationError("window IDs must be greater than zero")
        }
        guard windowID != otherWindowID else {
            throw ValidationError("window-id and other-window-id must be different")
        }
        guard timeout > 0, timeout <= 30 else {
            throw ValidationError("timeout must be greater than zero and no more than 30 seconds")
        }

        let message = try runControlCommand(
            userInfo: [
                AmethystControl.commandKey: AmethystControl.swapWindowsCommand,
                AmethystControl.windowIDKey: NSNumber(value: windowID),
                AmethystControl.otherWindowIDKey: NSNumber(value: otherWindowID),
            ],
            timeout: timeout
        )
        print(message)
    }
}

private func runControlCommand(userInfo: [AnyHashable: Any], timeout: Double) throws -> String {
    let requestID = UUID().uuidString
    var requestUserInfo = userInfo
    requestUserInfo[AmethystControl.requestIDKey] = requestID

    var response: (success: Bool, message: String)?
    let center = DistributedNotificationCenter.default()
    let observer = center.addObserver(
        forName: AmethystControl.responseNotification,
        object: nil,
        queue: .main
    ) { notification in
        guard notification.userInfo?[AmethystControl.requestIDKey] as? String == requestID else {
            return
        }
        let success = (notification.userInfo?[AmethystControl.successKey] as? NSNumber)?.boolValue ?? false
        let message = notification.userInfo?[AmethystControl.messageKey] as? String ?? "no response message"
        response = (success, message)
    }
    defer { center.removeObserver(observer) }

    center.postNotificationName(
        AmethystControl.requestNotification,
        object: nil,
        userInfo: requestUserInfo,
        deliverImmediately: true
    )

    let deadline = Date().addingTimeInterval(timeout)
    while response == nil, Date() < deadline {
        RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.1)))
    }

    guard let response else {
        throw ValidationError("running Amethyst did not respond within \(timeout) seconds")
    }
    guard response.success else {
        throw ValidationError(response.message)
    }
    return response.message
}

struct App: ParsableCommand {
    static var configuration: CommandConfiguration = CommandConfiguration(
        abstract: "Run the Amethyst application."
    )

    mutating func run() throws {
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

if CommandLine.arguments.contains("--debug-info") {
    print(DebugInfo.description(arguments: CommandLine.arguments))
} else if CommandLine.arguments.dropFirst().first == "test" {
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
} else {
    do {
        var command = try Amethyst.parseAsRoot()
        try command.run()
    } catch {
        Arguments.exit(withError: error)
    }
    Arguments.exit()
}
