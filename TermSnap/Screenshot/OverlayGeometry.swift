import CoreGraphics

enum OverlayGeometry {
    static func toGlobalTopLeft(point: CGPoint, on screenFrame: CGRect, desktopBounds: CGRect) -> CGPoint {
        let absoluteX = screenFrame.origin.x + point.x
        let absoluteY = screenFrame.origin.y + point.y
        let topLeftY = desktopBounds.maxY - absoluteY
        return CGPoint(x: absoluteX, y: topLeftY)
    }

    static func fromGlobalTopLeft(rect: CGRect, toLocalOn screenFrame: CGRect, desktopBounds: CGRect) -> CGRect {
        let absoluteX = rect.origin.x
        let absoluteY = desktopBounds.maxY - rect.maxY
        let localX = absoluteX - screenFrame.origin.x
        let localY = absoluteY - screenFrame.origin.y

        return CGRect(x: localX, y: localY, width: rect.width, height: rect.height)
    }
}
