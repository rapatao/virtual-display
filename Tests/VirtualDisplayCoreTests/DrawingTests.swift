import XCTest
@testable import VirtualDisplayCore

@MainActor
final class DrawingTests: XCTestCase {

    private func stroke(_ tool: DrawingTool) -> Stroke {
        Stroke(tool: tool, color: .red, width: 0.01, points: [.zero])
    }

    func testUndoSkipsLaserStrokes() {
        let drawing = Drawing()
        drawing.begin(stroke(.pen)); drawing.end()
        drawing.begin(stroke(.highlighter)); drawing.end()
        drawing.begin(stroke(.laser))
        drawing.undo()
        XCTAssertEqual(drawing.strokes.map(\.tool), [.pen, .laser])
        drawing.undo()
        drawing.undo()
        XCTAssertEqual(drawing.strokes.map(\.tool), [.laser])
    }

    func testOnlyAnEndedLaserFades() {
        let ended = Date()
        var laser = stroke(.laser)
        XCTAssertEqual(Drawing.opacity(of: laser, at: ended + 10), 1)
        laser.endedAt = ended
        XCTAssertEqual(Drawing.opacity(of: laser, at: ended + Drawing.laserFade / 2), 0.5, accuracy: 0.001)
        var pen = stroke(.pen)
        pen.endedAt = ended
        XCTAssertEqual(Drawing.opacity(of: pen, at: ended + 10), 1)
    }

    func testFadedLasersAreRemoved() {
        let drawing = Drawing()
        let start = Date()
        drawing.begin(stroke(.pen)); drawing.end(at: start)
        drawing.begin(stroke(.laser)); drawing.end(at: start)
        drawing.removeFaded(at: start + Drawing.laserFade + 0.1)
        XCTAssertEqual(drawing.strokes.map(\.tool), [.pen])
    }

    func testExtendGrowsOnlyTheStrokeInProgress() {
        let drawing = Drawing()
        drawing.begin(stroke(.pen))
        drawing.extend(to: CGPoint(x: 0.5, y: 0.5))
        drawing.end()
        drawing.extend(to: CGPoint(x: 1, y: 1))
        XCTAssertEqual(drawing.strokes.first?.points.count, 2)
    }
}

@MainActor
final class RegionDrawingTests: XCTestCase {

    private func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1,
                                           pressure: 1)!
            if type == .leftMouseUp { NSApp.postEvent(event, atStart: false) } else { window.sendEvent(event) }
        }
    }

    func testStrokesStartAnywhereInTheRegionIncludingUnderTheHiddenTitleBar() {
        let drawing = Drawing()
        let window = RegionWindow(drawing: drawing)
        window.isEditing = false
        window.isDrawing = true
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let height = window.contentView!.bounds.height
        click(window, at: NSPoint(x: 100, y: height / 2))
        click(window, at: NSPoint(x: 100, y: height - 5))
        XCTAssertEqual(drawing.strokes.count, 2)
    }

    func testNothingIsDrawnOutsideDrawMode() {
        let drawing = Drawing()
        let window = RegionWindow(drawing: drawing)
        window.isEditing = true
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        click(window, at: NSPoint(x: 100, y: 100))
        XCTAssertTrue(drawing.strokes.isEmpty)
    }
}
