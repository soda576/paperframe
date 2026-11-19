import AppKit
import QuartzCore

enum MechanismStyle: String, CaseIterable {
    case signal, angled

    var title: String { self == .signal ? "三色灯款" : "折角款" }
}

final class TaskInput: NSTextView {
    var onCaret: (() -> Void)?
    var onStrike: (() -> Void)?
    var onBlur: (() -> Void)?

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let previous = self.string
        super.insertText(string, replacementRange: replacementRange)
        if self.string != previous, !hasMarkedText() { onStrike?() }
        onCaret?()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onCaret?() } }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onBlur?() }
        return accepted
    }
}

private final class PaperCheckCell: NSButtonCell {
    var ink = NSColor.black

    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        let box = CGRect(x: frame.midX - 5.75, y: frame.midY - 5.75, width: 11.5, height: 11.5)
        let outline = NSBezierPath(rect: box)
        if isHighlighted {
            ink.withAlphaComponent(0.13).setFill()
            outline.fill()
        }
        ink.withAlphaComponent(isEnabled ? 0.84 : 0.55).setStroke()
        outline.lineWidth = 0.9
        outline.stroke()
        if state == .on {
            let orientation: CGFloat = controlView.isFlipped ? -1 : 1
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: box.minX + 2.1, y: box.midY))
            tick.line(to: CGPoint(x: box.midX - 0.8, y: box.midY - orientation * 2.2))
            tick.line(to: CGPoint(x: box.maxX - 1.8, y: box.midY + orientation * 2.5))
            tick.lineCapStyle = .round
            tick.lineWidth = 1.01
            tick.stroke()
        }
    }
}

final class PaperTask: NSView {
    let id: UUID
    let input: TaskInput
    let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let addChild = NSButton()
    let toggleChildren = NSButton()
    private static let openChevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
    private static let closedChevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
    private let reorderGrip = TaskReorderGrip()
    var ink = NSColor.black
    var crossing: CGFloat = 0 { didSet { strikeView.needsDisplay = true } }
    private let strikeView = TaskStrike()
    private let paperStyle: PaperStyle
    private var size: CGFloat = 19
    private var lineSpacing: CGFloat = 0
    private var tinted = false

    override var isFlipped: Bool { true }

    init(row: PlanRow, style: PaperStyle) {
        id = row.id
        paperStyle = style
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        input = TaskInput(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        input.drawsBackground = false
        input.isRichText = false
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticTextReplacementEnabled = false
        input.isContinuousSpellCheckingEnabled = false
        input.allowsUndo = true
        input.textContainerInset = NSSize(width: 0, height: 1)
        input.string = row.text
        crossing = row.done ? 1 : 0
        let cell = PaperCheckCell(textCell: "")
        cell.setButtonType(.switch)
        cell.controlSize = .small
        check.cell = cell
        addSubview(check)
        addSubview(reorderGrip)
        addSubview(input)
        for button in [toggleChildren, addChild] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
            button.refusesFirstResponder = true
            addSubview(button)
        }
        addChild.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addChild.toolTip = "添加子任务"
        toggleChildren.isHidden = true
        strikeView.task = self
        addSubview(strikeView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(index: Int, done: Bool, child: Bool, ink: NSColor, size: CGFloat,
                   lineSpacing: CGFloat, tinted: Bool) {
        self.ink = ink
        self.size = size
        self.lineSpacing = lineSpacing
        self.tinted = tinted
        check.state = done ? .on : .off
        (check.cell as? PaperCheckCell)?.ink = ink
        check.needsDisplay = true
        reorderGrip.ink = ink
        reorderGrip.setAccessibilityLabel("拖动第 \(index + 1) 项排序")
        check.setAccessibilityLabel("完成第 \(index + 1) 项\(child ? "子任务" : "")")
        addChild.isHidden = child
        addChild.contentTintColor = ink.withAlphaComponent(0.60)
        toggleChildren.contentTintColor = ink.withAlphaComponent(0.72)
        addChild.setAccessibilityLabel("为第 \(index + 1) 项添加子任务")
        input.setAccessibilityLabel(child ? "子任务文字" : "任务文字")
        input.insertionPointColor = ink
        restyle()
    }

    func updateDisclosure(index: Int, hasChildren: Bool, collapsed: Bool) {
        toggleChildren.isHidden = !hasChildren
        guard hasChildren else { return }
        toggleChildren.image = collapsed ? Self.closedChevron : Self.openChevron
        toggleChildren.toolTip = collapsed ? "展开子任务" : "收起子任务"
        toggleChildren.setAccessibilityLabel("\(collapsed ? "展开" : "收起")第 \(index + 1) 项的子任务")
    }

    func restyle() {
        guard !input.hasMarkedText(), let storage = input.textStorage else { return }
        addChild.isEnabled = !input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        check.isEnabled = !addChild.isHidden || addChild.isEnabled
        reorderGrip.isHidden = !addChild.isEnabled
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = size + 6
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byCharWrapping
        let traits: [NSAttributedString.Key: Any] = [
            .font: paperStyle.font(latin: false, size: size), .foregroundColor: ink, .paragraphStyle: paragraph,
        ]
        if storage.length > 0 {
            let styled = NSMutableAttributedString(attributedString: paperStyle.text(
                input.string, size: size, ink: ink, pressed: true, tinted: tinted))
            styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))
            storage.beginEditing()
            styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attributes, range, _ in
                storage.setAttributes(attributes, range: range)
            }
            storage.endEditing()
        }
        input.typingAttributes = traits
        strikeView.needsDisplay = true
    }

    func align(width: CGFloat, y: CGFloat, indent: CGFloat, spaceBelow: CGFloat) -> CGFloat {
        let textX: CGFloat = 49
        let controls: CGFloat = addChild.isHidden ? 3 : (toggleChildren.isHidden ? 25 : 45)
        let textWidth = max(25, width - textX - controls)
        guard let manager = input.layoutManager, let container = input.textContainer else { return 39 }
        if container.containerSize.width != textWidth {
            container.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: container)
        let contentHeight = max(size + 6, ceil(manager.usedRect(for: container).maxY) + 2)
        frame = CGRect(x: 6 + indent, y: y, width: width, height: contentHeight + spaceBelow)
        check.frame = CGRect(x: 21, y: max(1, (size - 17) / 2), width: 23, height: 23)
        reorderGrip.frame = CGRect(x: 2, y: check.frame.minY, width: 18, height: 23)
        addChild.frame = CGRect(x: width - 22, y: check.frame.minY, width: 22, height: 23)
        toggleChildren.frame = CGRect(x: width - 42, y: check.frame.minY, width: 20, height: 23)
        input.frame = CGRect(x: textX, y: 0, width: textWidth, height: contentHeight)
        strikeView.frame = input.frame
        return frame.height
    }

    func caret(in document: NSView) -> CGPoint {
        let location = min(input.selectedRange().location, input.string.utf16.count)
        let geometry = input.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        if let window, geometry.height > 0, geometry.origin.x.isFinite {
            let point = window.convertPoint(fromScreen: CGPoint(x: geometry.minX, y: geometry.minY))
            return document.convert(point, from: nil)
        }
        return document.convert(CGPoint(x: input.frame.minX, y: 24), from: self)
    }

    fileprivate func drawStrike() {
        guard crossing > 0, let manager = input.layoutManager, let container = input.textContainer else { return }
        let glyphs = manager.glyphRange(for: container)
        var lines: [NSRect] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in lines.append(used) }
        var remaining = lines.reduce(CGFloat(0)) { $0 + $1.width } * crossing
        ink.withAlphaComponent(0.72).setStroke()
        for line in lines where remaining > 0 {
            let width = min(remaining, line.width)
            let inkLine = NSBezierPath()
            inkLine.move(to: CGPoint(x: line.minX, y: line.midY + 1))
            for step in 1...12 {
                inkLine.line(to: CGPoint(x: line.minX + width * CGFloat(step) / 12,
                                         y: line.midY + 1 + sin(CGFloat(step) * 0.8) * 0.48))
            }
            inkLine.lineCapStyle = .round
            inkLine.lineWidth = 1.25
            inkLine.stroke()
            remaining -= width
        }
    }
}

private final class TaskReorderGrip: NSView {
    var ink = NSColor.labelColor { didSet { needsDisplay = true } }
    private var start: CGPoint?
    private var escapeMonitor: Any?
    private var task: PaperTask? { superview as? PaperTask }
    private var document: PaperDocument? { task?.superview as? PaperDocument }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func isAccessibilityElement() -> Bool { !isHidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .handle }
    override func accessibilityHelp() -> String? { "上下拖动调整顺序" }

    override func draw(_ dirtyRect: NSRect) {
        let color = escapeMonitor == nil ? ink.withAlphaComponent(0.46) : PaperSwatch.rgb(0x5799d0)
        color.setFill()
        for x in [-2.0, 2.0] {
            for y in [-4.0, 0.0, 4.0] {
                NSBezierPath(ovalIn: CGRect(x: bounds.midX + x - 0.9, y: bounds.midY + y - 0.9,
                                            width: 1.8, height: 1.8)).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, escapeMonitor != nil || abs(event.locationInWindow.y - start.y) >= 3,
              let task, let document, (window?.firstResponder as? TaskInput)?.hasMarkedText() != true else { return }
        if escapeMonitor == nil {
            guard document.beginTaskDrag(task.id, at: start) else { return }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self else { return event }
                self.finishDrag(at: nil)
                return nil
            }
            NSCursor.closedHand.set()
            needsDisplay = true
        }
        document.updateTaskDrag(at: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) { finishDrag(at: event.locationInWindow) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishDrag(at: nil, animated: false) }
        super.viewWillMove(toWindow: newWindow)
    }

    private func finishDrag(at location: CGPoint?, animated: Bool = true) {
        start = nil
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
        document?.finishTaskDrag(at: location, animated: animated)
        NSCursor.arrow.set()
        needsDisplay = true
    }
}

private final class TaskDragPreview: NSView {
    private var rows: [(image: NSImage, frame: CGRect)] = []
    private let hiddenCount: Int
    private let night: Bool

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(source: ArraySlice<PaperTask>, night: Bool) {
        self.night = night
        let visible = source.filter { !$0.isHidden }
        hiddenCount = max(0, visible.count - 3)
        let first = source[source.startIndex].frame
        var y: CGFloat = 4
        for task in visible.prefix(3) {
            let area = CGRect(x: 0, y: 0, width: task.bounds.width, height: min(52, task.input.frame.height))
            if let bitmap = task.bitmapImageRepForCachingDisplay(in: area) {
                task.cacheDisplay(in: area, to: bitmap)
                let image = NSImage(size: area.size)
                image.addRepresentation(bitmap)
                let position = CGPoint(x: task.frame.minX - first.minX, y: y)
                rows.append((image, CGRect(origin: position, size: area.size)))
            }
            y += area.height + 1
        }
        super.init(frame: CGRect(x: 0, y: 0, width: first.width + 2, height: y + 3 + (hiddenCount > 0 ? 17 : 0)))
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = PaperSwatch.rgb(night ? 0x353d46 : 0xeaf2f8).cgColor
        layer?.borderColor = PaperSwatch.rgb(night ? 0x80b8e6 : 0x558fbd).cgColor
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.33
        layer?.shadowRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        for row in rows {
            row.image.draw(in: row.frame, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
        }
        if hiddenCount > 0 {
            ("另 \(hiddenCount) 条子任务" as NSString).draw(at: CGPoint(x: 29, y: bounds.maxY - 17), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: PaperSwatch.rgb(night ? 0xc1d8ec : 0x395e7b),
            ])
        }
    }
}

private final class TaskStrike: NSView {
    weak var task: PaperTask?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { task?.drawStrike() }
}

final class PaperDocument: NSView {
    struct ReorderLayout {
        let tasks: [PaperTask]
        let block: Range<Int>
        let slots: [Int]
    }

    private struct TaskDrag {
        let id: UUID
        let layout: ReorderLayout
        let frames: [CGRect]
        let preview: TaskDragPreview
        let gripOffset: CGFloat
        var location: CGPoint
        var slot: Int
        var settling = false

        var blockFrame: CGRect {
            frames[layout.block.lowerBound].union(frames[layout.block.upperBound - 1])
        }

        func slotY(_ slot: Int) -> CGFloat {
            slot == frames.count ? frames[slot - 1].maxY : frames[slot].minY
        }

        var gapY: CGFloat { slotY(slot) - (slot > layout.block.upperBound ? blockFrame.height : 0) }
    }

    static let strikeDuration = 0.095
    private static let signalWidth: CGFloat = 80
    private static let signalHeight: CGFloat = 26
    private static let signalTop: CGFloat = 14.4

    static func strikeTravel(at elapsed: Double) -> CGFloat {
        guard elapsed < strikeDuration else { return 0 }
        return sin(.pi * max(0, elapsed) / strikeDuration)
    }

    var point: CGPoint? { didSet { if oldValue != point { lampMoved?() } } }
    var night = false
    var lampLevel: CGFloat = 0
    var thrust: CGFloat = 0
    var mechanismStyle = MechanismStyle.signal
    var lampMoved: (() -> Void)?
    var reorderLayout: ((UUID) -> ReorderLayout?)?
    var moveTask: ((UUID, Int) -> Void)?
    var reorderAppearanceChanged: (() -> Void)?
    var usesGlass = false
    var isReordering: Bool { taskDrag != nil }
    var isDraggingTask: Bool { taskDrag?.settling == false }
    private var dropMarker: CGRect? { didSet { if dropMarker != oldValue { needsDisplay = true } } }
    private var taskDrag: TaskDrag?
    private var dragScrollTimer: Timer?

    override var isFlipped: Bool { true }
    var carriageClearance: CGFloat { mechanismStyle == .signal ? 42 : 29 }

    override func draw(_ dirtyRect: NSRect) {
        guard let dropMarker else { return }
        let outline = NSBezierPath(roundedRect: dropMarker.insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4)
        let blue = PaperSwatch.rgb(night || usesGlass ? 0x82b9e7 : 0x3679ad)
        blue.withAlphaComponent(0.13).setFill()
        outline.fill()
        blue.withAlphaComponent(0.74).setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }

    func beginTaskDrag(_ id: UUID, at location: CGPoint) -> Bool {
        guard taskDrag == nil, let layout = reorderLayout?(id),
              layout.slots.contains(where: { $0 < layout.block.lowerBound || $0 > layout.block.upperBound }) else {
            return false
        }
        let first = layout.tasks[layout.block.lowerBound].frame
        let preview = TaskDragPreview(source: layout.tasks[layout.block], night: night || usesGlass)
        preview.setFrameOrigin(CGPoint(x: first.minX + 4, y: first.minY - 2))
        taskDrag = TaskDrag(id: id, layout: layout, frames: layout.tasks.map(\.frame), preview: preview,
                            gripOffset: convert(location, from: nil).y - first.minY, location: location,
                            slot: layout.block.lowerBound)
        for task in layout.tasks[layout.block] { task.alphaValue = 0 }
        addSubview(preview, positioned: .above, relativeTo: nil)
        reorderAppearanceChanged?()
        refreshTaskDrag()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.scrollWhileDragging()
        }
        dragScrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    func updateTaskDrag(at location: CGPoint) {
        guard taskDrag?.settling == false else { return }
        taskDrag?.location = location
        refreshTaskDrag()
    }

    func finishTaskDrag(at location: CGPoint?, animated: Bool = true) {
        guard let drag = taskDrag, !drag.settling else { return }
        dragScrollTimer?.invalidate()
        dragScrollTimer = nil
        let slot = location.map { insertionSlot(for: drag, at: $0) } ?? drag.layout.block.lowerBound
        placeGap(at: slot, animated: animated)
        taskDrag?.settling = true
        let gapY = taskDrag?.gapY ?? drag.blockFrame.minY
        if slot != drag.layout.block.lowerBound { moveTask?(drag.id, slot) }
        let finish: () -> Void = { [weak self, weak preview = drag.preview] in
            guard let self, let preview, self.taskDrag?.preview === preview else { return }
            self.clearTaskDrag()
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { finish(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.17
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            drag.preview.animator().setFrameOrigin(CGPoint(x: drag.blockFrame.minX, y: gapY))
            drag.preview.animator().alphaValue = 0.55
        } completionHandler: { finish() }
    }

    func clearTaskDrag() {
        guard let drag = taskDrag else { return }
        taskDrag = nil
        dragScrollTimer?.invalidate()
        dragScrollTimer = nil
        dropMarker = nil
        drag.preview.removeFromSuperview()
        for (task, frame) in zip(drag.layout.tasks, drag.frames) {
            if !drag.settling { task.setFrameOrigin(frame.origin) }
            task.alphaValue = 1
        }
        reorderAppearanceChanged?()
    }

    private func insertionSlot(for drag: TaskDrag, at windowLocation: CGPoint) -> Int {
        let location = convert(windowLocation, from: nil)
        let block = drag.layout.block
        guard visibleRect.contains(location), let slot = drag.layout.slots.min(by: {
            abs(drag.slotY($0) - location.y) < abs(drag.slotY($1) - location.y)
        }), slot < block.lowerBound || slot > block.upperBound else { return block.lowerBound }
        return slot
    }

    private func refreshTaskDrag() {
        guard let drag = taskDrag else { return }
        placeGap(at: insertionSlot(for: drag, at: drag.location), animated: true)
        let pointer = convert(drag.location, from: nil)
        drag.preview.setFrameOrigin(CGPoint(x: drag.blockFrame.minX + 4, y: pointer.y - drag.gripOffset - 2))
    }

    private func placeGap(at slot: Int, animated: Bool) {
        guard var drag = taskDrag else { return }
        let changed = slot != drag.slot
        drag.slot = slot
        taskDrag = drag
        dropMarker = CGRect(x: drag.blockFrame.minX + 2, y: drag.gapY,
                            width: drag.blockFrame.width - 2, height: drag.blockFrame.height)
        guard changed else { return }
        let block = drag.layout.block
        let height = drag.blockFrame.height
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.16 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (index, task) in drag.layout.tasks.enumerated() where !block.contains(index) {
                let origin = drag.frames[index].origin
                let shift = index >= slot && index < block.lowerBound ? height
                    : index >= block.upperBound && index < slot ? -height : 0
                let target = CGPoint(x: origin.x, y: origin.y + shift)
                if task.frame.origin != target { task.animator().setFrameOrigin(target) }
            }
        }
    }

    private func scrollWhileDragging() {
        guard let drag = taskDrag, let scroller = enclosingScrollView else { return }
        let location = convert(drag.location, from: nil)
        let clip = scroller.contentView
        let viewport = clip.bounds
        guard visibleRect.contains(location) else { return }
        let delta = location.y < viewport.minY + 20 ? -8.0 : location.y > viewport.maxY - 20 ? 8.0 : 0
        guard delta != 0 else { return }
        let next = clip.constrainBoundsRect(viewport.offsetBy(dx: 0, dy: delta)).origin
        guard next != viewport.origin else { return }
        clip.scroll(to: next)
        scroller.reflectScrolledClipView(clip)
        refreshTaskDrag()
    }

    var lightSource: CGPoint? {
        guard !isReordering, night && lampLevel > 0, let point else { return nil }
        let x = mechanismStyle == .signal ? strikerCenter(point.x) : carriageCenter(point.x) + 9.5
        let offset = mechanismStyle == .signal ? Self.signalTop : 13.2
        return CGPoint(x: x, y: point.y + offset)
    }

    private func carriageCenter(_ x: CGFloat) -> CGFloat {
        let half: CGFloat = mechanismStyle == .signal ? Self.signalWidth / 2 : 26
        return min(max(x, half), bounds.width - half)
    }

    private func strikerCenter(_ x: CGFloat) -> CGFloat {
        min(max(x, 6), bounds.width - 6)
    }

    var carriageBounds: CGRect? {
        guard mechanismStyle == .signal, let point else { return nil }
        return CGRect(x: carriageCenter(point.x) - Self.signalWidth / 2, y: point.y + Self.signalTop,
                      width: Self.signalWidth, height: Self.signalHeight)
    }

    func railPosition(at x: CGFloat) -> CGFloat {
        carriageCenter(x)
    }

    func drawMechanism() {
        guard let point else { return }
        let railY = point.y + 18
        let left: CGFloat = 20
        let span = max(0, bounds.width - 40)
        let center = carriageCenter(point.x)
        if let body = carriageBounds {
            drawRoundRail(x: left, centerY: body.midY, width: span)
            drawSignalCarriage(in: body)
        } else {
            drawFlatRail(x: left, y: railY, width: span)
            drawAngledCarriage(center: center, railY: railY)
        }
        let x = mechanismStyle == .signal ? strikerCenter(point.x) : center
        let metal = gray(night ? 0.58 : 0.17)
        let headY = point.y + 3.2 - thrust * (mechanismStyle == .signal ? 3.1 : 2.6)
        if mechanismStyle == .signal {
            let striker = gray(night ? 0.22 : 0.15)
            let top = point.y + Self.signalTop
            fill(CGRect(x: x - 1.2, y: headY + 1, width: 2.4, height: top - headY - 1), striker, radius: 0.5)
            fill(CGRect(x: x - 0.8, y: headY + 2.5, width: 0.55, height: top - headY - 3.5),
                 gray(night ? 0.53 : 0.54))
            fill(CGRect(x: x - 6, y: headY, width: 12, height: 2.4), gray(night ? 0.13 : 0.14), radius: 0.5)
            fill(CGRect(x: x - 5.3, y: headY, width: 10.6, height: 0.55), gray(0.56), radius: 0.2)
            let aperture = CGRect(x: x - 5, y: top - 0.6, width: 10, height: 1.25)
            fill(aperture, striker, radius: 0.45)
            if night && lampLevel > 0 {
                fill(aperture, NSColor(srgbRed: 0.96, green: 0.84, blue: 0.61, alpha: lampLevel), radius: 0.45)
            }
        } else {
            fill(CGRect(x: x - 0.65, y: headY, width: 1.3, height: railY - headY - 3.5), metal)
            fill(CGRect(x: x - 5.2, y: headY, width: 10.4, height: 1.9), metal, radius: 0.45)
            if night && lampLevel > 0 {
                fill(CGRect(x: x + 4.5, y: railY - 4.8, width: 10, height: 1),
                     gray(0.96, alpha: lampLevel), radius: 0.45)
            }
        }
    }

    private func drawRoundRail(x: CGFloat, centerY: CGFloat, width: CGFloat) {
        guard width >= 36 else { return }
        let diameter = min(16, max(11, width * 0.047))
        let shaft = CGRect(x: x, y: centerY - diameter / 2, width: width, height: diameter)
        let profile = NSBezierPath(roundedRect: shaft, xRadius: diameter / 2, yRadius: diameter / 2)
        shadow(under: profile, blur: 3.2, opacity: night ? 0.75 : 0.27)
        shade(profile, with: NSGradient(colorsAndLocations:
            (PaperSwatch.rgb(night ? 0x14191d : 0x1f262b), 0),
            (PaperSwatch.rgb(night ? 0x343d45 : 0x4a555e), 0.24),
            (PaperSwatch.rgb(night ? 0x2a3239 : 0x39434b), 0.43),
            (PaperSwatch.rgb(night ? 0x14191e : 0x1a2228), 0.66),
            (PaperSwatch.rgb(0x080c0f), 0.86),
            (PaperSwatch.rgb(night ? 0x161b20 : 0x1e272c), 1)))

        let collarHeight = diameter + 5
        let collarWidth: CGFloat = 14
        for (index, end) in [x, x + width - collarWidth].enumerated() {
            let collar = CGRect(x: end, y: centerY - collarHeight / 2, width: collarWidth, height: collarHeight)
            let collarFace = NSBezierPath(roundedRect: collar, xRadius: 2.6, yRadius: 2.6)
            shadow(under: collarFace, blur: 2.2, opacity: night ? 0.65 : 0.23)
            shade(collarFace, with: NSGradient(colorsAndLocations:
                (PaperSwatch.rgb(0x151a1e), 0),
                (PaperSwatch.rgb(night ? 0x323a41 : 0x454f56), 0.27),
                (PaperSwatch.rgb(0x13171b), 0.70),
                (PaperSwatch.rgb(0x080b0e), 1)))
            let seamX = index == 0 ? collar.maxX - 3 : collar.minX + 2
            fill(CGRect(x: seamX, y: collar.minY + 1, width: 0.9, height: collar.height - 2),
                 gray(0, alpha: 0.45), radius: 0.4)
            fill(CGRect(x: seamX + 0.9, y: collar.minY + 2, width: 0.6, height: collar.height * 0.48),
                 gray(0.49, alpha: 0.33), radius: 0.3)
        }
    }

    private func drawFlatRail(x: CGFloat, y: CGFloat, width: CGFloat) {
        fill(CGRect(x: x, y: y, width: width, height: 5), gray(night ? 0.32 : 0.28), radius: 1.4)
        fill(CGRect(x: x, y: y + 0.8, width: width, height: 0.8), gray(night ? 0.68 : 0.75))
        fill(CGRect(x: x, y: y + 3.4, width: width, height: 0.75), gray(night ? 0.17 : 0.1))
        for end in [x, x + width - 11] {
            fill(CGRect(x: end, y: y - 1.3, width: 11, height: 7.5), gray(night ? 0.36 : 0.45), radius: 1)
            for tick in 1...3 {
                fill(CGRect(x: end + 2.5 * CGFloat(tick), y: y + 0.4, width: 0.65, height: 4), gray(0.19))
            }
        }
    }

    private func drawSignalCarriage(in body: CGRect) {
        let x = body.minX, y = body.minY, right = body.maxX, bottom = body.maxY
        let shell = NSBezierPath()
        shell.move(to: CGPoint(x: x + 11, y: y))
        shell.line(to: CGPoint(x: right - 13, y: y))
        shell.curve(to: CGPoint(x: right - 4, y: y + 4), controlPoint1: CGPoint(x: right - 9, y: y),
                    controlPoint2: CGPoint(x: right - 6, y: y + 1.5))
        shell.curve(to: CGPoint(x: right - 3, y: bottom - 5), controlPoint1: CGPoint(x: right + 1, y: y + 9),
                    controlPoint2: CGPoint(x: right + 1, y: bottom - 9))
        shell.curve(to: CGPoint(x: right - 13, y: bottom), controlPoint1: CGPoint(x: right - 6, y: bottom - 1),
                    controlPoint2: CGPoint(x: right - 9, y: bottom))
        shell.line(to: CGPoint(x: x + 11, y: bottom))
        shell.curve(to: CGPoint(x: x, y: body.midY), controlPoint1: CGPoint(x: x + 4.5, y: bottom),
                    controlPoint2: CGPoint(x: x, y: bottom - 4))
        shell.curve(to: CGPoint(x: x + 11, y: y), controlPoint1: CGPoint(x: x, y: y + 5),
                    controlPoint2: CGPoint(x: x + 4.5, y: y))
        shell.close()
        shadow(under: shell, blur: 4, opacity: night ? 0.83 : 0.25)
        shade(shell, with: NSGradient(colorsAndLocations:
            (litShell(0xd4d0c8), 0),
            (litShell(0xf7f3ea), 0.16),
            (litShell(0xece8df), 0.44),
            (litShell(0xded9d0), 0.79),
            (litShell(0xb4ada3), 1)))

        NSGraphicsContext.saveGraphicsState()
        shell.addClip()
        for index in 0..<32 {
            let brightness = sin(CGFloat(index) * 2.17)
            fill(CGRect(x: x + 3, y: y + 3 + CGFloat(index) * 0.60, width: body.width - 6, height: 0.35),
                 gray(brightness > 0 ? 1 : 0, alpha: abs(brightness) * (night ? 0.015 : 0.038)))
        }
        let facet = NSBezierPath()
        facet.move(to: CGPoint(x: right - 9, y: y))
        facet.line(to: CGPoint(x: right, y: y))
        facet.line(to: CGPoint(x: right, y: bottom))
        facet.line(to: CGPoint(x: right - 16, y: bottom))
        facet.close()
        gray(0, alpha: night ? 0.10 : 0.08).setFill()
        facet.fill()
        NSGraphicsContext.restoreGraphicsState()

        let colors = [0xe8695e, 0xf1b84c, 0x67be7a]
        for (index, color) in colors.enumerated() {
            let dotX = x + 10 + CGFloat(index) * 8
            let dotY = body.midY - 2.3
            fill(CGRect(x: dotX, y: dotY, width: 4.8, height: 4.8), gray(night ? 0.12 : 0.45), radius: 2.4)
            fill(CGRect(x: dotX + 0.75, y: dotY + 0.65, width: 3.3, height: 3.3),
                 PaperSwatch.rgb(color).withAlphaComponent(0.88 + thrust * 0.12), radius: 1.5)
            fill(CGRect(x: dotX + 1.15, y: dotY + 1, width: 0.85, height: 0.85), gray(1, alpha: 0.49), radius: 0.4)
        }
    }

    private func litShell(_ pigment: Int) -> NSColor {
        let white = PaperSwatch.rgb(pigment)
        // Both appearances use the same paint, with lower ambient light at night.
        let illumination: CGFloat = night ? 0.235 : 1
        return NSColor(srgbRed: white.redComponent * illumination,
                       green: white.greenComponent * illumination,
                       blue: white.blueComponent * illumination, alpha: 1)
    }

    private func shade(_ profile: NSBezierPath, with gradient: NSGradient?) {
        let bounds = profile.bounds
        NSGraphicsContext.saveGraphicsState()
        profile.addClip()
        gradient?.draw(from: CGPoint(x: bounds.midX, y: bounds.minY),
                       to: CGPoint(x: bounds.midX, y: bounds.maxY), options: [])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func shadow(under profile: NSBezierPath, blur: CGFloat, opacity: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = gray(0, alpha: opacity)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = CGSize(width: 0, height: -2.5)
        shadow.set()
        gray(0.06).setFill()
        profile.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawAngledCarriage(center: CGFloat, railY: CGFloat) {
        let profile = NSBezierPath()
        profile.move(to: CGPoint(x: center - 26, y: railY - 4.8))
        profile.line(to: CGPoint(x: center + 18, y: railY - 4.8))
        profile.line(to: CGPoint(x: center + 26, y: railY + 2.8))
        profile.line(to: CGPoint(x: center + 26, y: railY + 10.6))
        profile.line(to: CGPoint(x: center - 26, y: railY + 10.6))
        profile.close()
        NSGradient(starting: litShell(0xf7f3ea), ending: litShell(0xded9d0))?.draw(in: profile, angle: 90)
        litShell(0xb4ada3).setStroke()
        profile.lineWidth = 0.65
        profile.stroke()
        let detail = NSBezierPath()
        for offset: CGFloat in [-19, -14] {
            detail.move(to: CGPoint(x: center + offset, y: railY + 6.6))
            detail.line(to: CGPoint(x: center + offset + 4, y: railY - 0.9))
        }
        gray(night ? 0.48 : 0.59).setStroke()
        detail.lineCapStyle = .round
        detail.lineWidth = 0.8
        detail.stroke()
    }

    private func fill(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

}

final class PaperMechanism: NSView {
    weak var document: PaperDocument?
    var onHold: (() -> Void)?
    var onDrag: ((CGFloat?) -> Void)?
    private var grab: (mouse: CGFloat, carriage: CGFloat)?
    private var dragStarted = false
    private var pendingHold: DispatchWorkItem?
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onHold != nil, let carriage = document?.carriageBounds else { return nil }
        return carriage.insetBy(dx: -3, dy: -2).contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let carriage = document?.point else { return }
        let mouse = convert(event.locationInWindow, from: nil)
        grab = (mouse.x, carriage.x)
        dragStarted = false
        pendingHold?.cancel()
        let hold = DispatchWorkItem { [weak self] in self?.onHold?() }
        pendingHold = hold
        DispatchQueue.main.asyncAfter(deadline: .now() + MechanismMotion.holdTime, execute: hold)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab else { return }
        let delta = convert(event.locationInWindow, from: nil).x - grab.mouse
        guard dragStarted || abs(delta) >= 3 else { return }
        pendingHold?.cancel()
        dragStarted = true
        onDrag?(grab.carriage + delta)
    }

    override func mouseUp(with event: NSEvent) {
        pendingHold?.cancel()
        grab = nil
        if dragStarted { onDrag?(nil) }
        dragStarted = false
    }

    override func draw(_ dirtyRect: NSRect) { document?.drawMechanism() }
}
