import XCTest
import SwiftUI
@testable import LexiApp

final class BadgeTooltipLayoutTests: XCTestCase {
    func testAdjacentRightAndLeft() {
        let bounds = CGRect(x: 0, y: 0, width: 1100, height: 750)
        let size = CGSize(width: 220, height: 75)
        let badge = CGRect(x: 530, y: 350, width: 30, height: 20)
        XCTAssertEqual(BadgeTooltipLayout.origin(anchor: badge, size: size, bounds: bounds).x, 568)
        let rightEdge = CGRect(x: 1060, y: 350, width: 30, height: 20)
        XCTAssertEqual(BadgeTooltipLayout.origin(anchor: rightEdge, size: size, bounds: bounds).x, 832)
    }
    func testClampsVerticallyAtWindowEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 920, height: 580)
        let size = CGSize(width: 260, height: 100)
        let top = CGRect(x: 500, y: 2, width: 30, height: 20)
        let bottom = CGRect(x: 500, y: 550, width: 30, height: 20)
        XCTAssertEqual(BadgeTooltipLayout.origin(anchor: top, size: size, bounds: bounds).y, 8)
        XCTAssertEqual(BadgeTooltipLayout.origin(anchor: bottom, size: size, bounds: bounds).y, 472)
    }
}
