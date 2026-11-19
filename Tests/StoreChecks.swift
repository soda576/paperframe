import Foundation

@main
struct StoreChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlansStore(file: root.appendingPathComponent("plans.json"))
        let today = "2026-11-18"
        let tomorrow = "2026-11-19"
        var rows = store.rows(for: today)
        precondition(rows.count == 1 && rows[0].text.isEmpty)
        rows[0].text = "今天写 report 📝"
        let next = rows.splitRow(at: 0, selection: NSRange(location: 3, length: 0))
        precondition(rows.map(\.text) == ["今天写", " report 📝"])
        precondition(rows[1].id == next)
        let merged = rows.mergeRow(at: 1)
        precondition(merged.id == rows[0].id && merged.offset == 3 && rows[0].text == "今天写 report 📝")
        rows[0].done = true
        try store.save(rows, for: today)
        try store.save([PlanRow(text: "明天读书")], for: tomorrow)
        let reopened = PlansStore(file: store.file)
        let legacyJSON = try String(contentsOf: store.file, encoding: .utf8)
        precondition(!legacyJSON.contains("parentID") && reopened.rows(for: today).first?.parentID == nil)
        precondition(reopened.days == [tomorrow, today])
        precondition(reopened.rows(for: today) == rows)
        precondition(reopened.rows(for: tomorrow).first?.text == "明天读书")
        precondition(reopened.rows(for: "2026-11-20").first?.text == "")
        rows[0].done = false
        try reopened.save(rows, for: today)
        precondition(PlansStore(file: store.file).rows(for: today).first?.done == false)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        let leapDay = PlansStore.date(for: "2024-02-29", calendar: calendar)!
        precondition(PlansStore.day(for: leapDay, calendar: calendar) == "2024-02-29")
        let older = "2026-10-31"
        try reopened.save([PlanRow(text: "上月任务", done: true)], for: older)
        let rowsForHistory = [PlanRow(text: "补记旧任务", done: true), PlanRow(text: "未完成"), PlanRow(text: " ")]
        try reopened.save(rowsForHistory, for: today)
        let november = reopened.summary(year: 2026, month: 11)
        precondition(november.days == 2 && november.total == 3 && november.done == 1)
        precondition(november.recordedDays == [18, 19])
        precondition(abs(november.completion - 1.0 / 3) < 0.000001)
        precondition(november.completed.first?.text == "补记旧任务")
        precondition(reopened.summary(year: 2026, month: 10).done == 1)
        precondition(reopened.summary(year: 2026, month: 10).completion == 1)
        let empty = reopened.summary(year: 2026, month: 12)
        precondition(empty.recordedDays.isEmpty && empty.completion == 0)
        let history = ActivityHistory(store: reopened, through: leapDay, calendar: calendar)
        precondition(history.months.count == 12)
        precondition(PlansStore.day(for: history.months.last!.end, calendar: calendar) == "2024-02-29")
        let activity = ActivityHistory(store: reopened, through: PlansStore.date(for: today, calendar: calendar)!,
                                       calendar: calendar)
        precondition(PlansStore.day(for: activity.months.first!.start, calendar: calendar) == "2025-12-01")
        precondition(activity.months.last!.progress == TaskProgress(total: 3, done: 1))
        let week = activity.weeks.first { $0.days.contains { $0?.dayKey == today } }!
        precondition(week.days[2]?.dayKey == today && week.days[3]?.dayKey == tomorrow)
        precondition(week.period.progress == TaskProgress(total: 3, done: 1))
        precondition(reopened.progress(for: tomorrow).level == 1)
        precondition(reopened.progress(for: today).level == 3)
        precondition(reopened.progress(for: older).level == 5)
        precondition(reopened.progress(for: "2026-11-20").level == 0)
        precondition(PlansStore(file: store.file).rows(for: today) == rowsForHistory)
        let nextDay = Date(timeIntervalSince1970: 1_794_931_200)
        precondition(PlansStore.day(for: nextDay, calendar: calendar) != PlansStore.day(for: nextDay.addingTimeInterval(-86400), calendar: calendar))
        let parent = PlanRow(text: "周报")
        let other = PlanRow(text: "整理桌面")
        let draft = PlanRow(parentID: parent.id)
        let spaces = PlanRow(text: "  \t", parentID: parent.id)
        let written = PlanRow(text: "核对数据", done: true, parentID: parent.id)
        let legacyOutline = [parent, draft, spaces, written, other]
        let legacyFile = root.appendingPathComponent("legacy-outline.json")
        let legacyData = try JSONEncoder().encode([today: legacyOutline])
        try legacyData.write(to: legacyFile)
        let legacyStore = PlansStore(file: legacyFile)
        precondition(legacyStore.rows(for: today) == [parent, written, other])
        let unchangedLegacyData = try Data(contentsOf: legacyFile)
        precondition(unchangedLegacyData == legacyData)
        try reopened.save(legacyOutline, for: today)
        precondition(PlansStore(file: store.file).rows(for: today) == [parent, written, other])

        var pending = legacyOutline
        precondition(pending.splitRow(at: 1, selection: NSRange(location: 0, length: 0)) == nil)
        precondition(pending.splitRow(at: 2, selection: NSRange(location: 2, length: 0)) == nil)
        precondition(pending == legacyOutline)
        var outline = [parent, other]
        let child = outline.addChild(at: 0)
        outline[1].text = "初稿📝"
        outline[1].done = true
        let sibling = outline.splitRow(at: 1, selection: NSRange(location: 2, length: 0))!
        precondition(outline.map(\.id) == [parent.id, child, sibling, other.id])
        precondition(outline.map(\.parentID) == [nil, parent.id, parent.id, nil])
        precondition(outline[2].text == "📝")
        precondition(outline.outdentRow(at: 1))
        precondition(outline.map(\.id) == [parent.id, sibling, child, other.id])
        precondition(outline.indentRow(at: 2))
        let newRoot = outline.splitRow(at: 0, selection: NSRange(location: 2, length: 0))!
        precondition(outline.map(\.id) == [parent.id, sibling, child, newRoot, other.id])
        let lastChild = outline.addChild(at: 3)
        outline[4].text = "发给组员"
        precondition(outline.mergeRow(at: 3).id == parent.id)
        precondition(outline[3].id == lastChild && outline[3].parentID == parent.id)
        try reopened.save(outline, for: today)
        let persisted = PlansStore(file: store.file)
        precondition(persisted.rows(for: today) == outline)
        precondition(persisted.progress(for: today) == TaskProgress(total: 5, done: 1))
        let otherChild = PlanRow(text: "分类文件", parentID: other.id)
        var reordered = [parent, written, PlanRow(text: "交稿", parentID: parent.id), other, otherChild]
        let beforeReorder = reordered
        precondition(!reordered.moveTask(at: 0, to: 1))
        precondition(!reordered.moveTask(at: 1, to: 4))
        precondition(!reordered.moveTask(at: 0, to: 3) && reordered == beforeReorder)
        precondition(reordered.moveTask(at: 0, to: 5))
        precondition(reordered == Array(beforeReorder.suffix(2)) + Array(beforeReorder.prefix(3)))
        precondition(reordered.moveTask(at: 4, to: 3))
        precondition(reordered[3] == beforeReorder[2] && reordered[4] == written)
        precondition(reordered.moveTask(at: 2, to: 0))
        precondition(reordered[0] == parent && reordered[3] == other)
        try persisted.save(reordered, for: today)
        precondition(PlansStore(file: store.file).rows(for: today) == reordered)
        print("Passed plan storage, UTF-16 editing, and daily, weekly and monthly completion checks.")
    }
}
