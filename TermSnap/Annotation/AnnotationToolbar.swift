import AppKit

class AnnotationToolbar: NSView {
    private let annotationView: AnnotationView
    private let stackView = NSStackView()
    private var colorWell: NSColorWell?
    private var colorButton: NSButton?
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
        addColorPicker()
        addSeparator()
        addWidthDots()
        addSeparator()
        addUndoRedoButtons()
        addSeparator()
        addActionButtons()

        // Calculate size based on stack view content
        let fittingWidth = stackView.fittingSize.width
        let minWidth: CGFloat = 400
        let contentWidth = max(minWidth, ceil(fittingWidth))
        let clampedWidth = min(contentWidth, parentBounds.width - 20)
        
        self.frame = NSRect(x: 0, y: 0, width: clampedWidth, height: Self.barHeight)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupStack() {
        stackView.orientation = .horizontal
        stackView.spacing = 2 // Small spacing between standard 32px items
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
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
            
            // Initial selection highlight
            if tool == annotationView.currentTool {
                btn.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
            }
        }
    }

    // MARK: - Color Picker

    private func addColorPicker() {
        // We use a custom button for the visual "square" to bypass NSColorWell's size limits
        let btn = NSButton(frame: .zero)
        btn.bezelStyle = .shadowlessSquare
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 2
        btn.layer?.backgroundColor = annotationView.currentColor.cgColor
        btn.title = ""
        btn.target = self
        btn.action = #selector(openColorPicker(_:))
        btn.toolTip = NSLocalizedString("Color Picker", comment: "")
        
        let container = NSView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 32).isActive = true // Match other tools
        container.heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true
        
        container.addSubview(btn)
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            btn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            btn.widthAnchor.constraint(equalToConstant: 14), // Perfect square size
            btn.heightAnchor.constraint(equalToConstant: 14)
        ])
        
        self.colorButton = btn
        stackView.addArrangedSubview(container)
        
        // Hidden ColorWell that actually manages the system color panel
        let well = NSColorWell(frame: .zero)
        well.isHidden = true
        well.target = self
        well.action = #selector(colorChanged(_:))
        addSubview(well)
        self.colorWell = well
    }

    @objc private func openColorPicker(_ sender: NSButton) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = annotationView.currentColor
        panel.isContinuous = true
        
        // Dynamically set level to be one higher than the screenshot overlay
        if let windowLevel = self.window?.level {
            panel.level = NSWindow.Level(windowLevel.rawValue + 1)
        } else {
            panel.level = .screenSaver
        }
        
        // Position panel near the button
        if let window = self.window {
            let rectInWindow = sender.convert(sender.bounds, to: nil)
            let rectInScreen = window.convertToScreen(rectInWindow)
            // Position the panel above or below the toolbar
            let panelOrigin = NSPoint(x: rectInScreen.origin.x, 
                                     y: rectInScreen.origin.y + 40)
            panel.setFrameOrigin(panelOrigin)
        }
        
        panel.orderFrontRegardless()
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        annotationView.currentColor = sender.color
        colorButton?.layer?.backgroundColor = sender.color.cgColor
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        annotationView.currentColor = sender.color
        colorButton?.layer?.backgroundColor = sender.color.cgColor
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
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 16).isActive = true
        container.heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true

        let line = NSView(frame: .zero)
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        container.addSubview(line)
        
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 24)
        ])

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
        for btn in stackView.arrangedSubviews.compactMap({ $0 as? NSButton }) {
            guard btn.tag < 100 else { continue }
            btn.layer?.backgroundColor = btn.tag == sender.tag ? NSColor(white: 1, alpha: 0.2).cgColor : .clear
        }
    }

    @objc private func selectWidth(_ sender: NSButton) {
        annotationView.currentLineWidth = CGFloat(sender.tag - 200)
        for container in stackView.arrangedSubviews {
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
}
