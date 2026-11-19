import SwiftUI

enum ActivityMode: String, CaseIterable {
    case day = "每天"
    case week = "每周"
    case month = "每月"
}

struct ActivityHeatmap: View {
    let history: ActivityHistory
    let calendar: Calendar
    let night: Bool
    let textFont: Font
    let axisFont: Font
    @Binding var mode: ActivityMode
    let openDay: (ActivityCell) -> Void

    private let tileSize: CGFloat = 9
    private let gap: CGFloat = 3
    private let accent = Color(nsColor: PaperSwatch.rgb(0x306da7))
    private var dim: Color { Color(white: night ? 0.64 : 0.36) }
    private var levels: [Int] {
        night ? [0x2b2e34, 0xa8c5e1, 0x7eabd6, 0x568fc6, 0x3177b7, 0x0e508b]
              : [0xdce0e5, 0xc5ddf4, 0xa0c8ed, 0x70a9df, 0x3d7fbc, 0x144d83]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 0) {
                Text("记录节奏").font(textFont).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                ForEach(ActivityMode.allCases, id: \.self) { option in
                    Button {
                        mode = option
                    } label: {
                        Text(option.rawValue)
                            .font(axisFont)
                            .foregroundStyle(mode == option ? (night ? Color(white: 0.93) : accent) : dim)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .overlay(alignment: .bottom) {
                                if mode == option { Rectangle().fill(accent).frame(height: 1.5) }
                            }
                            .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(mode == option ? .isSelected : [])
                }
            }
            switch mode {
            case .day: dailyTimeline
            case .week: weekGrid
            case .month: monthGrid
            }
            HStack(spacing: 4) {
                Text(span).lineLimit(1)
                Spacer(minLength: 4)
                chip(0, size: 7)
                Text("无任务")
                Spacer(minLength: 3).frame(maxWidth: 6)
                Text("0%")
                ForEach(1...5, id: \.self) { chip($0, size: 7) }
                Text("100%")
            }
            .font(axisFont)
            .foregroundStyle(dim)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(span)，蓝色越深，完成率越高。灰色表示无任务。")
        }
    }

    private var dailyTimeline: some View {
        HStack(alignment: .top, spacing: 5) {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(Array(["一", "", "三", "", "五", "", "日"].enumerated()), id: \.offset) { _, day in
                    Text(day).font(axisFont).foregroundStyle(dim)
                        .frame(width: 13, height: tileSize, alignment: .leading)
                }
            }.accessibilityHidden(true)
            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(history.weeks) { week in
                            VStack(alignment: .leading, spacing: gap) {
                                ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                                    if let day { tile(day, size: tileSize) }
                                    else { Color.clear.frame(width: tileSize, height: tileSize) }
                                }
                                Color.clear.frame(width: tileSize, height: 15)
                                    .overlay(alignment: .bottomLeading) {
                                        if let month = week.monthLabel {
                                            Text("\(calendar.component(.month, from: month))月")
                                                .font(axisFont).foregroundStyle(dim)
                                                .fixedSize().accessibilityHidden(true)
                                        }
                                    }
                            }
                            .id(week.id)
                        }
                    }
                    .background(PaperScrollStyle(axis: .horizontal, night: night))
                }
                .onAppear { scrollToLatest(scroll) }
                .onChange(of: history.weeks.last?.id) { _ in scrollToLatest(scroll) }
            }
        }
    }

    private var weekGrid: some View {
        let columns = (history.weeks.count + 3) / 4
        let starts = columns > 0 ? Array(stride(from: 0, to: history.weeks.count, by: columns)) : []
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(starts, id: \.self) { start in
                let weeks = history.weeks[start..<min(start + columns, history.weeks.count)]
                let firstWeek = calendar.component(.weekOfYear, from: history.weeks[start].period.start)
                HStack(spacing: 4) {
                    Text(String(format: "W%02d", firstWeek))
                        .font(axisFont).foregroundStyle(dim)
                        .frame(width: 27, alignment: .leading).accessibilityHidden(true)
                    ForEach(weeks) { week in tile(week.period, size: 12) }
                }
            }
        }
    }

    private var monthGrid: some View {
        let starts = Array(stride(from: 0, to: history.months.count, by: 4))
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            ForEach(starts, id: \.self) { start in
                GridRow {
                    ForEach(history.months[start..<min(start + 4, history.months.count)]) { month in
                        HStack(spacing: 6) {
                            tile(month, size: 17)
                            Text("\(calendar.component(.month, from: month.start))月")
                                .font(axisFont).foregroundStyle(dim).accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var span: String {
        guard let first = history.months.first, let last = history.months.last else { return "" }
        func label(_ date: Date) -> String {
            "\(calendar.component(.year, from: date)).\(calendar.component(.month, from: date))"
        }
        return "\(label(first.start))–\(label(last.start))"
    }

    private func chip(_ level: Int, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(nsColor: PaperSwatch.rgb(levels[level])))
            .frame(width: size, height: size)
    }

    private func tile(_ cell: ActivityCell, size: CGFloat) -> some View {
        let content = chip(cell.progress.level, size: size)
        let description = tooltip(for: cell)
        return Group {
            if cell.dayKey != nil, cell.progress.total > 0 {
                Button { openDay(cell) } label: { content }
            } else {
                content.accessibilityElement(children: .ignore)
            }
        }
        .accessibilityLabel(description)
        .help(description)
    }

    private func tooltip(for cell: ActivityCell) -> String {
        let start = PlansStore.day(for: cell.start, calendar: calendar)
        let end = PlansStore.day(for: cell.end, calendar: calendar)
        let label: String
        switch mode {
        case .day: label = start
        case .week: label = "第 \(calendar.component(.weekOfYear, from: cell.start)) 周 · \(start) 至 \(end)"
        case .month: label = String(start.prefix(7))
        }
        let progress = cell.progress
        return "\(label)，" + (progress.total == 0 ? "无任务" : "完成 \(progress.done) / \(progress.total) 项（\(progress.percent)%）")
    }

    private func scrollToLatest(_ scroll: ScrollViewProxy) {
        if let last = history.weeks.last { scroll.scrollTo(last.id, anchor: .trailing) }
    }
}
