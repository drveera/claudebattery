import Foundation
import Combine

class UsageMonitor: ObservableObject {

    // MARK: - Published state

    @Published var tokensUsed: Int = 0        // raw input+output tokens (display only)
    @Published var costUsed: Double = 0.0     // USD cost equivalent (used for battery %)
    @Published var costLimit: Double {        // user-set budget per 5h window in USD
        didSet { UserDefaults.standard.set(costLimit, forKey: "costLimit") }
    }
    @Published var resetAt: Date? = nil
    @Published var lastUpdated: Date? = nil

    // MARK: - Derived

    var percentageRemaining: Double {
        let limit = max(0.000001, costLimit)
        return max(0.0, min(1.0, (limit - costUsed) / limit))
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

    // MARK: - Model pricing

    struct ModelPricing {
        let inputPerM: Double
        let outputPerM: Double
        let cacheWrite5mPerM: Double   // 5-minute ephemeral cache write
        let cacheWrite1hPerM: Double   // 1-hour ephemeral cache write
        let cacheReadPerM: Double

        func cost(input: Int, output: Int,
                  cacheWrite5m: Int, cacheWrite1h: Int,
                  cacheRead: Int) -> Double {
            let M = 1_000_000.0
            return (Double(input)        * inputPerM        +
                    Double(output)       * outputPerM       +
                    Double(cacheWrite5m) * cacheWrite5mPerM +
                    Double(cacheWrite1h) * cacheWrite1hPerM +
                    Double(cacheRead)    * cacheReadPerM) / M
        }
    }

    // Pricing table — ordered from most to least specific prefix.
    // Rates as of early 2026; update if Anthropic changes prices.
    private static let pricingTable: [(prefix: String, pricing: ModelPricing)] = [
        // Claude Opus 4.6 / 4.5 — newer, cheaper than Opus 4.1
        ("claude-opus-4-6",   ModelPricing(inputPerM: 5,    outputPerM: 25,   cacheWrite5mPerM: 6.25,  cacheWrite1hPerM: 10,    cacheReadPerM: 0.50)),
        ("claude-opus-4-5",   ModelPricing(inputPerM: 5,    outputPerM: 25,   cacheWrite5mPerM: 6.25,  cacheWrite1hPerM: 10,    cacheReadPerM: 0.50)),
        // Claude Opus 4.1 / 4 — older, expensive
        ("claude-opus-4",     ModelPricing(inputPerM: 15,   outputPerM: 75,   cacheWrite5mPerM: 18.75, cacheWrite1hPerM: 30,    cacheReadPerM: 1.50)),
        // Claude Sonnet 4.x
        ("claude-sonnet-4",   ModelPricing(inputPerM: 3,    outputPerM: 15,   cacheWrite5mPerM: 3.75,  cacheWrite1hPerM: 6,     cacheReadPerM: 0.30)),
        // Claude Haiku 4.5+
        ("claude-haiku-4",    ModelPricing(inputPerM: 1,    outputPerM: 5,    cacheWrite5mPerM: 1.25,  cacheWrite1hPerM: 2,     cacheReadPerM: 0.10)),
        // Claude 3.5 Sonnet
        ("claude-3-5-sonnet", ModelPricing(inputPerM: 3,    outputPerM: 15,   cacheWrite5mPerM: 3.75,  cacheWrite1hPerM: 3.75,  cacheReadPerM: 0.30)),
        // Claude 3.5 Haiku
        ("claude-3-5-haiku",  ModelPricing(inputPerM: 0.80, outputPerM: 4,    cacheWrite5mPerM: 1.00,  cacheWrite1hPerM: 1.00,  cacheReadPerM: 0.08)),
        // Claude 3 Opus
        ("claude-3-opus",     ModelPricing(inputPerM: 15,   outputPerM: 75,   cacheWrite5mPerM: 18.75, cacheWrite1hPerM: 18.75, cacheReadPerM: 1.50)),
        // Claude 3 Haiku
        ("claude-3-haiku",    ModelPricing(inputPerM: 0.25, outputPerM: 1.25, cacheWrite5mPerM: 0.30,  cacheWrite1hPerM: 0.30,  cacheReadPerM: 0.03)),
    ]

    static func pricingFor(model: String) -> ModelPricing {
        for (prefix, p) in pricingTable where model.hasPrefix(prefix) { return p }
        // Unknown model — fall back to Sonnet 4 rates
        return ModelPricing(inputPerM: 3, outputPerM: 15,
                            cacheWrite5mPerM: 3.75, cacheWrite1hPerM: 6,
                            cacheReadPerM: 0.30)
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        let stored = UserDefaults.standard.double(forKey: "costLimit")
        self.costLimit = stored > 0 ? stored : 5.0  // default ≈ Pro plan budget

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
            let entries = self.loadEntries()
            let (tokens, cost, reset) = self.calculateCurrentBlock(entries: entries)
            DispatchQueue.main.async {
                self.tokensUsed  = tokens
                self.costUsed    = cost
                self.resetAt     = reset
                self.lastUpdated = Date()
            }
        }
    }

    // MARK: - JSONL parsing

    private struct Entry {
        let timestamp: Date
        let tokens: Int     // raw input + output (for display)
        let cost: Double    // USD cost (for battery %)
    }

    private func loadEntries() -> [Entry] {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let enumerator = FileManager.default.enumerator(
            at: claudeDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var entries: [Entry] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            entries.append(contentsOf: parseJSONL(at: fileURL, formatter: formatter))
        }
        return entries.sorted { $0.timestamp < $1.timestamp }
    }

    private func parseJSONL(at url: URL, formatter: ISO8601DateFormatter) -> [Entry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var entries: [Entry] = []
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

            let model  = msg["model"] as? String ?? ""
            let p      = UsageMonitor.pricingFor(model: model)

            let input      = usage["input_tokens"]              as? Int ?? 0
            let output     = usage["output_tokens"]             as? Int ?? 0
            let cacheTotal = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead  = usage["cache_read_input_tokens"]   as? Int ?? 0

            // Use the per-duration breakdown when available; fall back to 5m rate for the total
            let breakdown = usage["cache_creation"] as? [String: Any]
            let cache5m   = breakdown?["ephemeral_5m_input_tokens"] as? Int ?? cacheTotal
            let cache1h   = breakdown?["ephemeral_1h_input_tokens"] as? Int ?? 0

            let tokens = input + output
            let cost   = p.cost(input: input, output: output,
                                cacheWrite5m: cache5m, cacheWrite1h: cache1h,
                                cacheRead: cacheRead)

            if tokens > 0 || cost > 0 {
                entries.append(Entry(timestamp: ts, tokens: tokens, cost: cost))
            }
        }
        return entries
    }

    // MARK: - 5-hour window calculation

    private func calculateCurrentBlock(entries: [Entry]) -> (tokens: Int, cost: Double, resetAt: Date?) {
        guard !entries.isEmpty else { return (0, 0, nil) }

        let fiveHours: TimeInterval = 5 * 60 * 60
        var blocks: [[Entry]] = []
        var current: [Entry] = [entries[0]]

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
            return (0, 0, nil)
        }

        let blockEnd = first.timestamp.addingTimeInterval(fiveHours)
        if blockEnd < Date() { return (0, 0, nil) }

        let tokens = lastBlock.reduce(0) { $0 + $1.tokens }
        let cost   = lastBlock.reduce(0.0) { $0 + $1.cost }
        return (tokens, cost, blockEnd)
    }
}
