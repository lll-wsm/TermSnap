import AppKit

/// Renders a provider icon entirely from the JSON `icon` field. No built-in brand registry,
/// no SF Symbol fallback — kept intentionally simple.
///
/// Resolution:
///  - If JSON has an `icon` object → render letter-mark with its label/color/text_color/shape
///  - If JSON has no `icon` (or it's empty) → render a neutral GRAY letter-mark using the
///    first character of the provider key (uppercased). Visual rows stay aligned.
///
/// Shapes supported: `"rounded"` (default), `"circle"`, `"square"`.
enum ClaudeProviderIcon {

    /// Neutral defaults applied to any field the JSON leaves out.
    private static let defaultBackground = NSColor(white: 0.55, alpha: 1.0)
    private static let defaultForeground = NSColor.white
    private static let defaultShape = "rounded"

    enum Shape {
        case rounded
        case circle
        case square

        init(rawValue: String?) {
            switch (rawValue ?? defaultShape).lowercased() {
            case "circle":  self = .circle
            case "square":  self = .square
            default:        self = .rounded
            }
        }
    }

    // MARK: - Public entry

    /// Returns a square icon for the provider. Pass the provider's `iconOverride` to drive
    /// rendering; nil falls back to a gray first-letter mark.
    static func image(for providerKey: String,
                      override: ProviderIconSpec? = nil,
                      size: CGFloat = 16) -> NSImage {
        let label = resolveLabel(override?.label, providerKey: providerKey)
        let bg = override?.color.flatMap(parseHexColor) ?? defaultBackground
        let fg = override?.textColor.flatMap(parseHexColor) ?? defaultForeground
        let shape = Shape(rawValue: override?.shape)
        return letterMark(label: label, background: bg, textColor: fg, shape: shape, size: size)
    }

    private static func resolveLabel(_ explicit: String?, providerKey: String) -> String {
        if let l = explicit, !l.isEmpty { return l }
        // Fall back to the first character of the key, uppercased. Empty keys get "?".
        return providerKey.first.map { String($0).uppercased() } ?? "?"
    }

    // MARK: - Rendering

    /// Draws the chosen shape filled with `background`, then centers `label` in `textColor`.
    static func letterMark(label: String,
                           background: NSColor,
                           textColor: NSColor,
                           shape: Shape,
                           size: CGFloat) -> NSImage {
        let pixel = NSSize(width: size, height: size)
        let image = NSImage(size: pixel)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: pixel)
        let path = bezierPath(for: shape, in: rect)
        background.setFill()
        path.fill()

        // 1-char labels get a larger glyph than 2-char labels so the mark stays balanced.
        let baseRatio: CGFloat = label.count >= 2 ? 0.42 : 0.58
        let fontSize = size * baseRatio
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let text = label as NSString
        let textSize = text.size(withAttributes: attrs)
        let textRect = NSRect(
            x: (pixel.width - textSize.width) / 2,
            y: (pixel.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attrs)

        return image
    }

    private static func bezierPath(for shape: Shape, in rect: NSRect) -> NSBezierPath {
        switch shape {
        case .rounded:
            let corner = rect.width * 0.22
            return NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        case .circle:
            return NSBezierPath(ovalIn: rect)
        case .square:
            return NSBezierPath(rect: rect)
        }
    }

    // MARK: - Hex parser

    /// Parses `#RRGGBB`, `RRGGBB`, `#RRGGBBAA`, or `RRGGBBAA`. Case-insensitive.
    static func parseHexColor(_ raw: String) -> NSColor? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        if hex.count == 6 {
            r = CGFloat((value >> 16) & 0xff) / 255
            g = CGFloat((value >>  8) & 0xff) / 255
            b = CGFloat( value        & 0xff) / 255
            a = 1
        } else {
            r = CGFloat((value >> 24) & 0xff) / 255
            g = CGFloat((value >> 16) & 0xff) / 255
            b = CGFloat((value >>  8) & 0xff) / 255
            a = CGFloat( value        & 0xff) / 255
        }
        return NSColor(red: r, green: g, blue: b, alpha: a)
    }
}
