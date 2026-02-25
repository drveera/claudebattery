import SwiftUI
import ServiceManagement

struct MenuContent: View {
    @EnvironmentObject var monitor: UsageMonitor
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stats
            if !monitor.usingOAuth {
                Divider()
                budgetPicker
            }
            Divider()
            actions
        }
        // Each section fills its own width; the outer padding is the sole source of margins.
        .padding(14)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: batteryIcon)
                .foregroundColor(batteryColor)
                .font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text("ClaudeBattery")
                    .font(.headline)
                HStack(spacing: 4) {
                    Text("\(Int(monitor.percentageRemaining * 100))% remaining")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let plan = monitor.subscriptionType {
                        Text("• \(formattedPlan(plan))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: monitor.percentageRemaining)
                .tint(batteryColor)
                .animation(.easeInOut(duration: 0.3), value: monitor.percentageRemaining)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)

            if monitor.usingOAuth {
                statRow(label: "5h usage",
                        value: "\(Int(monitor.fiveHourUtilization ?? 0))% used")
                if let sevenDay = monitor.sevenDayUtilization {
                    statRow(label: "7d usage",
                            value: "\(Int(sevenDay))% used")
                }
            } else {
                statRow(label: "API cost",
                        value: "\(monitor.costUsed.formatted(.currency(code: "USD"))) / \(monitor.costLimit.formatted(.currency(code: "USD")))")
                statRow(label: "Tokens (in+out)",
                        value: monitor.tokensUsed.formatted())
            }

            statRow(label: "Resets in",
                    value: monitor.timeUntilReset)

            if let updated = monitor.lastUpdated {
                statRow(label: "Updated",
                        value: updated.formatted(date: .omitted, time: .shortened))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var budgetPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("5h budget (API-equivalent)")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: $monitor.costLimit) {
                Text("Pro (~$5)").tag(5.0 as Double)
                Text("Max 5× (~$25)").tag(25.0 as Double)
                Text("Max 20× (~$100)").tag(100.0 as Double)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $launchAtLogin) {
                Label("Launch at Login", systemImage: "power")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: launchAtLogin) { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = !enabled
                }
            }

            HStack {
                Button {
                    monitor.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "xmark.circle")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .font(.callout)
            Spacer()
            Text(value)
                .font(.callout)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
    }

    private func formattedPlan(_ type: String) -> String {
        switch type.lowercased() {
        case "pro", "claude_pro":           return "Pro"
        case "max_5", "claude_max_5":       return "Max 5×"
        case "max_20", "claude_max_20":     return "Max 20×"
        case "max", "claude_max":           return "Max"
        default:                            return type
        }
    }

    private var batteryIcon: String {
        switch monitor.percentageRemaining {
        case 0.75...: return "battery.100"
        case 0.50...: return "battery.75"
        case 0.25...: return "battery.50"
        case 0.10...: return "battery.25"
        default:      return "battery.0"
        }
    }

    private var batteryColor: Color {
        switch monitor.percentageRemaining {
        case 0.25...: return .green
        case 0.10...: return .orange
        default:      return .red
        }
    }
}

// MARK: - Menu bar label

struct BatteryLabel: View {
    let percentage: Double

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .foregroundColor(color)
                .imageScale(.medium)
            Text("\(Int(percentage * 100))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
    }

    private var icon: String {
        switch percentage {
        case 0.75...: return "battery.100"
        case 0.50...: return "battery.75"
        case 0.25...: return "battery.50"
        case 0.10...: return "battery.25"
        default:      return "battery.0"
        }
    }

    private var color: Color {
        switch percentage {
        case 0.25...: return .green
        case 0.10...: return .orange
        default:      return .red
        }
    }
}
