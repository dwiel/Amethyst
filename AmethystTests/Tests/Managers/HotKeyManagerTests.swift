//
//  HotKeyManagerTests.swift
//  Amethyst
//
//  Created by Ian Ynda-Hummel on 4/18/17.
//  Copyright © 2017 Ian Ynda-Hummel. All rights reserved.
//

@testable import Amethyst
import Nimble
import Quick
import Silica

class HotKeyManagerTests: QuickSpec {
    override func spec() {
        describe("hotKeyNameToDefaultsKey") {
            it("has the right number of screens") {
                let keyMapping = HotKeyManager<SIApplication>.hotKeyNameToDefaultsKey()
                let screenCommands = keyMapping.filter { $0[1].hasPrefix(CommandKey.focusScreenPrefix.rawValue) }
                expect(screenCommands.count).to(equal(7))
            }
        }

        describe("WindowMoveControlRequest") {
            it("accepts an exact window and bounded desktop") {
                let request = try? WindowMoveControlRequest(userInfo: [
                    AmethystControl.requestIDKey: "request-1",
                    AmethystControl.windowIDKey: NSNumber(value: UInt32(60)),
                    AmethystControl.desktopKey: NSNumber(value: 2),
                ])

                expect(request?.requestID).to(equal("request-1"))
                expect(request?.windowID).to(equal(CGWindowID(60)))
                expect(request?.desktop).to(equal(2))
            }

            it("rejects an out-of-range desktop") {
                expect {
                    try WindowMoveControlRequest(userInfo: [
                        AmethystControl.requestIDKey: "request-2",
                        AmethystControl.windowIDKey: NSNumber(value: UInt32(60)),
                        AmethystControl.desktopKey: NSNumber(value: 20),
                    ])
                }.to(throwError(WindowMoveControlRequestError.invalidDesktop))
            }

            it("rejects a missing window id") {
                expect {
                    try WindowMoveControlRequest(userInfo: [
                        AmethystControl.requestIDKey: "request-3",
                        AmethystControl.desktopKey: NSNumber(value: 2),
                    ])
                }.to(throwError(WindowMoveControlRequestError.invalidWindowID))
            }
        }
    }
}
