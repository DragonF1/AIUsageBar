import AppKit
import SwiftUI
import XCTest
@testable import AIUsageBar

/// `PanelWindow.make` is the one place every floating window (Sessions, Cost, Settings) gets its
/// chrome from, so these tests lock that chrome down rather than each controller's own window.
final class PanelWindowTests: XCTestCase {
    private func hosting() -> NSHostingController<AnyView> {
        NSHostingController(rootView: AnyView(Text("x")))
    }

    @MainActor func testMakeSetsSharedChrome() {
        let window = PanelWindow.make(title: "Title", hosting: hosting(), resizable: false)
        XCTAssertEqual(window.title, "Title")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .windowBackgroundColor)
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertFalse(window.styleMask.contains(.resizable))
    }

    @MainActor func testMakeResizableAddsResizableToStyleMask() {
        let window = PanelWindow.make(title: "Title", hosting: hosting(), resizable: true)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
    }
}
