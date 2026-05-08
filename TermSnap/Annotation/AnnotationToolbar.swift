import AppKit

class AnnotationToolbar: NSView {
    private let annotationView: AnnotationView
    private let stackView = NSStackView()
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    private static let barHeight: CGFloat = 44

    init(annotationView: AnnotationView, selectedRect: NSRect, parentBounds: NSRect) {
        self.annotationView = annotationView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.95).cgColor
        layer?.cornerRadius = 22
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 8
        layer?.shadowOffset = .zero

        setupStack()
        addToolButtons()
        addSeparator()
        addColorButtons()
        addSeparator()
        addWidthDots()
        addSeparator()
        addUndoRedoButtons()
        addSeparator()
        addActionButtons()

        let fittingWidth = stackView.fittingSize.width
        let minWidth: CGFloat = 750
        let contentWidth = fittingWidth > 0 ? ceil(fittingWidth) : minWidth
        let clampedWidth = min(contentWidth, parentBounds.width - 40)
        let barX = (parentBounds.width - clampedWidth) / 2
        frame = NSRect(x: barX, y: 20, width: clampedWidth, height: Self.barHeight)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupStack() {
        stackView.orientation = .horizontal
        stackView.spacing = 0
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.heightAnchor.constraint(equalToConstant: Self.barHeight)
        ])
    }

    // MARK: - Tool Buttons

    private func addToolButtons() {
        for tool in AnnotationTool.allCases {
            let btn = NSButton(frame: .zero)
            btn.bezelStyle = .shadowlessSquare
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 6
            btn.image = NSImage(systemSymbolName: tool.systemImage, accessibilityDescription: tool.tooltip)
            btn.image?.isTemplate = true
            btn.contentTintColor = .white
            btn.target = self
            btn.action = #selector(selectTool(_:))
            btn.tag = AnnotationTool.allCases.firstIndex(of: tool)!
            btn.toolTip = tool.tooltip
            btn.setContentHuggingPriority(.required, for: .horizontal)
            btn.widthAnchor.constraint(equalToConstant: 32).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
            stackView.addArrangedSubview(btn)
        }
    }

    // MARK: - Color Picker

    private func addColorButtons() {
        for (i, color) in ColorPalette.presets.enumerated() {
            let container = NSView(frame: .zero)
            container.wantsLayer = false
            container.widthAnchor.constraint(equalToConstant: 28).isActive = true
            container.heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true

            let btn = NSButton(frame: NSRect(x: 2, y: (Self.barHeight - 24) / 2, width: 24, height: 24))
            btn.bezelStyle = .shadowlessSquare
            btn.isBordered = false
            btn.title = ""
            btn.wantsLayer = true
            btn.layer?.backgroundColor = color.cgColor
            btn.layer?.cornerRadius = 12
            btn.layer?.borderWidth = i == 0 ? 2 : 0
            btn.layer?.borderColor = NSColor.white.cgColor
            btn.tag = 100 + i
            btn.target = self
            btn.action = #selector(selectColor(_:))
            btn.toolTip = colorName(color)
            btn.setContentHuggingPriority(.required, for: .horizontal)

            container.addSubview(btn)
            stackView.addArrangedSubview(container)
        }
    }

    // MARK: - Width Dots

    private func addWidthDots() {
        for width in [2, 4, 6] {
            let container = NSView(frame: .zero)
            container.wantsLayer = false
            container.widthAnchor.constraint(equalToConstant: 28).isActive = true
            container.heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true

            let dotSize = CGFloat(width) * 2 + 8
            let btn = NSButton(frame: NSRect(x: (28 - dotSize) / 2, y: (Self.barHeight - dotSize) / 2, width: dotSize, height: dotSize))
            btn.bezelStyle = .shadowlessSquare
            btn.isBordered = false
            btn.title = ""
            btn.wantsLayer = true
            btn.layer?.cornerRadius = dotSize / 2
            btn.layer?.backgroundColor = NSColor.white.cgColor
            btn.tag = 200 + width
            btn.target = self
            btn.action = #selector(selectWidth(_:))
            btn.toolTip = "\(width)px"
            btn.setContentHuggingPriority(.required, for: .horizontal)

            container.addSubview(btn)
            stackView.addArrangedSubview(container)
        }
    }

    // MARK: - Undo / Redo

    private func addUndoRedoButtons() {
        for (name, sel) in [("arrow.uturn.backward", #selector(undoAction)),
                            ("arrow.uturn.forward", #selector(redoAction))] {
            let btn = NSButton(frame: .zero)
            btn.bezelStyle = .shadowlessSquare
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 6
            btn.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            btn.image?.isTemplate = true
            btn.contentTintColor = .white
            btn.target = self
            btn.action = sel
            btn.setContentHuggingPriority(.required, for: .horizontal)
            btn.widthAnchor.constraint(equalToConstant: 28).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 28).isActive = true
            stackView.addArrangedSubview(btn)
        }
    }

    // MARK: - Separator

    private func addSeparator() {
        let container = NSView(frame: .zero)
        container.wantsLayer = false
        container.widthAnchor.constraint(equalToConstant: 10).isActive = true
        container.heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true

        let line = NSView(frame: NSRect(x: 4, y: 10, width: 1, height: 24))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        container.addSubview(line)

        stackView.addArrangedSubview(container)
    }

    // MARK: - Action Buttons (icons only: X = cancel, ↓ = save, ✓ = copy to clipboard)

    private func addActionButtons() {
        // X — close / cancel
        let cancelBtn = makeIconButton(
            symbol: "xmark",
            tag: 400,
            action: #selector(cancelAction),
            toolTip: NSLocalizedString("Cancel", comment: "")
        )
        stackView.addArrangedSubview(cancelBtn)

        // ↓ — save to file
        let saveBtn = makeIconButton(
            symbol: "square.and.arrow.down",
            tag: 402,
            action: #selector(saveAction),
            toolTip: NSLocalizedString("Save", comment: "")
        )
        stackView.addArrangedSubview(saveBtn)

        // ✓ — copy to clipboard (done)
        let doneBtn = makeIconButton(
            symbol: "checkmark",
            tag: 401,
            action: #selector(copyAction),
            toolTip: NSLocalizedString("Copy to Clipboard", comment: "")
        )
        stackView.addArrangedSubview(doneBtn)
    }

    private func makeIconButton(symbol: String, tag: Int, action: Selector, toolTip: String) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.bezelStyle = .shadowlessSquare
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 6
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        btn.image?.isTemplate = true
        btn.contentTintColor = .white
        btn.target = self
        btn.action = action
        btn.tag = tag
        btn.toolTip = toolTip
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.widthAnchor.constraint(equalToConstant: 32).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return btn
    }

    // MARK: - Actions

    @objc private func selectTool(_ sender: NSButton) {
        let tool = AnnotationTool.allCases[sender.tag]
        annotationView.currentTool = tool
        for case let btn as NSButton in stackView.arrangedSubviews {
            guard btn.tag < 100 else { continue }
            btn.layer?.backgroundColor = btn.tag == sender.tag ? NSColor(white: 1, alpha: 0.2).cgColor : .clear
        }
    }

    @objc private func selectColor(_ sender: NSButton) {
        let idx = sender.tag - 100
        guard idx >= 0, idx < ColorPalette.presets.count else { return }
        annotationView.currentColor = ColorPalette.presets[idx]
        for case let container as NSView in stackView.arrangedSubviews {
            guard let btn = container.subviews.first as? NSButton, btn.tag >= 100, btn.tag < 200 else { continue }
            btn.layer?.borderWidth = btn.tag == sender.tag ? 2 : 0
        }
    }

    @objc private func selectWidth(_ sender: NSButton) {
        annotationView.currentLineWidth = CGFloat(sender.tag - 200)
        for case let container as NSView in stackView.arrangedSubviews {
            guard let btn = container.subviews.first as? NSButton, btn.tag >= 200, btn.tag < 300 else { continue }
            let isSelected = btn.tag == sender.tag
            btn.layer?.opacity = isSelected ? 1.0 : 0.4
        }
    }

    @objc private func undoAction() { annotationView.undo() }
    @objc private func redoAction() { annotationView.redo() }
    @objc private func cancelAction() { onCancel?() }
    @objc private func saveAction() { onSave?() }
    @objc private func copyAction() { onCopy?() }

    private func colorName(_ color: NSColor) -> String {
        switch color {
        case .red: return NSLocalizedString("Red", comment: "")
        case .orange: return NSLocalizedString("Orange", comment: "")
        case .yellow: return NSLocalizedString("Yellow", comment: "")
        case .green: return NSLocalizedString("Green", comment: "")
        case .cyan: return NSLocalizedString("Cyan", comment: "")
        case .blue: return NSLocalizedString("Blue", comment: "")
        case .purple: return NSLocalizedString("Purple", comment: "")
        case .white: return NSLocalizedString("White", comment: "")
        case .black: return NSLocalizedString("Black", comment: "")
        case NSColor(white: 0.5, alpha: 1): return NSLocalizedString("Gray", comment: "")
        default: return ""
        }
    }
}
