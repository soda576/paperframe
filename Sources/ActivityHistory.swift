import Foundation

struct TaskProgress: Equatable {
    var total = 0
    var done = 0

    var percent: Int { total == 0 ? 0 : Int((Double(done) * 100 / Double(total)).rounded()) }
    var level: Int {
        if total == 0 { return 0 }
        if done == 0 { return 1 }
        if done == total { return 5 }
        return 2 + min(2, Int(Double(done) * 3 / Double(total)))
    }

    mutating func add(_ progress: Self) {
        total += progress.total
        done += progress.done
    }
}

struct ActivityCell: Identifiable {
    let start: Date
    let end: Date
    let progress: TaskProgress
    var dayKey: String?
    var id: Date { start }
}

struct ActivityHistory {
    struct Week: Identifiable {
        let days: [ActivityCell?]
        let period: ActivityCell
        let monthLabel: Date?
        var id: Date { period.start }
    }

    let weeks: [Week]
    let months: [ActivityCell]

    init(store: PlansStore, through month: Date, calendar: Calendar) {
        let current = calendar.dateInterval(of: .month, for: month)!
        let monthStarts = (-11...0).compactMap { offset -> Date? in
            guard let date = calendar.date(byAdding: .month, value: offset, to: current.start),
                  calendar.component(.era, from: date) == 1 else { return nil }
            return date
        }
        let first = monthStarts.first ?? current.start
        var weekStart = calendar.dateInterval(of: .weekOfYear, for: first)!.start
        var weeks: [Week] = []
        var monthProgress: [Date: TaskProgress] = [:]

        while weekStart < current.end {
            var progress = TaskProgress()
            var monthLabel: Date?
            let days: [ActivityCell?] = (0..<7).map { index in
                let day = calendar.date(byAdding: .day, value: index, to: weekStart)!
                guard day >= first, day < current.end else { return nil }
                let key = PlansStore.day(for: day, calendar: calendar)
                let daily = store.progress(for: key)
                progress.add(daily)
                let month = calendar.dateInterval(of: .month, for: day)!.start
                monthProgress[month, default: TaskProgress()].add(daily)
                if day == month { monthLabel = month }
                return ActivityCell(start: day, end: day, progress: daily, dayKey: key)
            }
            let present = days.compactMap { $0 }
            let period = ActivityCell(start: present.first!.start, end: present.last!.end, progress: progress)
            weeks.append(Week(days: days, period: period, monthLabel: monthLabel))
            weekStart = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        }
        self.weeks = weeks
        months = monthStarts.map { firstDay in
            let lastDay = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: firstDay)!
            return ActivityCell(start: firstDay, end: lastDay, progress: monthProgress[firstDay] ?? TaskProgress())
        }
    }
}
