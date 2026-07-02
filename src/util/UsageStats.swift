struct UsageStats {
    private static let defaults = UserDefaults(suiteName: "\(App.bundleIdentifier).usage")!
    private static let writeQueue = DispatchQueue(label: "UsageStats.writeQueue", qos: .utility)
    private static let maxAge: TimeInterval = 365 * 24 * 3600
    private static let allKeys = ["triggers"]

    static func recordTrigger(_ shortcutIndex: Int) {
        record("triggers")
    }

    static func count(_ key: String, since date: Date) -> Int {
        let threshold = Int(date.timeIntervalSince1970)
        return getTimestamps(key).count { $0 >= threshold }
    }

    static var triggerCount: Int { count("triggers", since: Date.distantPast) }

    static func prune() {
        let cutoff = Int(Date().timeIntervalSince1970 - maxAge)
        writeQueue.async {
            for key in allKeys {
                let timestamps = getTimestamps(key)
                guard !timestamps.isEmpty else { continue }
                let pruned = timestamps.filter { $0 >= cutoff }
                defaults.set(pruned, forKey: key)
            }
        }
    }

    private static func record(_ key: String) {
        let now = Int(Date().timeIntervalSince1970)
        writeQueue.async {
            var timestamps = getTimestamps(key)
            timestamps.append(now)
            defaults.set(timestamps, forKey: key)
        }
    }

    private static func getTimestamps(_ key: String) -> [Int] {
        defaults.array(forKey: key) as? [Int] ?? []
    }
}
