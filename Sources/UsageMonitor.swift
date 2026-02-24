import Foundation
import Combine
import Security

class UsageMonitor: ObservableObject {

    // MARK: - Published state

    @Published var tokensUsed: Int = 0        // raw input+output tokens (JSONL fallback)
    @Published var costUsed: Double = 0.0     // USD cost equivalent (JSONL fallback)
    @Published var costLimit: Double {        // user-set budget per 5h window in USD
        didSet { UserDefaults.standard.set(costLimit, forKey: "costLimit") }
    }
    @Published var resetAt: Date? = nil
    @Published var lastUpdated: Date? = nil

    // OAuth-sourced data
    @Published var fiveHourUtilization: Double? = nil  // 0–100 from API
    @Published var sevenDayUtilization: Double? = nil  // 0–100 from API
    @Published var sevenDayResetsAt: Date? = nil
    @Published var subscriptionType: String? = nil
    @Published var usingOAuth: Bool = false

    // MARK: - Derived

    var percentageRemaining: Double {
        if let util = fiveHourUtilization {
            return max(0.0, min(1.0, 1.0 - util / 100.0))
        }
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
        let cacheWrite5mPerM: Double
        let cacheWrite1hPerM: Double
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
        self.costLimit = stored > 0 ? stored : 5.0

        refresh()

        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    // MARK: - Keychain

    private struct OAuthCredential {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let subscriptionType: String?
    }

    private func readKeychainCredential() -> OAuthCredential? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken  = oauth["accessToken"]  as? String,
              let refreshToken = oauth["refreshToken"] as? String
        else { return nil }

        // expiresAt may be Unix milliseconds (JS Date.now()) or seconds
        let expiresAtRaw = oauth["expiresAt"] as? Double ?? 0
        let expiresAt = expiresAtRaw > 1e10
            ? Date(timeIntervalSince1970: expiresAtRaw / 1000.0)
            : Date(timeIntervalSince1970: expiresAtRaw)

        let subscriptionType = oauth["subscriptionType"] as? String
        return OAuthCredential(accessToken: accessToken,
                               refreshToken: refreshToken,
                               expiresAt: expiresAt,
                               subscriptionType: subscriptionType)
    }

    // MARK: - OAuth API

    private func fetchOAuthUsage(token: String, subscriptionType: String?,
                                  completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let fiveHour = json["five_hour"] as? [String: Any],
                let utilization = fiveHour["utilization"] as? Double
            else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let resetDate = self.parseDate(fiveHour["resets_at"] as? String)

            var sevenDayUtil: Double? = nil
            var sevenDayReset: Date? = nil
            if let sevenDay = json["seven_day"] as? [String: Any] {
                sevenDayUtil  = sevenDay["utilization"] as? Double
                sevenDayReset = self.parseDate(sevenDay["resets_at"] as? String)
            }

            DispatchQueue.main.async {
                self.fiveHourUtilization = utilization
                self.resetAt             = resetDate
                self.sevenDayUtilization = sevenDayUtil
                self.sevenDayResetsAt    = sevenDayReset
                self.subscriptionType    = subscriptionType
                self.usingOAuth          = true
                self.lastUpdated         = Date()
                completion(true)
            }
        }.resume()
    }

    private func parseDate(_ str: String?) -> Date? {
        guard let str else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: str) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: str)
    }

    // MARK: - Refresh

    func refresh() {
        // Try OAuth first; fall back to local JSONL if unavailable or expired
        if let credential = readKeychainCredential(),
           credential.expiresAt.timeIntervalSinceNow > -60 {
            fetchOAuthUsage(token: credential.accessToken,
                            subscriptionType: credential.subscriptionType) { [weak self] success in
                if !success { self?.refreshFromJSONL() }
            }
        } else {
            refreshFromJSONL()
        }
    }

    private func refreshFromJSONL() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let entries = self.loadEntries()
            let (tokens, cost, reset) = self.calculateCurrentBlock(entries: entries)
            DispatchQueue.main.async {
                self.tokensUsed  = tokens
                self.costUsed    = cost
                self.resetAt     = reset
                self.usingOAuth  = false
                self.lastUpdated = Date()
            }
        }
    }

    // MARK: - JSONL parsing

    private struct Entry {
        let timestamp: Date
        let tokens: Int
        let cost: Double
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

            let input      = usage["input_tokens"]                as? Int ?? 0
            let output     = usage["output_tokens"]               as? Int ?? 0
            let cacheTotal = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead  = usage["cache_read_input_tokens"]     as? Int ?? 0

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
