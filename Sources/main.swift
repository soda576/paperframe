import AppKit
import QuartzCore
import SwiftUI

private enum Theme: String, CaseIterable {
    case system, day, night
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .day: "白天"
        case .night: "夜间"
        }
    }
}

private final class PaperWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class DateWheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PaperHeader: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

private final class ResizeGrip: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = NSEvent.mouseLocation
        let frame = window.frame
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type != .leftMouseUp {
            let pointer = NSEvent.mouseLocation
            let visible = window.screen?.visibleFrame ?? frame
            let width = min(max(frame.width + pointer.x - start.x, window.minSize.width),
                            max(window.minSize.width, visible.maxX - frame.minX))
            let height = min(max(frame.height + start.y - pointer.y, window.minSize.height),
                             max(window.minSize.height, frame.maxY - visible.minY))
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height), display: true)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.46).setStroke()
        let lines = NSBezierPath()
        for inset: CGFloat in [6, 10] {
            lines.move(to: CGPoint(x: 17 - inset, y: 4))
            lines.line(to: CGPoint(x: 17, y: 4 + inset))
        }
        lines.lineWidth = 0.75
        lines.stroke()
    }
}

private struct Tween {
    let start = CACurrentMediaTime()
    let duration: Double
    var easing: (CGFloat) -> CGFloat = { $0 * $0 * (3 - 2 * $0) }

    func progress(_ now: Double) -> CGFloat {
        let portion = CGFloat(min(max((now - start) / duration, 0), 1))
        return easing(portion)
    }
}

private final class PaperApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    private let preferences: UserDefaults
    private let store: PlansStore
    private let style = PaperStyle()
    private let window = PaperWindow(contentRect: NSRect(x: 0, y: 0, width: 375, height: 386),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
    private let surface = PaperSurface()
    private let glassBackdrop = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let document = PaperDocument()
    private let mechanism = PaperMechanism()
    private let header = PaperHeader()
    private let dateButton = NSButton(title: "", target: nil, action: nil)
    private lazy var dateWheel = DateWheel(style: style, calendar: archive.calendar)
    private lazy var yearWheel = DateWheel(style: style, calendar: archive.calendar, unit: .year)
    private var activeWheel: DateWheel?
    private weak var wheelAnchor: NSButton?
    private let datePanel = DateWheelPanel(contentRect: NSRect(x: 0, y: 0, width: 246, height: 184),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
    private let datePaper = PaperSurface()
    private let optionsButton = NSButton(title: "", target: nil, action: nil)
    private let grip = ResizeGrip()
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var archive = ArchiveState(store: store, defaults: preferences, style: style)
    private var archiveWindow: NSWindow?
    private weak var editorHost: PaperSurface?
    private weak var archiveBackdrop: PaperSurface?
    private var stickyDay: String?
    private var editingWindow: NSWindow { scroll.window ?? window }

    private var today = PlansStore.day()
    private var day = PlansStore.day()
    private var rows: [PlanRow] = []
    private var tasks: [PaperTask] = []
    private var collapsedParents: Set<UUID> = []
    private var active: UUID?
    private var lastVisibleTask: PaperTask? {
        rows.lastIndex { !isFolded($0) }.map { tasks[$0] }
    }
    private var isToday: Bool { day == today }
    private var editingOnGlass: Bool { editorHost == nil && archive.glassEnabled }
    private var paperInk: NSColor { PaperSwatch.ink[archive.inkIndex(for: day)].color(night: document.night) }
    private var ink: NSColor { editingOnGlass ? PaperSurface.glassInk : paperInk }
    private var theme: Theme { Theme(rawValue: preferences.string(forKey: "theme") ?? "") ?? .system }
    private var isNight: Bool {
        theme == .night || (theme == .system &&
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
    private var saveErrorShown = false
    private var strikeStart: Double?
    private var railMotion: (origin: CGPoint, tween: Tween)?
    private var draggingCarriage = false
    private var lampFade: (from: CGFloat, to: CGFloat, tween: Tween)?
    private var crossings: [UUID: (from: CGFloat, to: CGFloat, tween: Tween)] = [:]
    private var cursorDestination: CGPoint?
    private var animator: Timer?

    override init() {
        let environment = ProcessInfo.processInfo.environment
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = environment["PAPER_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("纸间打字机")
        preferences = environment["PAPER_PREFERENCES_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
        store = PlansStore(file: folder.appendingPathComponent("plans.json"))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.register(defaults: ["sound": true, "lamp": true, "pin": false])
        window.identifier = NSUserInterfaceItemIdentifier("PaperWindow")
        window.title = "Paperframe 便签"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 260, height: 231)
        window.delegate = self
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.wantsLayer = true
        content.layer?.cornerRadius = 19
        content.layer?.masksToBounds = true
        window.contentView = content
        glassBackdrop.frame = content.bounds
        glassBackdrop.autoresizingMask = [.width, .height]
        glassBackdrop.blendingMode = .behindWindow
        glassBackdrop.material = .hudWindow
        glassBackdrop.state = .active
        glassBackdrop.isHidden = true
        content.addSubview(glassBackdrop)
        surface.frame = content.bounds
        surface.autoresizingMask = [.width, .height]
        surface.softGrain = true
        surface.setAccessibilityIdentifier("paper-surface")
        content.addSubview(surface)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = PaperScroller()
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        scroll.verticalScrollElasticity = .none
        document.reorderLayout = { [weak self] id in self?.reorderLayout(for: id) }
        document.moveTask = { [weak self] id, slot in self?.moveTask(id, to: slot) }
        document.reorderAppearanceChanged = { [weak self] in
            guard let self else { return }
            self.mechanism.isHidden = self.document.isReordering
            self.updateLight()
        }
        document.lampMoved = { [weak self] in self?.updateLight() }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateLight),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        mechanism.document = document
        mechanism.onHold = { [weak self] in self?.toggleCarriageLamp() }
        mechanism.onDrag = { [weak self] x in self?.dragCarriage(to: x) }
        mechanism.autoresizingMask = [.width, .height]
        document.addSubview(mechanism)
        surface.addSubview(scroll)
        surface.addSubview(header)
        surface.addSubview(grip)
        setupDateWheel()
        setupHeaderButton(dateButton, label: "便签日期", action: #selector(toggleDateWheel))
        setupHeaderButton(optionsButton, label: "便签设置", action: #selector(showOptions(_:)))
        optionsButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        optionsButton.toolTip = "外观、声音与窗口设置"
        dateButton.toolTip = "用滚轮切换便签日期"
        grip.toolTip = "拖动调整便签大小"
        status.button?.image = NSImage(systemSymbolName: "text.page", accessibilityDescription: "Paperframe")
        status.menu = NSMenu()
        buildMainMenu()
        applyPin()
        restoreWindow()
        openDay(today)
        refreshAppearance(animateLamp: false)

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(systemAppearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(checkDay),
            name: .NSCalendarDayChanged, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(checkDay),
            name: NSWorkspace.didWakeNotification, object: nil)
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.checkDay() }
        showWindow()
        if let error = store.loadError { showSaveError(error) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        checkDay()
        refreshAppearance()
    }

    func applicationDidResignActive(_ notification: Notification) { closeDateWheel() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let archiveWindow, archiveWindow.isVisible || archiveWindow.isMiniaturized { showArchive() }
        else { showWindow() }
        return true
    }

    private func setupHeaderButton(_ button: NSButton, label: String, action: Selector) {
        button.isBordered = false
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        header.addSubview(button)
    }

    private func restoreWindow() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var frame = window.frame
        if let saved = preferences.string(forKey: "windowFrame") {
            let candidate = NSRectFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersection(candidate).width >= 200
                && $0.visibleFrame.intersection(candidate).height >= 180 }) {
                window.setFrame(candidate, display: false)
                return
            }
        }
        frame.origin = CGPoint(x: screen.maxX - frame.width - 24, y: screen.maxY - frame.height - 32)
        window.setFrame(frame, display: false)
    }

    @objc private func showWindow() {
        if let archiveWindow, archiveWindow.isVisible || archiveWindow.isMiniaturized {
            archiveWindow.close()
        }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidResize(_ notification: Notification) {
        if notification.object as? NSWindow === datePanel.parent { positionDatePanel() }
        guard notification.object as? NSWindow === window else { return }
        layoutPaper()
        revealWritingLine()
        rememberWindow()
    }

    func windowDidMove(_ notification: Notification) {
        if notification.object as? NSWindow === datePanel.parent { positionDatePanel() }
        guard notification.object as? NSWindow === window else { return }
        rememberWindow()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === datePanel else { return }
        if let anchor = wheelAnchor, let event = NSApp.currentEvent,
           event.type == .leftMouseDown, event.window === datePanel.parent,
           anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return }
        closeDateWheel()
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === datePanel.parent { closeDateWheel() }
        if notification.object as? NSWindow === window, let active {
            discardEmptySubtask(active)
        }
        guard let archiveWindow, notification.object as? NSWindow === archiveWindow else { return }
        clearArchiveEditor()
        archive.begin()
        let previous = stickyDay ?? today
        stickyDay = nil
        openDay(previous)
        window.makeKeyAndOrderFront(nil)
    }
    private func rememberWindow() { preferences.set(NSStringFromRect(window.frame), forKey: "windowFrame") }

    @objc private func checkDay() {
        let current = PlansStore.day()
        guard current != today, datePanel.parent == nil else { return }
        if isToday, let editing = window.firstResponder as? TaskInput, editing.hasMarkedText() { return }
        let follow = isToday
        if stickyDay == today { stickyDay = current }
        today = current
        archive.today = current
        if follow && editorHost == nil && stickyDay == nil { openDay(today) }
        else { refreshHeader() }
    }

    @objc private func systemAppearanceChanged() {
        DispatchQueue.main.async { [weak self] in self?.refreshAppearance() }
    }

    private func refreshAppearance(animateLamp: Bool = true) {
        let night = isNight
        let paperAppearance = theme == .system ? nil : NSAppearance(named: night ? .darkAqua : .aqua)
        window.appearance = archive.glassEnabled ? NSAppearance(named: .darkAqua) : paperAppearance
        datePanel.appearance = paperAppearance
        archiveWindow?.appearance = paperAppearance
        archiveWindow?.backgroundColor = PaperSwatch.paper[0].color(night: night)
        if archive.night != night { archive.night = night }
        let look = archive.look(night: night)
        look.apply(to: surface)
        surface.glass = archive.glassEnabled
        glassBackdrop.alphaValue = archive.glassBlur
        glassBackdrop.isHidden = !surface.glass || archive.glassBlur == 0
        look.apply(to: datePaper)
        datePaper.layer?.borderColor = gray(night ? 0.26 : 0.80).cgColor
        let font = archive.value("paperFont", preferences.bool(forKey: "originalFont") ? "ipa" : "print")
        style.usesOriginal = font == "ipa"
        style.usesSystem = font == "system"
        document.night = night
        let lampTarget: CGFloat = night && look.lamp ? 1 : 0
        if !night {
            lampFade = nil
            document.lampLevel = 0
        } else if (lampFade?.to ?? document.lampLevel) != lampTarget {
            if animateLamp && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                lampFade = (document.lampLevel, lampTarget,
                            Tween(duration: MechanismMotion.lampRise, easing: MechanismMotion.lampEase))
                animate()
            } else {
                lampFade = nil
                document.lampLevel = lampTarget
            }
        }
        document.mechanismStyle = look.mechanismStyle
        if (editingWindow.firstResponder as? TaskInput)?.hasMarkedText() != true { configureTasks() }
        layoutPaper()
        refreshHeader()
        mechanism.needsDisplay = true
        updateLight()
        refreshStatusMenu()
    }

    @objc private func updateLight() {
        let paper = editorHost == nil ? surface : (archiveBackdrop ?? surface)
        paper.lampLevel = document.lampLevel
        guard let source = document.lightSource,
              scroll.contentView.bounds.insetBy(dx: 0, dy: -4).contains(source) else {
            paper.lampOrigin = nil
            return
        }
        paper.lampOrigin = paper.convert(source, from: document)
    }

    private func refreshHeader() {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let title = parts.count == 3 ? "\(parts[1])月\(parts[2])日" : day
        let headerInk = surface.glass ? PaperSurface.glassInk : paperInk
        dateButton.attributedTitle = style.text(title, size: 14, ink: headerInk, pressed: !surface.glass)
        dateButton.setAccessibilityLabel("便签日期，\(day)")
        dateWheel.ink = paperInk
        if activeWheel === yearWheel { yearWheel.ink = document.night ? gray(0.86) : gray(0.12) }
        optionsButton.contentTintColor = headerInk.withAlphaComponent(0.72)
    }

    private func save() {
        do {
            try store.save(rows, for: day)
            saveErrorShown = false
            if archiveWindow?.isVisible == true { archive.objectWillChange.send() }
        } catch { showSaveError(error) }
    }

    private func showSaveError(_ error: Error) {
        guard !saveErrorShown else { return }
        saveErrorShown = true
        let alert = NSAlert()
        alert.messageText = "无法读写本地计划"
        alert.informativeText = "\(store.file.path)\n\(error.localizedDescription)"
        let host = archiveWindow.flatMap { $0.isVisible ? $0 : nil } ?? window
        alert.beginSheetModal(for: host)
    }

    private func openDay(_ selectedDay: String) {
        document.clearTaskDrag()
        day = selectedDay
        rows = store.rows(for: day)
        active = nil
        railMotion = nil
        draggingCarriage = false
        cursorDestination = nil
        crossings = [:]
        strikeStart = nil
        document.thrust = 0
        document.point = nil
        mechanism.needsDisplay = true
        refreshHeader()
        rebuildTasks()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        if let last = lastVisibleTask {
            focus(last.id, at: last.input.string.utf16.count)
        } else {
            editingWindow.makeFirstResponder(nil)
        }
    }

    private func rebuildTasks() {
        let previous = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let currentIDs = Set(rows.map(\.id))
        for task in tasks where !currentIDs.contains(task.id) { task.removeFromSuperview() }
        tasks = rows.map { row in
            if let existing = previous[row.id] {
                if existing.input.string != row.text { existing.input.string = row.text }
                if crossings[row.id] == nil { existing.crossing = row.done ? 1 : 0 }
                return existing
            }
            let task = PaperTask(row: row, style: style)
            task.input.delegate = self
            task.input.onCaret = { [weak self, weak task] in
                guard let self, let task, self.editingWindow.firstResponder === task.input else { return }
                self.follow(task.id)
            }
            task.input.onStrike = { [weak self] in self?.strike() }
            task.input.onBlur = { [weak self, weak task] in
                guard let self, let task,
                      self.rows.contains(where: { $0.id == task.id && $0.parentID != nil && !$0.hasText }) else { return }
                DispatchQueue.main.async { [weak self, weak task] in
                    guard let self, let task, self.editingWindow.firstResponder !== task.input else { return }
                    self.discardEmptySubtask(task.id)
                }
            }
            task.check.target = self
            task.check.action = #selector(toggleDone(_:))
            task.addChild.target = self
            task.addChild.action = #selector(addSubtaskForRow(_:))
            task.toggleChildren.target = self
            task.toggleChildren.action = #selector(toggleSubtasks(_:))
            document.addSubview(task, positioned: .below, relativeTo: mechanism)
            return task
        }
        configureTasks()
        layoutPaper()
        document.sortSubviews({ first, second, _ in
            if first === second { return .orderedSame }
            if !(first is PaperTask) { return second is PaperTask ? .orderedDescending : .orderedSame }
            if !(second is PaperTask) { return .orderedAscending }
            if first.frame.minY == second.frame.minY { return .orderedSame }
            return first.frame.minY < second.frame.minY ? .orderedAscending : .orderedDescending
        }, context: nil)
    }

    private func configureTasks() {
        document.usesGlass = editingOnGlass
        (scroll.verticalScroller as? PaperScroller)?.night = document.night || editingOnGlass
        for (index, task) in tasks.enumerated() {
            task.configure(index: index, done: rows[index].done, child: rows[index].parentID != nil,
                           ink: ink, size: archive.size(for: day), lineSpacing: archive.lineSpacing,
                           tinted: editingOnGlass || archive.inkIndex(for: day) != 0)
        }
    }

    private func layoutPaper(animateCaret: Bool = false) {
        if document.isDraggingTask { document.clearTaskDrag() }
        if let editorHost {
            guard editorHost.bounds.width >= 90, editorHost.bounds.height >= 50 else { return }
            scroll.frame = editorHost.bounds
        } else {
            let size = surface.bounds.size
            guard size.width >= window.minSize.width, size.height >= window.minSize.height else { return }
            header.frame = CGRect(x: 0, y: size.height - 56, width: size.width, height: 56)
            dateButton.frame = CGRect(x: size.width - 137, y: 15, width: 84, height: 27)
            optionsButton.frame = CGRect(x: size.width - 47, y: 15, width: 26, height: 27)
            grip.frame = CGRect(x: size.width - 21, y: 2, width: 20, height: 20)
            scroll.frame = CGRect(x: 0, y: 13, width: size.width, height: size.height - 69)
        }
        let contentWidth = scroll.contentSize.width
        let parents = Set(rows.compactMap { $0.hasText ? $0.parentID : nil })
        var y: CGFloat = 11
        for (index, task) in tasks.enumerated() {
            let row = rows[index]
            let indent: CGFloat = row.parentID == nil ? 0 : 18
            let width = contentWidth - 33 - indent
            task.updateDisclosure(index: index, hasChildren: parents.contains(row.id),
                                  collapsed: collapsedParents.contains(row.id))
            task.isHidden = isFolded(row)
            if task.isHidden {
                // Keep the model slot at its visible group's boundary for drag and drop.
                task.frame = CGRect(x: 6 + indent, y: y, width: width, height: 0)
                continue
            }
            let spaceBelow = archive.lineSpacing + (task.id == active ? document.carriageClearance : 0)
            y += task.align(width: width, y: y, indent: indent, spaceBelow: spaceBelow)
        }
        document.setFrameSize(NSSize(width: contentWidth, height: max(scroll.contentSize.height, y + 12)))
        mechanism.frame = document.bounds
        if let task = tasks.first(where: { $0.id == active && !$0.isHidden }) {
            positionCarriage(at: task, animate: animateCaret)
        }
        updateLight()
    }

    private func reorderLayout(for id: UUID) -> PaperDocument.ReorderLayout? {
        guard let source = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return PaperDocument.ReorderLayout(tasks: tasks, block: rows.taskBlock(at: source),
                                           slots: rows.reorderSlots(for: source))
    }

    private func moveTask(_ id: UUID, to slot: Int) {
        guard let source = rows.firstIndex(where: { $0.id == id }), rows.moveTask(at: source, to: slot) else { return }
        rebuildTasks()
        save()
    }

    private func focus(_ id: UUID, at location: Int, animate: Bool = false) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        if let parent = rows.first(where: { $0.id == id })?.parentID,
           collapsedParents.remove(parent) != nil { layoutPaper() }
        task.input.setSelectedRange(NSRange(location: min(location, task.input.string.utf16.count), length: 0))
        editingWindow.makeFirstResponder(task.input)
        follow(id, animate: animate)
        revealWritingLine()
    }

    private func revealWritingLine() {
        if let point = cursorDestination {
            let viewport = scroll.contentView.bounds
            let y = max(point.y + (document.mechanismStyle == .signal ? 46 : 39) - viewport.height,
                        min(viewport.minY, point.y - 32))
            guard abs(viewport.minY - y) > 1 else { return }
            scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func follow(_ id: UUID, animate: Bool = true) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        if active == id {
            positionCarriage(at: task, animate: animate)
        } else {
            active = id
            layoutPaper(animateCaret: animate)
            revealWritingLine()
        }
    }

    private func positionCarriage(at task: PaperTask, animate: Bool) {
        var target = task.caret(in: document)
        target.y = max(target.y, task.frame.minY + task.input.frame.maxY - 4)
        guard cursorDestination != target else { return }
        cursorDestination = target
        if draggingCarriage { return }
        if animate, let from = document.point, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            railMotion = (from, Tween(duration: abs(from.y - target.y) > 3 ? 0.18 : 0.09))
            self.animate()
        } else {
            railMotion = nil
            document.point = target
            mechanism.needsDisplay = true
        }
    }

    private func toggleCarriageLamp() {
        if document.night {
            preferences.set(!preferences.bool(forKey: "lamp"), forKey: "lamp")
        } else {
            preferences.set(Theme.night.rawValue, forKey: "theme")
            preferences.set(true, forKey: "lamp")
        }
        refreshSettings()
    }

    private func dragCarriage(to x: CGFloat?) {
        guard let point = document.point else { return }
        if let x {
            draggingCarriage = true
            railMotion = nil
            document.point = CGPoint(x: document.railPosition(at: x), y: point.y)
            mechanism.needsDisplay = true
        } else {
            draggingCarriage = false
            guard let target = cursorDestination, target != point else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                document.point = target
                mechanism.needsDisplay = true
            } else {
                railMotion = (point, Tween(duration: MechanismMotion.settleDuration(distance: target.x - point.x),
                                          easing: MechanismMotion.returnEase))
                animate()
            }
        }
    }

    private func strike(returning: Bool = false) {
        if preferences.bool(forKey: "sound") { style.play(returning: returning) }
        if !returning, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            strikeStart = CACurrentMediaTime()
            animate()
        }
    }

    private func animate() {
        guard animator == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.animationFrame() }
        RunLoop.main.add(timer, forMode: .common)
        animator = timer
    }

    private func animationFrame() {
        let time = CACurrentMediaTime()
        if let fade = lampFade {
            let amount = fade.tween.progress(time)
            document.lampLevel = fade.from + (fade.to - fade.from) * amount
            updateLight()
            if amount >= 1 { lampFade = nil }
        }
        if let motion = railMotion, let destination = cursorDestination {
            let amount = motion.tween.progress(time)
            document.point = CGPoint(x: motion.origin.x + (destination.x - motion.origin.x) * amount,
                                     y: motion.origin.y + (destination.y - motion.origin.y) * amount)
            if amount >= 1 { railMotion = nil }
        }
        if let start = strikeStart {
            let elapsed = time - start
            document.thrust = PaperDocument.strikeTravel(at: elapsed)
            if elapsed >= PaperDocument.strikeDuration { strikeStart = nil }
        }
        for (id, motion) in crossings {
            let amount = motion.tween.progress(time)
            tasks.first(where: { $0.id == id })?.crossing = motion.from + (motion.to - motion.from) * amount
            if amount >= 1 { crossings[id] = nil }
        }
        mechanism.needsDisplay = true
        if railMotion == nil, lampFade == nil, strikeStart == nil, crossings.isEmpty {
            animator?.invalidate()
            animator = nil
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let input = notification.object as? TaskInput, !input.hasMarkedText(),
              let index = tasks.firstIndex(where: { $0.input === input }) else { return }
        rows[index].text = input.string
        tasks[index].restyle()
        let lastPoint = document.point
        layoutPaper()
        revealWritingLine()
        if let lastPoint, let target = cursorDestination, lastPoint != target,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            document.point = lastPoint
            railMotion = (lastPoint, Tween(duration: abs(lastPoint.y - target.y) > 3 ? 0.18 : 0.09))
            animate()
        }
        save()
        if document.night != isNight { refreshAppearance() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let input = notification.object as? TaskInput,
              editingWindow.firstResponder === input,
              let task = tasks.first(where: { $0.input === input }) else { return }
        follow(task.id)
    }

    func textView(_ textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText(), let index = tasks.firstIndex(where: { $0.input === textView }) else { return false }
        let selection = textView.selectedRange()
        let handled: (UUID, Int, Bool)
        switch command {
        case #selector(NSResponder.insertNewline(_:)):
            guard let next = rows.splitRow(at: index, selection: selection) else { return true }
            handled = (next, 0, true)
        case #selector(NSResponder.cancelOperation(_:)):
            return discardEmptySubtask(rows[index].id, returnToParent: true)
        case #selector(NSResponder.insertTab(_:)):
            let id = rows[index].id
            guard rows.indentRow(at: index) else { return false }
            handled = (id, selection.location, false)
        case #selector(NSResponder.insertBacktab(_:)):
            let id = rows[index].id
            if discardEmptySubtask(id, returnToParent: true) { return true }
            guard rows.outdentRow(at: index) else { return false }
            handled = (id, selection.location, false)
        case #selector(NSResponder.deleteBackward(_:)) where index > 0 && selection.location == 0 && selection.length == 0:
            if rows[index].parentID != nil {
                discardEmptySubtask(rows[index].id, returnToParent: true)
                return true
            }
            let target = rows.mergeRow(at: index)
            handled = (target.id, target.offset, false)
        default:
            return false
        }
        updateTaskStructure(focus: handled.0, offset: handled.1)
        if handled.2 { strike(returning: true) }
        return true
    }

    private var subtaskAnchor: Int? {
        guard editingWindow.isVisible, (editingWindow.firstResponder as? TaskInput)?.hasMarkedText() != true,
              let index = rows.firstIndex(where: { $0.id == active }), rows[index].hasText else { return nil }
        return index
    }

    @objc private func addSubtask() {
        guard let index = subtaskAnchor else { return }
        insertSubtask(at: index)
    }

    @objc private func addSubtaskForRow(_ sender: NSButton) {
        guard let index = tasks.firstIndex(where: { $0.addChild === sender }),
              rows[index].parentID == nil, rows[index].hasText else { return }
        if (editingWindow.firstResponder as? TaskInput)?.hasMarkedText() == true {
            editingWindow.makeFirstResponder(nil)
        }
        insertSubtask(at: index)
    }

    private func insertSubtask(at index: Int) {
        let parent = rows[index].parentID ?? rows[index].id
        if let draft = rows.first(where: { $0.parentID == parent && !$0.hasText }) {
            focus(draft.id, at: draft.text.utf16.count)
            return
        }
        collapsedParents.remove(parent)
        let child = rows.addChild(at: index)
        rebuildTasks()
        focus(child, at: 0, animate: true)
    }

    private func isFolded(_ row: PlanRow) -> Bool {
        guard let parent = row.parentID else { return false }
        return collapsedParents.contains(parent)
    }

    @objc private func toggleSubtasks(_ sender: NSButton) {
        guard let task = tasks.first(where: { $0.toggleChildren === sender }),
              (editingWindow.firstResponder as? TaskInput)?.hasMarkedText() != true else { return }
        if collapsedParents.remove(task.id) == nil {
            collapsedParents.insert(task.id)
            if rows.first(where: { $0.id == active })?.parentID == task.id {
                focus(task.id, at: task.input.string.utf16.count, animate: true)
                return
            }
        }
        layoutPaper()
    }

    @discardableResult
    private func discardEmptySubtask(_ id: UUID, returnToParent: Bool = false) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let parent = rows[index].parentID, !rows[index].hasText else { return false }
        rows.remove(at: index)
        if active == id { active = parent }
        rebuildTasks()
        if returnToParent, let row = rows.first(where: { $0.id == parent }) {
            focus(parent, at: row.text.utf16.count, animate: true)
        }
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(addSubtask) || subtaskAnchor != nil
    }

    private func updateTaskStructure(focus id: UUID, offset: Int) {
        rebuildTasks()
        focus(id, at: offset, animate: true)
        save()
    }

    @objc private func toggleDone(_ sender: NSButton) {
        guard let index = tasks.firstIndex(where: { $0.check === sender }) else { return }
        let task = tasks[index]
        rows[index].done = sender.state == .on
        let goal: CGFloat = rows[index].done ? 1 : 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { task.crossing = goal }
        else {
            crossings[task.id] = (task.crossing, goal, Tween(duration: 0.24))
            animate()
        }
        save()
    }

    private func setupDateWheel() {
        datePanel.identifier = NSUserInterfaceItemIdentifier("DateWheelPanel")
        datePanel.isOpaque = false
        datePanel.backgroundColor = .clear
        datePanel.hasShadow = true
        datePanel.delegate = self
        datePanel.contentView = datePaper
        datePaper.softGrain = true
        datePaper.wantsLayer = true
        datePaper.layer?.cornerRadius = 11
        datePaper.layer?.masksToBounds = true
        datePaper.layer?.borderWidth = 1
        dateWheel.onSelect = { [weak self] selected in self?.switchStickyDay(to: selected) }
        yearWheel.onSelect = { [weak self] value in
            guard let self, let year = Int(value) else { return }
            self.dismissWheel()
            self.archive.setMonth(year: year, number: self.archive.number)
        }
        dateWheel.onCancel = { [weak self] in self?.dismissWheel() }
        yearWheel.onCancel = { [weak self] in self?.dismissWheel() }
    }

    @objc private func toggleDateWheel() {
        checkDay()
        dateWheel.reset(to: PlansStore.date(for: day, calendar: archive.calendar) ?? Date())
        openWheel(dateWheel, anchor: dateButton, title: "选择便签日期", width: 246)
    }

    private func showYearWheel(_ anchor: NSButton) {
        yearWheel.reset(to: archive.monthStart)
        yearWheel.ink = document.night ? gray(0.86) : gray(0.12)
        openWheel(yearWheel, anchor: anchor, title: "选择年份", width: 176)
    }

    private func openWheel(_ wheel: DateWheel, anchor: NSButton, title: String, width: CGFloat) {
        if datePanel.parent != nil {
            dismissWheel()
            return
        }
        guard let owner = anchor.window else { return }
        activeWheel = wheel
        wheelAnchor = anchor
        datePanel.title = title
        datePanel.setContentSize(NSSize(width: width, height: 184))
        wheel.frame = datePaper.bounds.insetBy(dx: 12, dy: 8)
        datePaper.addSubview(wheel)
        datePanel.level = owner.level
        owner.addChildWindow(datePanel, ordered: .above)
        positionDatePanel()
        datePanel.makeKeyAndOrderFront(nil)
        datePanel.makeFirstResponder(wheel)
    }

    private func positionDatePanel() {
        guard let owner = datePanel.parent, let screen = owner.screen?.visibleFrame else { return }
        let size = datePanel.frame.size
        let target: CGPoint
        if owner === window {
            let right = window.frame.maxX + 8
            let left = window.frame.minX - 8 - size.width
            let roomOnRight = screen.maxX - right
            let roomOnLeft = window.frame.minX - 8 - screen.minX
            let side = roomOnRight >= size.width || roomOnRight >= roomOnLeft ? right : left
            target = CGPoint(x: side, y: window.frame.maxY - 10 - size.height)
        } else if let anchor = wheelAnchor {
            let frame = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            target = CGPoint(x: frame.midX - size.width / 2, y: frame.minY - 7 - size.height)
        } else { return }
        let x = min(max(target.x, screen.minX), screen.maxX - size.width)
        let y = min(max(target.y, screen.minY), screen.maxY - size.height)
        datePanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func closeDateWheel() {
        guard let owner = datePanel.parent else { return }
        activeWheel?.stop()
        owner.removeChildWindow(datePanel)
        datePanel.orderOut(nil)
        activeWheel?.removeFromSuperview()
        activeWheel = nil
        wheelAnchor = nil
    }

    private func dismissWheel() {
        let owner = datePanel.parent
        closeDateWheel()
        owner?.makeKey()
    }

    private func switchStickyDay(to selected: String) {
        closeDateWheel()
        window.makeKey()
        guard selected != day else { return }
        window.makeFirstResponder(nil)
        openDay(selected)
    }

    @objc private func showArchive() {
        closeDateWheel()
        checkDay()
        if let archiveWindow, archiveWindow.isVisible || archiveWindow.isMiniaturized {
            if archiveWindow.isMiniaturized { archiveWindow.deminiaturize(nil) }
            archiveWindow.makeKeyAndOrderFront(nil)
            return
        }
        if archiveWindow == nil {
            let bounds = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1120, height: 800)
            let frame = NSRect(x: 0, y: 0, width: min(1160, bounds.width - 32), height: min(733, bounds.height - 45))
            let browser = NSWindow(contentRect: frame,
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
            browser.title = "Paperframe"
            browser.titleVisibility = .hidden
            browser.titlebarAppearsTransparent = true
            browser.titlebarSeparatorStyle = .none
            browser.isMovableByWindowBackground = true
            browser.isReleasedWhenClosed = false
            browser.contentMinSize = NSSize(width: 930, height: 510)
            browser.delegate = self
            archive.onDay = { [weak self] selected in
                guard let self else { return }
                self.editingWindow.makeFirstResponder(nil)
                if let selected { self.openDay(selected) }
                else { self.clearArchiveEditor() }
            }
            archive.onSetting = { [weak self] in self?.refreshAppearance() }
            browser.contentView = NSHostingView(rootView: ArchiveView(state: archive,
                attachEditor: { [weak self] in self?.attachArchiveEditor($0) },
                attachBackdrop: { [weak self] in self?.archiveBackdrop = $0 },
                openYearWheel: { [weak self] in self?.showYearWheel($0) },
                openSticky: { [weak self] in self?.showWindow() }))
            browser.center()
            archiveWindow = browser
        }
        window.makeFirstResponder(nil)
        stickyDay = day
        archive.begin()
        archiveWindow?.appearance = datePanel.appearance
        archiveWindow?.backgroundColor = PaperSwatch.paper[0].color(night: archive.night)
        window.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        archiveWindow?.makeKeyAndOrderFront(nil)
    }

    private func attachArchiveEditor(_ host: PaperSurface) {
        editorHost = host
        host.addSubview(scroll)
        surface.lampOrigin = nil
        configureTasks()
        host.onResize = { [weak self] in
            self?.layoutPaper()
            self?.revealWritingLine()
        }
        layoutPaper()
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, let host, self.editorHost === host, let last = self.lastVisibleTask else { return }
            self.focus(last.id, at: last.input.string.utf16.count)
        }
    }

    private func clearArchiveEditor() {
        guard let host = editorHost else { return }
        host.onResize = nil
        archiveBackdrop?.lampOrigin = nil
        editorHost = nil
        surface.addSubview(scroll, positioned: .below, relativeTo: header)
        configureTasks()
        layoutPaper()
    }

    @objc private func showOptions(_ sender: NSButton) {
        options().popUp(positioning: nil, at: CGPoint(x: 0, y: 0), in: sender)
    }

    private func item(_ label: String, _ action: Selector, value: Any? = nil, key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: label, action: action, keyEquivalent: key)
        result.target = self
        result.representedObject = value
        return result
    }

    private func options() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("打开 Paperframe", #selector(showArchive)))
        menu.addItem(.separator())
        for appearance in Theme.allCases {
            let entry = item(appearance.title, #selector(setTheme(_:)), value: appearance.rawValue)
            entry.state = theme == appearance ? .on : .off
            menu.addItem(entry)
        }
        let glass = item("透明玻璃", #selector(togglePreference(_:)), value: "glassEnabled")
        glass.state = archive.glassEnabled ? .on : .off
        menu.addItem(glass)
        if archive.glassEnabled {
            let blur = NSMenuItem(title: "背景模糊", action: nil, keyEquivalent: "")
            let levels = NSMenu()
            for value in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let entry = item("\(Int(value * 100))%", #selector(setGlassBlur(_:)), value: value)
                entry.state = abs(archive.glassBlur - value) < 0.005 ? .on : .off
                levels.addItem(entry)
            }
            blur.submenu = levels
            menu.addItem(blur)
        }
        menu.addItem(.separator())
        for (key, title) in [("lamp", "夜间开灯"), ("sound", "机械打字声"), ("pin", "始终置顶")] {
            let entry = item(title, #selector(togglePreference(_:)), value: key)
            entry.state = preferences.bool(forKey: key) ? .on : .off
            menu.addItem(entry)
        }
        let mechanic = NSMenuItem(title: "打字机造型", action: nil, keyEquivalent: "")
        let styles = NSMenu()
        for option in MechanismStyle.allCases {
            let entry = item(option.title, #selector(setMechanismStyle(_:)), value: option.rawValue)
            entry.state = archive.mechanismStyle == option ? .on : .off
            styles.addItem(entry)
        }
        mechanic.submenu = styles
        menu.addItem(mechanic)
        menu.addItem(.separator())
        for (title, size) in [("小号", NSSize(width: 285, height: 290)),
                              ("中号", NSSize(width: 375, height: 386)),
                              ("大号", NSSize(width: 496, height: 500))] {
            menu.addItem(item(title, #selector(setSize(_:)), value: NSValue(size: size)))
        }
        menu.addItem(.separator())
        let alternate = item("使用 IPA 原版中文字体", #selector(togglePreference(_:)), value: "originalFont")
        alternate.state = style.usesOriginal ? .on : .off
        menu.addItem(alternate)
        menu.addItem(item("字体与录音许可", #selector(showLicenses)))
        return menu
    }

    private func buildMainMenu() {
        let root = NSMenu()
        let appItem = NSMenuItem()
        root.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(item("显示便签", #selector(showWindow)))
        appMenu.addItem(item("隐藏便签", #selector(hideWindow)))
        appMenu.addItem(item("打开 Paperframe", #selector(showArchive)))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Paperframe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem()
        root.addItem(edit)
        let editMenu = NSMenu(title: "编辑")
        edit.submenu = editMenu
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"),
                                      ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        editMenu.addItem(.separator())
        editMenu.addItem(item("添加子任务", #selector(addSubtask), key: "\r"))
        let windowItem = NSMenuItem()
        root.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        for (title, action, key) in [("关闭", #selector(NSWindow.performClose(_:)), "w"),
                                      ("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
                                      ("缩放", #selector(NSWindow.performZoom(_:)), "")] {
            let command = NSMenuItem(title: title, action: action, keyEquivalent: key)
            windowMenu.addItem(command)
        }
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = root
    }

    private func refreshStatusMenu() {
        let menu = NSMenu()
        menu.addItem(item("显示便签", #selector(showWindow)))
        menu.addItem(item("隐藏便签", #selector(hideWindow)))
        menu.addItem(item("打开 Paperframe", #selector(showArchive)))
        let settings = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        settings.submenu = options()
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Paperframe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
    }

    @objc private func hideWindow() {
        closeDateWheel()
        window.orderOut(nil)
    }

    @objc private func setTheme(_ sender: NSMenuItem) {
        preferences.set(sender.representedObject as? String, forKey: "theme")
        refreshSettings()
    }

    @objc private func setMechanismStyle(_ sender: NSMenuItem) {
        guard let selected = sender.representedObject as? String else { return }
        preferences.set(selected, forKey: "mechanismStyle")
        refreshSettings()
    }

    @objc private func togglePreference(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        preferences.set(!preferences.bool(forKey: key), forKey: key)
        if key == "pin" { applyPin() }
        if key == "originalFont" {
            let useOriginal = !style.usesOriginal
            preferences.set(useOriginal, forKey: key)
            preferences.set(useOriginal ? "ipa" : "print", forKey: "paperFont")
        }
        refreshSettings()
    }

    @objc private func setGlassBlur(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        preferences.set(value, forKey: "glassBlur")
        refreshSettings()
    }

    private func refreshSettings() {
        refreshAppearance()
        archive.objectWillChange.send()
    }

    private func applyPin() {
        let pinned = preferences.bool(forKey: "pin")
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed, .fullScreenNone]
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let size = (sender.representedObject as? NSValue)?.sizeValue else { return }
        var frame = window.frame
        let right = frame.maxX
        let top = frame.maxY
        frame.size = size
        frame.origin = CGPoint(x: right - size.width, y: top - size.height)
        if let screen = window.screen?.visibleFrame {
            frame.size = CGSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: true)
    }

    @objc private func showLicenses() {
        guard let license = Bundle.main.url(forResource: "资源与授权", withExtension: "txt") else { return }
        NSWorkspace.shared.open(license)
    }
}

let app = NSApplication.shared
private let delegate = PaperApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
