import Testing
import AppKit
@testable import TermSnap

struct SelectionResizerTests {
    let rect = NSRect(x: 100, y: 100, width: 200, height: 150)
    var resizer: SelectionResizer { SelectionResizer(selectionRect: rect) }

    @Test func handleDetectionOnCorner() {
        // In flipped view, minX/minY is Top-Left (100, 100)
        let handle = resizer.handleAt(NSPoint(x: 100, y: 100))
        #expect(handle == .topLeft)
    }

    @Test func handleDetectionInsideReturnsNil() {
        let handle = resizer.handleAt(NSPoint(x: 150, y: 150))
        #expect(handle == nil)
    }

    @Test func handleDetectionOnBottomRightCorner() {
        // In flipped view, maxX/maxY is Bottom-Right (300, 250)
        let handle = resizer.handleAt(NSPoint(x: 300, y: 250))
        #expect(handle == .bottomRight)
    }

    @Test func handleDetectionOnEdge() {
        // midX/minY is Top edge (200, 100)
        let handle = resizer.handleAt(NSPoint(x: 200, y: 100))
        #expect(handle == .top)
    }

    @Test func resizeFromTopLeftExpandsRect() {
        // Moving Top-Left further up and left (-dx, -dy) should expand the rect
        let result = resizer.rectByResizing(rect, handle: .topLeft, delta: NSPoint(x: -10, y: -10))
        #expect(result.origin.x == 90)
        #expect(result.origin.y == 90)
        #expect(result.size.width == 210)
        #expect(result.size.height == 160)
    }

    @Test func resizeFromRightEdge() {
        let result = resizer.rectByResizing(rect, handle: .right, delta: NSPoint(x: 20, y: 0))
        #expect(result.size.width == 220)
        #expect(result.origin.x == 100) // Left edge fixed
    }

    @Test func resizeEnforcesMinimumSize() {
        let result = resizer.rectByResizing(rect, handle: .bottomRight, delta: NSPoint(x: -200, y: -200))
        #expect(result.size.width >= 20)
        #expect(result.size.height >= 20)
    }

    @Test func cursorAtHandleReturnsResizeCursor() {
        let cursor = resizer.cursorAt(NSPoint(x: 100, y: 100))
        #expect(cursor == .crosshair)
    }

    @Test func cursorInsideReturnsArrow() {
        let cursor = resizer.cursorAt(NSPoint(x: 150, y: 150))
        #expect(cursor == .arrow)
    }

    @Test func handleDetectionOnLeftEdge() {
        let handle = resizer.handleAt(NSPoint(x: 100, y: 175))
        #expect(handle == .left)
    }

    @Test func handleDetectionOnRightEdge() {
        let handle = resizer.handleAt(NSPoint(x: 300, y: 175))
        #expect(handle == .right)
    }

    @Test func handleDetectionOnBottomEdge() {
        let handle = resizer.handleAt(NSPoint(x: 200, y: 250))
        #expect(handle == .bottom)
    }
}
