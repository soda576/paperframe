import AppKit

final class DateWheel: NSView {
    enum Unit { case day, year }

    var onSelect: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var ink = NSColor.labelColor {
        didSet {
            todayButton.attributedTitle = style.text(todayTitle, size: 12, ink: ink.withAlphaComponent(0.7))
            needsDisplay = true
        }
    }

    private let style: PaperStyle
    private let calendar: Calendar
    private let unit: Unit
    private var todayTitle: String { unit == .year ? "回到今年" : "回到今天" }
    private let todayButton = NSButton(frame: .zero)
    private let step: CGFloat = 28
    private var origin = Date()
    private var position: CGFloat = 0 { didSet { needsDisplay = true } }
    private var dragStart: (y: CGFloat, position: CGFloat)?
    private var dragged = false
    private var settleWork: DispatchWorkItem?
    private var snapTimer: Timer?
    private var index: Int { Int(position.rounded()) }
    private var track: CGRect {
        let width = min(215, bounds.width)
        let height = min(136, max(step, bounds.height - 33))
        return CGRect(x: bounds.midX - width / 2, y: bounds.maxY - height - 4, width: width, height: height)
    }

    override var acceptsFirstResponder: Bool { true }

    init(style: PaperStyle, calendar: Calendar, unit: Unit = .day) {
        self.style = style
        self.calendar = calendar
        self.unit = unit
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        let selection = unit == .year ? "年份" : "日期"
        setAccessibilityLabel(unit == .year ? "年份滚轮" : "便签日期滚轮")
        setAccessibilityHelp("用上下方向键选择\(selection)，回车确认，Escape 取消。")
        todayButton.title = todayTitle
        todayButton.isBordered = false
        todayButton.target = self
        todayButton.action = #selector(selectToday)
        addSubview(todayButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func reset(to date: Date) {
        stop()
        origin = date
        position = 0
        updateAccessibility()
    }

    func stop() {
        settleWork?.cancel()
        snapTimer?.invalidate()
        dragStart = nil
    }

    override func layout() {
        super.layout()
        todayButton.frame = CGRect(x: bounds.midX - 42, y: track.minY - 27, width: 84, height: 24)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let area = track
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: area)

        ink.withAlphaComponent(0.055).setFill()
        CGRect(x: area.minX, y: area.midY - step / 2, width: area.width, height: step).fill()
        ink.withAlphaComponent(0.28).setFill()
        for edge in [-step / 2, step / 2] {
            CGRect(x: area.minX, y: area.midY + edge, width: area.width, height: 1).fill()
        }
        PaperSwatch.rgb(0x306da7).setFill()
        CGRect(x: area.minX, y: area.midY - 4, width: 2, height: 8).fill()

        for offset in (index - 3)...(index + 3) {
            guard let date = date(at: offset) else { continue }
            let distance = CGFloat(offset) - position
            let y = area.midY - distance * step
            let alpha = max(0, 1 - abs(distance) * 0.36)
            let text = style.text(title(for: date),
                                  size: 15, ink: ink.withAlphaComponent(alpha))
            let size = text.size()
            text.draw(at: CGPoint(x: area.midX - size.width / 2, y: y - size.height / 2))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        stop()
        if event.hasPreciseScrollingDeltas {
            position = bounded(position - delta / step)
            let work = DispatchWorkItem { [weak self] in self?.snap() }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            move(by: delta > 0 ? -1 : 1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard track.contains(point) else { return }
        window?.makeFirstResponder(self)
        stop()
        dragStart = (point.y, position)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let delta = convert(event.locationInWindow, from: nil).y - dragStart.y
        if abs(delta) > 3 { dragged = true }
        if dragged { position = bounded(dragStart.position + delta / step) }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        if dragged {
            snap()
        } else {
            let y = convert(event.locationInWindow, from: nil).y
            let row = Int((position + (track.midY - y) / step).rounded())
            if row == index { selectCurrent() }
            else { snap(to: row) }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { selectCurrent() }
        else { interpretKeyEvents([event]) }
    }

    override func moveUp(_ sender: Any?) { move(by: -1) }
    override func moveDown(_ sender: Any?) { move(by: 1) }
    override func pageUp(_ sender: Any?) { move(by: unit == .year ? -10 : -7) }
    override func pageDown(_ sender: Any?) { move(by: unit == .year ? 10 : 7) }
    override func insertNewline(_ sender: Any?) { selectCurrent() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func accessibilityPerformIncrement() -> Bool { moveDown(nil); return true }
    override func accessibilityPerformDecrement() -> Bool { moveUp(nil); return true }
    override func accessibilityPerformPress() -> Bool { selectCurrent(); return true }

    private func date(at offset: Int) -> Date? {
        guard bounded(CGFloat(offset)) == CGFloat(offset) else { return nil }
        return calendar.date(byAdding: unit == .year ? .year : .day, value: offset, to: origin)
    }

    private func key(for date: Date) -> String {
        unit == .year ? String(calendar.component(.year, from: date)) : PlansStore.day(for: date, calendar: calendar)
    }

    private func title(for date: Date) -> String {
        if unit == .year { return key(for: date) + " 年" }
        let dateLabel = key(for: date).replacingOccurrences(of: "-", with: " / ")
        let weekday = calendar.component(.weekday, from: date)
        let name = ["日", "一", "二", "三", "四", "五", "六"][weekday - 1]
        return "\(dateLabel)  周\(name)"
    }

    private func bounded(_ value: CGFloat) -> CGFloat {
        guard unit == .year else { return value }
        let year = calendar.component(.year, from: origin)
        return min(max(value, CGFloat(1 - year)), CGFloat(9999 - year))
    }

    @objc private func selectToday() { onSelect?(key(for: Date())) }

    private func selectCurrent() {
        if let date = date(at: index) { onSelect?(key(for: date)) }
    }

    private func updateAccessibility() {
        if let date = date(at: index) { setAccessibilityValue(key(for: date)) }
    }

    private func move(by count: Int) {
        stop()
        position = bounded(CGFloat(index + count))
        updateAccessibility()
    }

    private func snap(to offset: Int? = nil) {
        stop()
        let target = bounded(CGFloat(offset ?? index))
        let start = position
        if abs(target - start) < 0.01 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            position = target
            updateAccessibility()
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.15)
            self.position = start + (target - start) * (1 - pow(1 - progress, 3))
            if progress == 1 {
                timer.invalidate()
                self.updateAccessibility()
            }
        }
        snapTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
