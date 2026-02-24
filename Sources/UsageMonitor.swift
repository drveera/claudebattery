import Foundation
import Combine

class UsageMonitor: ObservableObject {

    // MARK: - Published state

    @Published var tokensUsed: Int = 0
    @Published var tokenLimit: Int {
        didSet { UserDefaults.standard.set(tokenLimit, forKey: "tokenLimit") }
    }
    @Published var resetAt: Date? = nil
    @Published var lastUpdated: Date? = nil

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Derived

    var percentageRemaining: Double {
        let limit = max(1, tokenLimit)
        return max(0.0, min(1.0, Double(limit - tokensUsed) / Double(limit)))
    }

    var percentageUsed: Double { 1.0 - percentageRemaining }

    var timeUntilReset: String {
        guard let resetAt else { return "—" }
        let remaining = resetAt.timeIntervalSinceNow
        guard remaining > 0 else { return "Resetting soon" }
        let hours   = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    // MARK: - Init

    init() {
        let stored = UserDefaults.standard.integer(forKey: "tokenLimit")
        self.tokenLimit = stored > 0 ? stored : 8_000

        refresh()

        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    // MARK: - Refresh

    func refresh() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let entries = self.loadTokenEntries()
            let (used, reset) = self.calculateCurrentBlock(entries: entries)
            DispatchQueue.main.async {
                self.tokensUsed   = used
                self.resetAt      = reset
                self.lastUpdated  = Date()
            }
        }
    }

    // MARK: - JSONL parsing

    private struct TokenEntry {
        let timestamp: Date
        let tokens: Int
    }

    private func loadTokenEntries() -> [TokenEntry] {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let enumerator = FileManager.default.enumerator(
            at: claudeDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var entries: [TokenEntry] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            entries.append(contentsOf: parseJSONL(at: fileURL, formatter: formatter))
        }

        return entries.sorted { $0.timestamp < $1.timestamp }
    }

    private func parseJSONL(at url: URL, formatter: ISO8601DateFormatter) -> [TokenEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var entries: [TokenEntry] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let data  = line.data(using: .utf8),
                let obj   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type  = obj["type"] as? String, type == "assistant",
                let tsStr = obj["timestamp"] as? String,
                let ts    = formatter.date(from: tsStr),
                let msg   = obj["message"] as? [String: Any],
                let usage = msg["usage"] as? [String: Any]
            else { continue }

            let input  = usage["input_tokens"]  as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let total  = input + output
            if total > 0 {
                entries.append(TokenEntry(timestamp: ts, tokens: total))
            }
        }
        return entries
    }

    // MARK: - 5-hour window calculation

    /// Groups messages into blocks separated by gaps > 5 hours.
    /// The "current block" is the last group. If its 5-hour window has
    /// already expired, returns (0, nil) — the user is in a reset gap.
    private func calculateCurrentBlock(entries: [TokenEntry]) -> (tokensUsed: Int, resetAt: Date?) {
        guard !entries.isEmpty else { return (0, nil) }

        let fiveHours: TimeInterval = 5 * 60 * 60

        // Build blocks: new block when gap between consecutive messages > 5h
        var blocks: [[TokenEntry]] = []
        var current: [TokenEntry] = [entries[0]]

        for i in 1..<entries.count {
            let gap = entries[i].timestamp.timeIntervalSince(entries[i - 1].timestamp)
            if gap > fiveHours {
                blocks.append(current)
                current = [entries[i]]
            } else {
                current.append(entries[i])
            }
        }
        blocks.append(current)

        guard let lastBlock = blocks.last, let first = lastBlock.first else {
            return (0, nil)
        }

        let blockEnd = first.timestamp.addingTimeInterval(fiveHours)

        // If the window has already expired, show 0 — no active usage
        if blockEnd < Date() {
            return (0, nil)
        }

        let tokensUsed = lastBlock.reduce(0) { $0 + $1.tokens }
        return (tokensUsed, blockEnd)
    }
}
