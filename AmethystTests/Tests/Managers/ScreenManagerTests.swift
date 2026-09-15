//
//  ScreenManagerTests.swift
//  AmethystTests
//
//  Created by Ian Ynda-Hummel on 2/11/20.
//  Copyright © 2020 Ian Ynda-Hummel. All rights reserved.
//

@testable import Amethyst
import Nimble
import Quick
import Silica
import SwiftyJSON
import XCTest

private final class TestDelegate: ScreenManagerDelegate {
    typealias Window = TestWindow
    var windows: [TestWindow] = []
    var activeSetRequests = 0
    var completions = 0
    var onInitiation: (() -> Void)?
    var onCompletion: (() -> Void)?

    func applyWindowLimit(forScreenManager screenManager: ScreenManager<TestDelegate>, minimizingIn range: (Int) -> Range<Int>) {
        // The fake windows never minimize real applications.
    }
    func activeWindowSet(forScreenManager screenManager: ScreenManager<TestDelegate>) -> WindowSet<TestWindow> {
        activeSetRequests += 1
        let snapshot = windows
        return WindowSet(
            windows: snapshot.map { LayoutWindow(id: $0.id(), frame: $0.frame(), isFocused: $0.isFocused()) },
            isWindowWithIDActive: { _ in true },
            isWindowWithIDFloating: { _ in false },
            windowForID: { id in snapshot.first { $0.id() == id } }
        )
    }
    func onReflowInitiation() {
        onInitiation?()
    }
    func onReflowCompletion() {
        completions += 1
        onCompletion?()
    }
}

class ScreenManagerTests: QuickSpec {
    override func spec() {
        describe("coding") {
            it("decodes layouts") {
                let configuration = UserConfiguration(storage: TestConfigurationStorage())
                configuration.setLayoutKeys(LayoutType<TestWindow>.standardLayoutClasses().map { $0.layoutKey })

                let layouts = LayoutType<TestWindow>.standardLayoutClasses().map { $0.init() }
                let encoder = JSONEncoder()
                let encodedLayouts = layouts.map { ["key": $0.layoutKey.data(using: .utf8)!, "data": try! encoder.encode($0)] }
                let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                expect(decodedLayouts.count).to(equal(layouts.count))
                expect(decodedLayouts.count).to(equal(encodedLayouts.count))
                expect(decodedLayouts.map { $0.layoutKey }).to(equal(layouts.map { $0.layoutKey }))
            }

            it("replaces incorrectly encoded layouts") {
                let configuration = UserConfiguration(storage: TestConfigurationStorage())
                configuration.setLayoutKeys([FullscreenLayout<TestWindow>.layoutKey, TallLayout<TestWindow>.layoutKey])

                let encoder = JSONEncoder()
                let encodedLayouts = [
                    ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(FullscreenLayout<TestWindow>())],
                    ["key": TallLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(["incorrect": "encoding"])]
                ]
                let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                expect {
                    try JSONDecoder().decode(TallLayout<TestWindow>.self, from: encodedLayouts[1]["data"]!)
                }.to(throwError())

                expect(decodedLayouts.count).to(equal(2))
                expect(decodedLayouts.map { $0.layoutKey }).to(equal(configuration.layoutKeys()))
            }

            it("replaces incorrectly keyed layouts") {
                let configuration = UserConfiguration(storage: TestConfigurationStorage())
                configuration.setLayoutKeys([FullscreenLayout<TestWindow>.layoutKey, TallLayout<TestWindow>.layoutKey])

                let encoder = JSONEncoder()
                let encodedLayouts = [
                    ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(FullscreenLayout<TestWindow>())],
                    ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(TallLayout<TestWindow>())]
                ]
                let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                expect(decodedLayouts.count).to(equal(2))
                expect(decodedLayouts.map { $0.layoutKey }).to(equal(configuration.layoutKeys()))
            }

            context("layout list changes") {
                it("maintains encoded layouts on insertions") {
                    let configuration = UserConfiguration(storage: TestConfigurationStorage())
                    configuration.setLayoutKeys([
                        FullscreenLayout<TestWindow>.layoutKey,
                        WideLayout<TestWindow>.layoutKey,
                        TallLayout<TestWindow>.layoutKey
                    ])

                    let encoder = JSONEncoder()
                    let tallLayout = TallLayout<TestWindow>()
                    tallLayout.increaseMainPaneCount()

                    expect(tallLayout.mainPaneCount).to(equal(2))

                    let encodedLayouts = [
                        ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(FullscreenLayout<TestWindow>())],
                        ["key": TallLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(tallLayout)]
                    ]
                    let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                    expect(decodedLayouts.count).to(equal(3))
                    expect(decodedLayouts.map { $0.layoutKey }).to(equal(configuration.layoutKeys()))
                    expect((decodedLayouts.last as? TallLayout<TestWindow>)?.mainPaneCount).to(equal(2))
                }

                it("maintains encoded layouts on appends") {
                    let configuration = UserConfiguration(storage: TestConfigurationStorage())
                    configuration.setLayoutKeys([
                        FullscreenLayout<TestWindow>.layoutKey,
                        TallLayout<TestWindow>.layoutKey,
                        WideLayout<TestWindow>.layoutKey
                    ])

                    let encoder = JSONEncoder()
                    let tallLayout = TallLayout<TestWindow>()
                    tallLayout.increaseMainPaneCount()

                    expect(tallLayout.mainPaneCount).to(equal(2))

                    let encodedLayouts = [
                        ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(FullscreenLayout<TestWindow>())],
                        ["key": TallLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(tallLayout)]
                    ]
                    let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                    expect(decodedLayouts.count).to(equal(3))
                    expect(decodedLayouts.map { $0.layoutKey }).to(equal(configuration.layoutKeys()))
                    expect((decodedLayouts[1] as? TallLayout<TestWindow>)?.mainPaneCount).to(equal(2))
                }

                it("maintains encoded layouts on prepends") {
                    let configuration = UserConfiguration(storage: TestConfigurationStorage())
                    configuration.setLayoutKeys([
                        WideLayout<TestWindow>.layoutKey,
                        FullscreenLayout<TestWindow>.layoutKey,
                        TallLayout<TestWindow>.layoutKey
                    ])

                    let encoder = JSONEncoder()
                    let tallLayout = TallLayout<TestWindow>()
                    tallLayout.increaseMainPaneCount()

                    expect(tallLayout.mainPaneCount).to(equal(2))

                    let encodedLayouts = [
                        ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(FullscreenLayout<TestWindow>())],
                        ["key": TallLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(tallLayout)]
                    ]
                    let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                    expect(decodedLayouts.count).to(equal(3))
                    expect(decodedLayouts.map { $0.layoutKey }).to(equal(configuration.layoutKeys()))
                    expect((decodedLayouts.last as? TallLayout<TestWindow>)?.mainPaneCount).to(equal(2))
                }

                it("maintains existing layouts on deletes") {
                    let configuration = UserConfiguration(storage: TestConfigurationStorage())
                    configuration.setLayoutKeys([
                        WideLayout<TestWindow>.layoutKey,
                        TallLayout<TestWindow>.layoutKey
                    ])

                    let encoder = JSONEncoder()
                    let wideLayout = WideLayout<TestWindow>()
                    let tallLayout = TallLayout<TestWindow>()
                    wideLayout.increaseMainPaneCount()
                    tallLayout.increaseMainPaneCount()

                    expect(wideLayout.mainPaneCount).to(equal(2))
                    expect(tallLayout.mainPaneCount).to(equal(2))

                    let encodedLayouts = [
                        ["key": WideLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(wideLayout)],
                        ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(FullscreenLayout<TestWindow>())],
                        ["key": TallLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(tallLayout)]
                    ]
                    let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                    expect(decodedLayouts.count).to(equal(2))
                    expect(decodedLayouts.map { $0.layoutKey }).to(equal(configuration.layoutKeys()))
                    expect((decodedLayouts.first as? WideLayout<TestWindow>)?.mainPaneCount).to(equal(2))
                    expect((decodedLayouts.last as? TallLayout<TestWindow>)?.mainPaneCount).to(equal(2))
                }
            }
        }
    }
}


final class ReflowRegressionTests: XCTestCase {
    private let space = Space(id: 1, type: CGSSpaceTypeUser, uuid: "test-space")

    override func tearDown() {
        TestScreen.availableScreens = []
        TestScreen.descriptions = []
        super.tearDown()
    }

    private func manager(_ delegate: TestDelegate) -> ScreenManager<TestDelegate> {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 2000, height: 1000))
        TestScreen.availableScreens.append(screen)
        TestScreen.descriptions.append(JSON([
            "Display Identifier": screen.screenID()!,
            "Current Space": ["ManagedSpaceID": 1, "type": 0, "uuid": "test-space"]
        ]))
        let configuration = UserConfiguration(storage: TestConfigurationStorage())
        configuration.setLayoutKeys([TallLayout<TestWindow>.layoutKey, FullscreenLayout<TestWindow>.layoutKey])
        let manager = ScreenManager(screen: screen, delegate: delegate, userConfiguration: configuration)
        manager.updateSpace(to: space)
        return manager
    }

    private func finishReflow(_ manager: ScreenManager<TestDelegate>, delegate: TestDelegate, request: (() -> Void)? = nil) {
        let completed = expectation(description: "reflow completed")
        delegate.onCompletion = { completed.fulfill() }
        if let request {
            request()
        } else {
            manager.setNeedsReflow()
        }
        waitForExpectations(timeout: 3)
        delegate.onCompletion = nil
    }

    func testCoalescesPendingRequests() {
        let delegate = TestDelegate()
        delegate.windows = [TestWindow(element: nil)!]
        let manager = manager(delegate)
        manager.setNeedsReflow()
        manager.setNeedsReflow()
        finishReflow(manager, delegate: delegate)
        XCTAssertEqual(delegate.activeSetRequests, 1)
        XCTAssertEqual(delegate.completions, 1)
    }

    func testDepartureDuringReflowRemainsVisibleToRecovery() {
        let delegate = TestDelegate()
        let first = TestWindow(element: nil)!
        let second = TestWindow(element: nil)!
        delegate.windows = [first, second]
        let manager = manager(delegate)
        // A silent departure after the layout was calculated, before completion.
        delegate.onInitiation = { delegate.windows = [first] }
        finishReflow(manager, delegate: delegate)
        XCTAssertEqual(manager.lastReflowWindowIDs, Set([first.id(), second.id()]))
        XCTAssertTrue(manager.needsReflow(windowIDs: Set([first.id()]), in: space))
        finishReflow(manager, delegate: delegate)
        XCTAssertFalse(manager.needsReflow(windowIDs: Set([first.id()]), in: space))
    }

    func testOtherDisplayCompletionDoesNotErasePendingDeparture() {
        let firstDelegate = TestDelegate()
        let first = TestWindow(element: nil)!
        let departed = TestWindow(element: nil)!
        firstDelegate.windows = [first, departed]
        let firstManager = manager(firstDelegate)
        finishReflow(firstManager, delegate: firstDelegate)
        firstDelegate.windows = [first]

        let otherDelegate = TestDelegate()
        otherDelegate.windows = [TestWindow(element: nil)!]
        let otherManager = manager(otherDelegate)
        finishReflow(otherManager, delegate: otherDelegate)
        XCTAssertTrue(firstManager.needsReflow(windowIDs: Set([first.id()]), in: space))
    }

    func testSupersededLayoutNeverMovesWindowsOrReportsCompletion() {
        let delegate = TestDelegate()
        let windows = [TestWindow(element: nil)!, TestWindow(element: nil)!]
        delegate.windows = windows
        let manager = manager(delegate)
        // Replace the two-pane layout after calculation, while its jobs are queued.
        delegate.onInitiation = {
            delegate.onInitiation = nil
            manager.selectLayout(FullscreenLayout<TestWindow>.layoutKey)
        }
        finishReflow(manager, delegate: delegate)
        XCTAssertEqual(delegate.completions, 1)
        for window in windows {
            XCTAssertEqual(window.assignedFrames.count, 1)
            XCTAssertEqual(window.frame().width, 2000)
        }
    }

    func testDisplaySizeChangeRequiresRecoveryEvenWithSameWindows() {
        let delegate = TestDelegate()
        let window = TestWindow(element: nil)!
        delegate.windows = [window]
        let manager = manager(delegate)
        finishReflow(manager, delegate: delegate)
        XCTAssertFalse(manager.needsReflow(windowIDs: Set([window.id()]), in: space))
        manager.screen!.internalFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertTrue(manager.needsReflow(windowIDs: Set([window.id()]), in: space))
    }

    func testCancelledOperationDoesNotWriteFrames() {
        let delegate = TestDelegate()
        let window = TestWindow(element: nil)!
        delegate.windows = [window]
        let manager = manager(delegate)
        let operation = TallLayout<TestWindow>().frameAssignments(
            delegate.activeWindowSet(forScreenManager: manager), on: manager.screen!
        )!.first!
        operation.cancel()
        operation.main()
        XCTAssertTrue(window.assignedFrames.isEmpty)
    }

    func testReturnFromOtherDisplayRetriesIgnoredMoveWithUnchangedMembership() {
        let delegate = TestDelegate()
        let first = TestWindow(element: nil)!
        let returned = TestWindow(element: nil)!
        returned.isFocusedValue = true
        delegate.windows = [first, returned]
        let manager = manager(delegate)
        finishReflow(manager, delegate: delegate)
        let correctFrame = returned.frame()

        // After an out-and-back throw, Chrome ignores both focused-window writes.
        let strandedFrame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        returned.setFrame(strandedFrame, withThreshold: .zero)
        returned.frameTransform = { _ in strandedFrame }
        finishReflow(manager, delegate: delegate)
        XCTAssertEqual(returned.frame(), strandedFrame)
        XCTAssertFalse(manager.needsReflow(windowIDs: Set([first.id(), returned.id()]), in: space))

        returned.frameTransform = nil
        finishReflow(manager, delegate: delegate) {
            XCTAssertTrue(manager.retryUnappliedFramesIfNeeded())
        }
        XCTAssertEqual(returned.frame(), correctFrame)
        XCTAssertFalse(manager.retryUnappliedFramesIfNeeded())
    }

    func testDelayedFrameAcceptanceNeedsNoRetry() {
        let delegate = TestDelegate()
        let window = TestWindow(element: nil)!
        window.frameTransform = { _ in .zero }
        delegate.windows = [window]
        let manager = manager(delegate)
        finishReflow(manager, delegate: delegate)
        // AX reports the old frame immediately, but the app applies it later.
        window.frameTransform = nil
        window.setFrame(window.assignedFrames.last!, withThreshold: .zero)
        XCTAssertFalse(manager.retryUnappliedFramesIfNeeded())
        XCTAssertEqual(delegate.completions, 1)
    }

    func testFrameOverwrittenAfterCompletionIsStillVerified() {
        let delegate = TestDelegate()
        let window = TestWindow(element: nil)!
        delegate.windows = [window]
        let manager = manager(delegate)
        finishReflow(manager, delegate: delegate)
        let correctFrame = window.frame()
        window.setFrame(.zero, withThreshold: .zero)
        finishReflow(manager, delegate: delegate) {
            XCTAssertTrue(manager.retryUnappliedFramesIfNeeded())
        }
        XCTAssertEqual(window.frame(), correctFrame)
    }

    func testPermanentSizeConstraintStopsAfterThreeRetries() {
        let delegate = TestDelegate()
        let window = TestWindow(element: nil)!
        window.isFocusedValue = true
        window.frameTransform = { CGRect(origin: $0.origin, size: CGSize(width: max(1200, $0.width), height: $0.height)) }
        delegate.windows = [TestWindow(element: nil)!, window]
        let manager = manager(delegate)
        finishReflow(manager, delegate: delegate)
        for _ in 0..<3 {
            finishReflow(manager, delegate: delegate) {
                XCTAssertTrue(manager.retryUnappliedFramesIfNeeded())
            }
        }
        XCTAssertFalse(manager.retryUnappliedFramesIfNeeded())
        XCTAssertFalse(manager.retryUnappliedFramesIfNeeded())
        XCTAssertEqual(delegate.completions, 4)
        XCTAssertEqual(window.frame().width, 1200)
        XCTAssertEqual(window.frame().maxX, 2000) // Keep the focused window on screen.
    }

    func testNewLayoutDiscardsOldFrameVerification() {
        let delegate = TestDelegate()
        let window = TestWindow(element: nil)!
        window.frameTransform = { _ in .zero }
        delegate.windows = [TestWindow(element: nil)!, window]
        let manager = manager(delegate)
        finishReflow(manager, delegate: delegate)
        window.frameTransform = nil
        finishReflow(manager, delegate: delegate) {
            manager.selectLayout(FullscreenLayout<TestWindow>.layoutKey)
            XCTAssertFalse(manager.retryUnappliedFramesIfNeeded())
        }
        XCTAssertEqual(window.frame().width, 2000)
        XCTAssertFalse(manager.retryUnappliedFramesIfNeeded())
    }

    func testSpaceChangeDiscardsOldFrameVerification() {
        let delegate = TestDelegate()
        let window = TestWindow(element: nil)!
        window.frameTransform = { _ in .zero }
        delegate.windows = [window]
        let manager = manager(delegate)
        finishReflow(manager, delegate: delegate)
        TestScreen.descriptions = [JSON([
            "Display Identifier": manager.screen!.screenID()!,
            "Current Space": ["ManagedSpaceID": 2, "type": 0, "uuid": "other-space"]
        ])]
        XCTAssertFalse(manager.retryUnappliedFramesIfNeeded())
        XCTAssertEqual(delegate.completions, 1)
    }
}
