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
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .pen: return "Freehand"
        case .text: return "Text"
        case .mosaic: return "Mosaic"
        }
    }
}
