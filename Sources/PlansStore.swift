import Foundation

struct PlanRow: Codable, Equatable, Identifiable {
    var id = UUID()
    var text = ""
    var done = false
    var parentID: UUID? = nil
    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct MonthSummary {
    var recordedDays: Set<Int> = []
    var total = 0
    var done = 0
    var completed: [(day: String, text: String)] = []

    var days: Int { recordedDays.count }
    var completion: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

extension Array where Element == PlanRow {
    var committedRows: [PlanRow] { filter { $0.parentID == nil || $0.hasText } }

    private func endOfChildren(of index: Int) -> Int {
        let parent = self[index].id
        return indices.dropFirst(index + 1).first { self[$0].parentID != parent } ?? endIndex
    }

    func taskBlock(at index: Int) -> Range<Int> {
        index..<(self[index].parentID == nil ? endOfChildren(of: index) : index + 1)
    }

    func reorderSlots(for index: Int) -> [Int] {
        if let parent = self[index].parentID {
            guard let root = firstIndex(where: { $0.id == parent }) else { return [] }
            return Array<Int>((root + 1)...endOfChildren(of: root))
        }
        return indices.filter { self[$0].parentID == nil } + [endIndex]
    }

    mutating func moveTask(at index: Int, to slot: Int) -> Bool {
        guard indices.contains(index), reorderSlots(for: index).contains(slot) else { return false }
        let block = taskBlock(at: index)
        guard slot < block.lowerBound || slot > block.upperBound else { return false }
        let moved = Array(self[block])
        removeSubrange(block)
        insert(contentsOf: moved, at: slot > block.upperBound ? slot - moved.count : slot)
        return true
    }

    mutating func addChild(at index: Int) -> UUID {
        let parent = self[index].parentID ?? self[index].id
        let root = firstIndex { $0.id == parent } ?? index
        let child = PlanRow(parentID: self[root].id)
        insert(child, at: endOfChildren(of: root))
        return child.id
    }

    mutating func indentRow(at index: Int) -> Bool {
        guard self[index].parentID == nil, endOfChildren(of: index) == index + 1,
              let previous = self[..<index].last(where: { $0.parentID == nil }), previous.hasText else { return false }
        self[index].parentID = previous.id
        return true
    }

    mutating func outdentRow(at index: Int) -> Bool {
        guard let parent = self[index].parentID, let root = firstIndex(where: { $0.id == parent }) else { return false }
        let end = endOfChildren(of: root)
        var row = remove(at: index)
        row.parentID = nil
        insert(row, at: end - 1)
        return true
    }

    mutating func splitRow(at index: Int, selection: NSRange) -> UUID? {
        let text = self[index].text as NSString
        let parent = self[index].parentID
        let leading = text.substring(to: selection.location)
        guard parent == nil || !leading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self[index].text = leading
        let next = PlanRow(text: text.substring(from: NSMaxRange(selection)), parentID: parent)
        let insertion = parent == nil ? endOfChildren(of: index) : index + 1
        insert(next, at: insertion)
        return next.id
    }

    mutating func mergeRow(at index: Int) -> (id: UUID, offset: Int) {
        let previous = self[..<index].lastIndex { $0.parentID == nil }!
        let target = self[previous].id
        let offset = self[previous].text.utf16.count
        let removed = remove(at: index)
        self[previous].text += removed.text
        for child in index..<endIndex where self[child].parentID == removed.id {
            self[child].parentID = target
        }
        return (target, offset)
    }
}

final class PlansStore {
    let file: URL
    private var plans: [String: [PlanRow]] = [:]
    private(set) var loadError: Error?

    init(file: URL) {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                plans = try JSONDecoder().decode([String: [PlanRow]].self, from: Data(contentsOf: file))
            } catch {
                loadError = error
            }
        }
    }

    var days: [String] { plans.keys.sorted(by: >) }

    func rows(for day: String) -> [PlanRow] {
        let saved = plans[day]?.committedRows ?? []
        return saved.isEmpty ? [PlanRow()] : saved
    }

    func progress(for day: String) -> TaskProgress {
        var progress = TaskProgress()
        for row in plans[day] ?? [] where row.hasText {
            progress.total += 1
            if row.done { progress.done += 1 }
        }
        return progress
    }

    func summary(year: Int, month: Int) -> MonthSummary {
        let prefix = String(format: "%04d-%02d-", year, month)
        var result = MonthSummary()
        for day in days where day.hasPrefix(prefix) {
            let written = (plans[day] ?? []).filter(\.hasText)
            guard !written.isEmpty, let date = Int(day.dropFirst(prefix.count)) else { continue }
            result.recordedDays.insert(date)
            result.total += written.count
            for row in written where row.done {
                result.done += 1
                if result.completed.count < 5 { result.completed.append((day, row.text)) }
            }
        }
        return result
    }

    func save(_ rows: [PlanRow], for day: String) throws {
        if let loadError { throw loadError }
        var updated = plans
        updated[day] = rows.contains(where: \.hasText) ? rows.committedRows : nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(updated).write(to: file, options: .atomic)
        plans = updated
    }

    static func day(for date: Date = Date(), calendar: Calendar = .init(identifier: .gregorian)) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func date(for day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
