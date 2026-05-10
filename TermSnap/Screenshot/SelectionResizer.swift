import AppKit

enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight

    static let handleSize: CGFloat = 8

    func cursor() -> NSCursor {
        switch self {
        case .topLeft, .bottomRight: return .crosshair
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topRight, .bottomLeft: return .crosshair
        }
    }
}

struct SelectionResizer {
    let selectionRect: NSRect

    func handleRects() -> [ResizeHandle: NSRect] {
        let hs = ResizeHandle.handleSize
        let half = hs / 2
        var result: [ResizeHandle: NSRect] = [:]
        for handle in ResizeHandle.allCases {
            let point = handlePoint(handle)
            result[handle] = NSRect(x: point.x - half, y: point.y - half, width: hs, height: hs)
        }
        return result
    }

    func handleAt(_ point: NSPoint) -> ResizeHandle? {
        for (handle, rect) in handleRects() {
            if rect.contains(point) { return handle }
        }
        return nil
    }

    func cursorAt(_ point: NSPoint) -> NSCursor {
        if let handle = handleAt(point) { return handle.cursor() }
        if selectionRect.contains(point) { return .openHand }
        return .arrow
    }

    func rectByResizing(_ rect: NSRect, handle: ResizeHandle, delta: NSPoint, minSize: CGFloat = 20) -> NSRect {
        var r = rect

        switch handle {
        case .topLeft:
            r.origin.x += delta.x; r.size.width -= delta.x
            r.origin.y += delta.y; r.size.height -= delta.y
        case .top:
            r.origin.y += delta.y; r.size.height -= delta.y
        case .topRight:
            r.size.width += delta.x
            r.origin.y += delta.y; r.size.height -= delta.y
        case .left:
            r.origin.x += delta.x; r.size.width -= delta.x
        case .right:
            r.size.width += delta.x
        case .bottomLeft:
            r.origin.x += delta.x; r.size.width -= delta.x
            r.size.height += delta.y
        case .bottom:
            r.size.height += delta.y
        case .bottomRight:
            r.size.width += delta.x
            r.size.height += delta.y
        }

        if r.size.width < minSize {
            r.size.width = minSize
            if handle == .topLeft || handle == .left || handle == .bottomLeft {
                r.origin.x = rect.maxX - minSize
            }
        }
        if r.size.height < minSize {
            r.size.height = minSize
            if handle == .topLeft || handle == .top || handle == .topRight {
                r.origin.y = rect.maxY - minSize
            }
        }
        return r
    }

    private func handlePoint(_ handle: ResizeHandle) -> NSPoint {
        let r = selectionRect
        switch handle {
        case .topLeft:     return NSPoint(x: r.minX, y: r.maxY)
        case .top:         return NSPoint(x: r.midX, y: r.maxY)
        case .topRight:    return NSPoint(x: r.maxX, y: r.maxY)
        case .left:        return NSPoint(x: r.minX, y: r.midY)
        case .right:       return NSPoint(x: r.maxX, y: r.midY)
        case .bottomLeft:  return NSPoint(x: r.minX, y: r.minY)
        case .bottom:      return NSPoint(x: r.midX, y: r.minY)
        case .bottomRight: return NSPoint(x: r.maxX, y: r.minY)
        }
    }
}
