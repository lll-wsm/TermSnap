import AppKit

enum AnnotationTool: String, CaseIterable {
    case rect
    case ellipse
    case arrow
    case line
    case pen
    case text
    case mosaic

    var systemImage: String {
        switch self {
        case .rect: return "square"
        case .ellipse: return "circle"
        case .arrow: return "arrowshape.right"
        case .line: return "line.diagonal"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .mosaic: return "square.grid.3x3.fill"
        }
    }

    var tooltip: String {
        switch self {
        case .rect: return NSLocalizedString("Rectangle", comment: "")
        case .ellipse: return NSLocalizedString("Ellipse", comment: "")
        case .arrow: return NSLocalizedString("Arrow", comment: "")
        case .line: return NSLocalizedString("Line", comment: "")
        case .pen: return NSLocalizedString("Freehand", comment: "")
        case .text: return NSLocalizedString("Text", comment: "")
        case .mosaic: return NSLocalizedString("Mosaic", comment: "")
        }
    }
}
