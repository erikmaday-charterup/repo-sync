import Foundation

enum RelativeTime {
    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "Never" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    static func until(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not scheduled" }
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "Due now" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        let hours = Int((Double(minutes) / 60).rounded())
        return "in \(hours) hr"
    }
}

extension String {
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
