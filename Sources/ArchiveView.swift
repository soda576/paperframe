import AppKit
import QuartzCore
import SwiftUI

struct PaperSwatch {
    let name: String
    let light: NSColor
    let dark: NSColor

    func color(night: Bool) -> NSColor { night ? dark : light }

    static let paper: [Self] = [
        .init(name: "原纸", light: rgb(PaperSurface.daylightPaper), dark: rgb(PaperSurface.lowLightPaper)),
        .init(name: "冰蓝", light: rgb(0xe1ecf6), dark: rgb(0x253d55)),
        .init(name: "雾紫", light: rgb(0xeee7f4), dark: rgb(0x3c2d50)),
        .init(name: "灰绿", light: rgb(0xe5eee8), dark: rgb(0x294536)),
    ]
    static let ink: [Self] = [
        .init(name: "原墨", light: gray(0.18), dark: gray(0.73)),
        .init(name: "石墨", light: gray(0.38), dark: gray(0.59)),
        .init(name: "蓝墨", light: rgb(0x28578b), dark: rgb(0x91b9e8)),
        .init(name: "红墨", light: rgb(0x813c49), dark: rgb(0xd99ba7)),
        .init(name: "绿墨", light: rgb(0x315c46), dark: rgb(0x95c0a4)),
    ]
    static let light: [Self] = [
        .init(name: "中性", light: .white, dark: .white),
        .init(name: "暖黄", light: rgb(0xffcd90), dark: rgb(0xffcd90)),
        .init(name: "冷蓝", light: rgb(0xa6cbff), dark: rgb(0xa6cbff)),
    ]

    static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

struct PaperLook {
    let night: Bool
    let paper: Int
    let lamp: Bool
    let lampTint: Int
    let intensity: Double
    let range: Double
    let mechanismStyle: MechanismStyle

    func apply(to surface: PaperSurface) {
        surface.night = night
        surface.paperTint = paper == 0 ? nil : PaperSwatch.paper[paper].color(night: night)
        surface.lampTint = lampTint == 0 ? nil : PaperSwatch.light[lampTint].dark
        surface.lampIntensity = intensity
        surface.lampRange = range
        surface.mechanismStyle = mechanismStyle
    }
}

final class ArchiveState: ObservableObject {
    let store: PlansStore
    let defaults: UserDefaults
    let style: PaperStyle
    private let pixel = PaperStyle.load("PixelifySans")

    func displayFont(_ size: CGFloat) -> Font {
        guard let pixel else { return .system(size: size, design: .monospaced) }
        return .custom(pixel, size: size)
    }
    var onDay: ((String?) -> Void)?
    var onSetting: (() -> Void)?
    @Published var month = Date()
    @Published var selectedDay: String?
    @Published var night = false
    @Published var today = PlansStore.day()

    init(store: PlansStore, defaults: UserDefaults, style: PaperStyle) {
        self.store = store
        self.defaults = defaults
        self.style = style
    }

    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }()

    var year: Int { calendar.component(.year, from: month) }
    var number: Int { calendar.component(.month, from: month) }
    var monthStart: Date { calendar.dateInterval(of: .month, for: month)?.start ?? month }

    func begin() {
        month = Date()
        selectedDay = nil
    }

    func select(_ day: String?) {
        guard day != selectedDay else { return }
        onDay?(day)
        selectedDay = day
    }

    func moveMonth(_ offset: Int) {
        guard let next = calendar.date(byAdding: .month, value: offset, to: monthStart),
              (1...9999).contains(calendar.component(.year, from: next)) else { return }
        select(nil)
        month = next
    }

    func setMonth(year: Int, number: Int) {
        guard let next = calendar.date(from: DateComponents(year: year, month: number, day: 1)) else { return }
        select(nil)
        month = next
    }

    func returnToCurrentMonth() {
        select(nil)
        month = Date()
    }

    func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }

    func set<T>(_ key: String, _ value: T) {
        defaults.set(value, forKey: key)
        onSetting?()
        objectWillChange.send()
    }

    func setting<T>(_ key: String, _ fallback: T) -> Binding<T> {
        Binding(get: { self.value(key, fallback) }, set: { self.set(key, $0) })
    }

    func size(for day: String? = nil) -> Double {
        day.map { value("noteSize.\($0)", value("fontSize", 19.0)) } ?? value("fontSize", 19.0)
    }

    var lineSpacing: Double { value("lineSpacing", 0.0) }
    static let defaultGlassBlur = 0.55
    var glassEnabled: Bool { value("glassEnabled", false) }
    var glassBlur: Double { value("glassBlur", Self.defaultGlassBlur) }

    func inkIndex(for day: String? = nil) -> Int {
        day.map { value("noteInk.\($0)", value("ink", 0)) } ?? value("ink", 0)
    }

    var mechanismStyle: MechanismStyle {
        MechanismStyle(rawValue: value("mechanismStyle", "")) ?? .signal
    }

    func look(night: Bool) -> PaperLook {
        PaperLook(night: night, paper: value("paperTint", 0), lamp: value("lamp", true),
                  lampTint: value("lampTint", 0), intensity: value("lampIntensity", 1.0),
                  range: value("lampRange", 1.0), mechanismStyle: mechanismStyle)
    }
}

struct ArchiveView: View {
    @ObservedObject var state: ArchiveState
    let attachEditor: (PaperSurface) -> Void
    let attachBackdrop: (PaperSurface) -> Void
    let openYearWheel: (NSButton) -> Void
    let openSticky: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal: CGFloat = 1
    @State private var showRail = false
    @State private var animationTask: Task<Void, Never>?
    @State private var activityMode = ActivityMode.day
    @State private var strikeTrial = 0

    private let blue = Color(nsColor: PaperSwatch.rgb(0x306da7))
    private var ink: Color { state.night ? Color(white: 0.86) : Color(white: 0.12) }
    private var dim: Color { state.night ? Color(white: 0.62) : Color(white: 0.36) }
    private var rule: Color { ink.opacity(0.21) }
    private var background: Color { Color(nsColor: PaperSwatch.paper[0].color(night: state.night)) }
    private var calendarBlue: Color { state.night ? Color(nsColor: PaperSwatch.rgb(0x83b7e1)) : blue }
    private var monthText: String { String(format: "%02d", state.number) }
    private var monthLength: Int { state.calendar.range(of: .day, in: .month, for: state.monthStart)?.count ?? 0 }
    private var leadingDays: Int {
        let weekday = state.calendar.component(.weekday, from: state.monthStart)
        return (weekday - state.calendar.firstWeekday + 7) % 7
    }

    var body: some View {
        let summary = state.store.summary(year: state.year, month: state.number)
        GeometryReader { geometry in
            HStack(spacing: 0) {
                calendar(recorded: summary.recordedDays).padding(.top, 20).frame(width: geometry.size.width * 0.40)
                Rectangle().fill(rule).frame(width: 1)
                center(summary).frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(rule).frame(width: 1)
                inspector.frame(width: geometry.size.width * 0.265)
            }
        }
        .font(noteFont(14))
        .foregroundStyle(ink)
        .buttonStyle(.plain)
        .background(background)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(state.night ? .dark : .light)
        .onChange(of: state.selectedDay) { _ in animateDetail() }
    }

    private func noteFont(_ size: CGFloat) -> Font {
        .custom(state.style.font(latin: false, size: size).fontName, size: size)
    }

    private func type(_ size: CGFloat) -> Font {
        .custom(state.style.font(latin: true, size: size).fontName, size: size)
    }

    private func printed(_ string: String, size: CGFloat = 15) -> Text {
        var result = AttributedString(string)
        for index in result.characters.indices {
            let next = result.characters.index(after: index)
            let isLatin = result.characters[index].unicodeScalars.allSatisfy(\.isASCII)
            result[index..<next].font = isLatin ? type(size) : noteFont(size)
        }
        return Text(result)
    }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 27, height: 27)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .help(label)
    }

    private func calendar(recorded: Set<Int>) -> some View {
        let offset = leadingDays
        let count = monthLength
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 7) {
                Text(monthText).font(state.displayFont(72)).fixedSize().accessibilityHidden(true)
                OrbitMark().stroke(ink, lineWidth: 0.8)
                    .overlay(alignment: .bottomTrailing) {
                        Triangle().fill(calendarBlue).frame(width: 23, height: 23).padding(.trailing, 6)
                    }
                    .frame(width: 67, height: 52).accessibilityHidden(true)
                Spacer(minLength: 0)
                calendarNavigation
            }
            .frame(height: 93)

            HStack(spacing: 0) {
                ForEach(Array("一二三四五六日"), id: \.self) { letter in
                    Text(String(letter)).foregroundStyle(dim).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                }
            }.frame(height: 31)
            Rectangle().fill(ink.opacity(0.68)).frame(height: 1)
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { column in
                            let number = week * 7 + column - offset + 1
                            Group {
                                if number >= 1, number <= count {
                                    dayCell(number, hasNote: recorded.contains(number))
                                } else { Color.clear }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .trailing) {
                                if column < 6 { Rectangle().fill(rule).frame(width: 1) }
                            }
                        }
                    }
                    Rectangle().fill(rule).frame(height: 1)
                }
            }
            HStack(spacing: 7) {
                recordedDayMark
                Text("有便签").foregroundStyle(dim)
                Spacer()
                Button("回到本月") { state.returnToCurrentMonth() }.foregroundStyle(dim)
            }.font(noteFont(12)).padding(.top, 14)
        }
        .padding(20)
    }

    private var calendarNavigation: some View {
        HStack(spacing: 0) {
            icon("chevron.left", "上个月") { state.moveMonth(-1) }
            Menu {
                ForEach(1...12, id: \.self) { month in
                    Button("\(month) 月") { state.setMonth(year: state.year, number: month) }
                }
            } label: {
                HStack(spacing: 4) {
                    printed("\(state.number) 月", size: 14)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 49, height: 30)
            .accessibilityLabel("选择月份")
            .accessibilityValue("\(state.number) 月")
            Rectangle().fill(rule).frame(width: 1, height: 14)
            ArchiveYearButton(title: String(state.year), style: state.style,
                              ink: NSColor(ink), open: openYearWheel)
                .frame(width: 58, height: 30)
            icon("chevron.right", "下个月") { state.moveMonth(1) }
        }
        .background(calendarBlue.opacity(state.night ? 0.08 : 0.045))
        .overlay { Rectangle().strokeBorder(rule, lineWidth: 1).allowsHitTesting(false) }
    }

    private var recordedDayMark: some View {
        Rectangle().fill(calendarBlue).frame(width: 8, height: 8)
            .rotationEffect(.degrees(45)).frame(width: 13, height: 13)
            .accessibilityHidden(true)
    }

    private func dayCell(_ number: Int, hasNote: Bool) -> some View {
        let key = String(format: "%04d-%02d-%02d", state.year, state.number, number)
        let active = state.selectedDay == key
        let today = key == state.today
        let tint: Double = active ? (state.night ? 0.23 : 0.13) : (state.night ? 0.12 : 0.065)
        return Button {
            state.select(key)
        } label: {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(hasNote || active ? calendarBlue.opacity(tint) : Color.clear)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(String(number)).font(type(19))
                        .fixedSize()
                        .foregroundStyle(today ? calendarBlue : ink)
                        .overlay(alignment: .bottomLeading) {
                            if today { Rectangle().fill(calendarBlue).frame(width: 12, height: 1).offset(y: 2) }
                        }
                    Spacer(minLength: 0)
                    if hasNote { recordedDayMark.alignmentGuide(.firstTextBaseline) { $0.height - 2 } }
                }
                .padding(.top, 8).padding(.horizontal, 6)
                if active { Rectangle().strokeBorder(calendarBlue, lineWidth: 1.2) }
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(hasNote ? "\(key)，有便签" : key)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func center(_ summary: MonthSummary) -> some View {
        ZStack {
            if let day = state.selectedDay { detail(day) }
            else { overview(summary) }
        }
        .background(alignment: .center) {
            PaperSample(look: state.look(night: state.night), onCreate: attachBackdrop)
                .allowsHitTesting(false)
        }
    }

    private func overview(_ totals: MonthSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("MONTHLY REVIEW").font(state.displayFont(12)).tracking(0.8).foregroundStyle(blue)
                        Spacer()
                        Text("\(String(state.year)) / \(monthText)").font(type(12)).foregroundStyle(dim)
                    }
                    Text("月度回顾").font(noteFont(30)).accessibilityAddTraits(.isHeader)
                }
                Rectangle().fill(ink).frame(height: 1)
                completionScale(totals)
                Rectangle().fill(rule).frame(height: 1)
                ActivityHeatmap(history: ActivityHistory(store: state.store, through: state.month,
                                                          calendar: state.calendar),
                                calendar: state.calendar, night: state.night,
                                textFont: noteFont(16), axisFont: type(10), mode: $activityMode) { day in
                    guard let key = day.dayKey else { return }
                    if !state.calendar.isDate(day.start, equalTo: state.month, toGranularity: .month) {
                        state.month = day.start
                    }
                    state.select(key)
                }
                Rectangle().fill(rule).frame(height: 1)
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近完成").font(noteFont(16)).accessibilityAddTraits(.isHeader)
                    if totals.completed.isEmpty {
                        Text("这个月还没有已完成的任务。").foregroundStyle(dim)
                    } else {
                        ForEach(totals.completed.indices, id: \.self) { index in
                            let entry = totals.completed[index]
                            Button {
                                state.select(entry.day)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(entry.day.suffix(5).replacingOccurrences(of: "-", with: "."))
                                        .font(type(13)).foregroundStyle(dim)
                                    printed(entry.text).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 4)
                                    Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(dim)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }.padding(23).frame(maxWidth: .infinity, alignment: .leading)
                .background(PaperScrollStyle(axis: .vertical, night: state.night))
        }
    }

    private func completionScale(_ totals: MonthSummary) -> some View {
        let percent = Int((totals.completion * 100).rounded())
        return VStack(alignment: .leading, spacing: 9) {
            Text("任务完成率").font(noteFont(16)).accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(totals.total > 0 ? String(percent) : "—")
                        .font(state.displayFont(54))
                    if totals.total > 0 { Text("%").font(state.displayFont(24)) }
                }.accessibilityHidden(true)
                Spacer(minLength: 8)
                Text(totals.total > 0 ? "已完成 \(totals.done) / \(totals.total) 项" : "本月暂无任务")
                    .font(noteFont(13)).foregroundStyle(dim)
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(rule).frame(height: 9)
                    Rectangle().fill(blue)
                        .frame(width: width * totals.completion, height: 9)
                        .overlay(alignment: .trailing) {
                            if totals.completion > 0, totals.completion < 1 {
                                Rectangle().fill(blue).frame(width: 2, height: 15)
                            }
                        }
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.32), value: totals.completion)
                    Canvas { context, size in
                        for tick in 0...20 {
                            let x = 0.5 + (size.width - 1) * CGFloat(tick) / 20
                            let height: CGFloat = tick.isMultiple(of: 5) ? 6 : 3
                            context.fill(Path(CGRect(x: x - 0.5, y: 12, width: 1, height: height)),
                                         with: .color(tick.isMultiple(of: 5) ? dim : rule))
                        }
                    }
                }
            }
            .frame(height: 18)
            .accessibilityLabel("任务完成进度")
            .accessibilityValue(totals.total > 0 ? "\(percent)%" : "暂无任务")
            GeometryReader { geometry in
                HStack {
                    Text("0")
                    Spacer()
                    Text("100%")
                }
                ForEach([25, 50, 75], id: \.self) { tick in
                    Text(String(tick)).position(x: geometry.size.width * CGFloat(tick) / 100,
                                                y: geometry.size.height / 2)
                }
            }.frame(height: 13).font(type(11)).foregroundStyle(dim).accessibilityHidden(true)
        }
    }

    private func detail(_ day: String) -> some View {
        let progress = state.store.progress(for: day)
        return VStack(alignment: .leading, spacing: 13) {
            Button { state.select(nil) } label: {
                Label("返回月度回顾", systemImage: "arrow.left").foregroundStyle(dim)
            }
            Text("NOTES").font(state.displayFont(17)).foregroundStyle(blue)
            Text(day.suffix(5).replacingOccurrences(of: "-", with: "."))
                .font(state.displayFont(53)).accessibilityLabel(day)
                .accessibilityAddTraits(.isHeader)
            Text("已完成 \(progress.done) / \(progress.total)").foregroundStyle(dim)
            GeometryReader { size in
                ZStack(alignment: .leading) {
                    Rectangle().fill(rule)
                    if progress.total > 0 {
                        Rectangle().fill(blue).frame(width: size.size.width * CGFloat(progress.done) / CGFloat(progress.total))
                    }
                }
            }.frame(height: 2)
            HStack(spacing: 10) {
                Button("A−") { state.set("noteSize.\(day)", max(12, state.size(for: day) - 1)) }
                    .help("缩小本页文字").accessibilityLabel("缩小本页文字")
                Text("\(Int(state.size(for: day))) pt").font(type(13)).foregroundStyle(dim)
                Button("A+") { state.set("noteSize.\(day)", min(28, state.size(for: day) + 1)) }
                    .help("放大本页文字").accessibilityLabel("放大本页文字")
                Spacer(minLength: 4)
                Picker("本页字色", selection: state.setting("noteInk.\(day)", state.inkIndex())) {
                    ForEach(PaperSwatch.ink.indices, id: \.self) { index in
                        Text(PaperSwatch.ink[index].name).tag(index)
                    }
                }.labelsHidden().fixedSize().buttonStyle(.bordered).controlSize(.small).help("本页字色")
            }.padding(8).overlay(Rectangle().strokeBorder(rule, lineWidth: 1))
            editorReveal
        }.padding(.horizontal, 18).padding(.vertical, 18)
    }

    private var editorReveal: some View {
        GeometryReader { geometry in
            let motion = state.value("archiveMotion", "typewriter")
            let byLine = motion == "line"
            let fade = motion == "fade"
            ArchiveEditor(attach: attachEditor)
                .mask(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: geometry.size.width * (byLine || fade ? 1 : reveal),
                               height: geometry.size.height * (byLine ? reveal : 1))
                        .opacity(fade ? reveal : 1)
                }
                .overlay(alignment: .topLeading) {
                    if showRail {
                        Rectangle().fill(ink.opacity(0.28)).frame(height: 1)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(blue).frame(width: 16, height: 4)
                                    .offset(x: max(0, (geometry.size.width - 16) * reveal))
                            }.padding(.top, 6)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        }
    }

    private func animateDetail() {
        animationTask?.cancel()
        let motion = state.value("archiveMotion", "typewriter")
        guard state.selectedDay != nil, !reduceMotion, motion != "none" else {
            reveal = 1
            showRail = false
            return
        }
        let duration = state.value("archiveDuration", 0.38)
        reveal = 0
        showRail = motion == "typewriter"
        animationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.22, 0.76, 0.30, 1, duration: duration)) { reveal = 1 }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.13)) { showRail = false }
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("设置").font(noteFont(23)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: openSticky) {
                        Label("桌面便签", systemImage: "rectangle.trailingthird.inset.filled")
                            .font(noteFont(12))
                            .foregroundStyle(dim)
                            .frame(minHeight: 26)
                            .contentShape(Rectangle())
                    }
                }
                PaperSample(look: state.look(night: state.night), showsMechanism: true,
                            strikeTrial: strikeTrial)
                    .frame(height: 82).overlay(Rectangle().strokeBorder(rule, lineWidth: 1))
                    .accessibilityHidden(true)
                picker("打字机造型", key: "mechanismStyle", fallback: MechanismStyle.signal.rawValue,
                       MechanismStyle.allCases.map { ($0.title, $0.rawValue) })
                HStack {
                    Toggle("机械打字声", isOn: state.setting("sound", true)).toggleStyle(.switch).controlSize(.small)
                    Spacer(minLength: 4)
                    Button("试敲") {
                        if state.value("sound", true) { state.style.play() }
                        strikeTrial += 1
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                section("光线与纸张")
                picker("主题", key: "theme", fallback: "system", [
                    ("跟随系统", "system"), ("白天", "day"), ("夜间", "night"),
                ])
                Toggle("桌面便签透明玻璃", isOn: state.setting("glassEnabled", false))
                    .toggleStyle(.switch).controlSize(.small)
                slider("背景模糊", key: "glassBlur", fallback: ArchiveState.defaultGlassBlur,
                       range: 0...1, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
                    .disabled(!state.glassEnabled)
                swatches("纸色", key: "paperTint", PaperSwatch.paper)
                Toggle("夜间开灯", isOn: state.setting("lamp", true)).toggleStyle(.switch).controlSize(.small)
                swatches("灯光颜色", key: "lampTint", PaperSwatch.light)
                slider("灯光强度", key: "lampIntensity", fallback: 1, range: 0...1, step: 0.01) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                slider("灯光范围", key: "lampRange", fallback: 1, range: 0.45...1.65, step: 0.05) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                section("字体与油墨")
                picker("字体", key: "paperFont",
                       fallback: state.value("originalFont", false) ? "ipa" : "print", [
                    ("纸间印刷", "print"), ("IPA 明朝", "ipa"), ("系统字体", "system"),
                ])
                slider("字号", key: "fontSize", fallback: 19, range: 12...28, step: 1) { "\(Int($0)) pt" }
                slider("行间距", key: "lineSpacing", fallback: 0, range: 0...24, step: 1) {
                    "\(Int($0)) pt"
                }
                swatches("字色", key: "ink", PaperSwatch.ink)
                section("展开动效")
                picker("样式", key: "archiveMotion", fallback: "typewriter", [
                    ("打字机", "typewriter"), ("沿线展开", "line"), ("淡入", "fade"), ("关闭", "none"),
                ])
                slider("时长", key: "archiveDuration", fallback: 0.38, range: 0.18...0.8, step: 0.01) {
                    "\(Int(($0 * 1_000).rounded())) ms"
                }.disabled(state.value("archiveMotion", "typewriter") == "none")
            }.padding(.horizontal, 15).padding(.vertical, 18)
                .background(PaperScrollStyle(axis: .vertical, night: state.night))
        }
    }

    private func section(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(rule).frame(height: 1)
            Text(title).font(noteFont(16)).accessibilityAddTraits(.isHeader)
        }
    }

    private func picker(_ label: String, key: String, fallback: String, _ choices: [(String, String)]) -> some View {
        HStack {
            Text(label).foregroundStyle(dim)
            Spacer()
            Picker(label, selection: state.setting(key, fallback)) {
                ForEach(choices, id: \.1) { title, value in Text(title).tag(value) }
            }.labelsHidden().fixedSize().buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func swatches(_ label: String, key: String, _ colors: [PaperSwatch]) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(dim)
            Spacer(minLength: 2)
            ForEach(colors.indices, id: \.self) { index in
                let selected = state.value(key, 0) == index
                Button { state.set(key, index) } label: {
                    Rectangle().fill(Color(nsColor: colors[index].color(night: state.night)))
                        .padding(3)
                        .frame(width: 19, height: 19)
                        .overlay(Rectangle().strokeBorder(selected ? blue : rule, lineWidth: 1))
                }.accessibilityLabel("\(label) · \(colors[index].name)")
                    .accessibilityAddTraits(selected ? .isSelected : []).help(colors[index].name)
            }
        }
    }

    private func slider(_ label: String, key: String, fallback: Double, range: ClosedRange<Double>, step: Double,
                        units: (Double) -> String) -> some View {
        HStack(spacing: 7) {
            Text(label).foregroundStyle(dim)
            PaperSlider(label: label, value: state.setting(key, fallback), range: range, step: step,
                        night: state.night)
                .frame(maxWidth: .infinity).frame(height: 18)
            Text(units(state.value(key, fallback))).font(type(11)).foregroundStyle(dim)
                .frame(width: 43, alignment: .trailing).accessibilityHidden(true)
        }
    }
}

private struct ArchiveYearButton: NSViewRepresentable {
    let title: String
    let style: PaperStyle
    let ink: NSColor
    let open: (NSButton) -> Void

    func makeNSView(context: Context) -> NSButton {
        let view = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.showWheel(_:)))
        view.isBordered = false
        view.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        view.imagePosition = .imageTrailing
        return view
    }

    func updateNSView(_ view: NSButton, context: Context) {
        context.coordinator.open = open
        view.attributedTitle = style.text(title, size: 14, ink: ink)
        view.setAccessibilityLabel("选择年份，\(title)")
        view.contentTintColor = ink
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var open: ((NSButton) -> Void)?
        @objc func showWheel(_ sender: NSButton) { open?(sender) }
    }
}

private struct ArchiveEditor: NSViewRepresentable {
    let attach: (PaperSurface) -> Void

    func makeNSView(context: Context) -> PaperSurface {
        let view = PaperSurface()
        view.paintsSurface = false
        attach(view)
        return view
    }

    func updateNSView(_ view: PaperSurface, context: Context) {}
}

private struct PaperSample: NSViewRepresentable {
    let look: PaperLook
    var showsMechanism = false
    var strikeTrial = 0
    var onCreate: ((PaperSurface) -> Void)?

    func makeNSView(context: Context) -> Sample {
        let view = Sample()
        view.softGrain = true
        view.lastTrial = strikeTrial
        view.document.isHidden = !showsMechanism
        if showsMechanism { view.onResize = { [weak view] in view?.refresh() } }
        onCreate?(view)
        return view
    }

    func updateNSView(_ view: Sample, context: Context) {
        look.apply(to: view)
        guard showsMechanism else { return }
        view.document.night = look.night
        view.document.lampLevel = look.lamp ? 1 : 0
        view.document.mechanismStyle = look.mechanismStyle
        view.refresh()
        if view.lastTrial != strikeTrial {
            view.lastTrial = strikeTrial
            view.strike()
        }
    }

    final class Sample: PaperSurface {
        let document = PaperDocument()
        let mechanism = PaperMechanism()
        var lastTrial = 0
        private var strikeTimer: Timer?

        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(document)
            document.addSubview(mechanism)
            mechanism.document = document
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        deinit { strikeTimer?.invalidate() }

        func strike() {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            strikeTimer?.invalidate()
            let start = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let elapsed = CACurrentMediaTime() - start
                self.document.thrust = PaperDocument.strikeTravel(at: elapsed)
                self.mechanism.needsDisplay = true
                if elapsed >= PaperDocument.strikeDuration { timer.invalidate() }
            }
            strikeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        func refresh() {
            document.frame = bounds
            mechanism.frame = document.bounds
            let previewLineY: CGFloat = document.mechanismStyle == .signal ? 35 : 40
            document.point = CGPoint(x: bounds.midX, y: previewLineY)
            lampOrigin = document.lightSource.map { convert($0, from: document) }
            mechanism.needsDisplay = true
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

private struct OrbitMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addEllipse(in: CGRect(x: rect.width * 0.29, y: rect.height * 0.14,
                                       width: rect.height * 0.61, height: rect.height * 0.61))
            path.move(to: CGPoint(x: 0, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        }
    }
}
