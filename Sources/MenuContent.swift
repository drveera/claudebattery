import SwiftUI
import ServiceManagement

struct MenuContent: View {
    @EnvironmentObject var monitor: UsageMonitor
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            stats
            Divider()
            budgetPicker
            Divider()
            actions
        }
        .frame(width: 300)  // frame owns the full width; padding lives inside each section
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
                Text("\(Int(monitor.percentageRemaining * 100))% remaining")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Progress bar — ProgressView avoids GeometryReader's greedy sizing
            ProgressView(value: monitor.percentageRemaining)
                .tint(batteryColor)
                .animation(.easeInOut(duration: 0.3), value: monitor.percentageRemaining)
                .padding(.vertical, 4)

            // Cost (primary — used for battery %)
            statRow(label: "API cost",
                    value: "\(monitor.costUsed.formatted(.currency(code: "USD"))) / \(monitor.costLimit.formatted(.currency(code: "USD")))")

            // Raw tokens (secondary — for reference)
            statRow(label: "Tokens (in+out)",
                    value: monitor.tokensUsed.formatted())

            statRow(label: "Resets in",
                    value: monitor.timeUntilReset)

            if let updated = monitor.lastUpdated {
                statRow(label: "Updated",
                        value: updated.formatted(date: .omitted, time: .shortened))
            }
        }
        .padding(.horizontal, 12)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var actions: some View {
        VStack(spacing: 6) {
            Toggle(isOn: $launchAtLogin) {
                Label("Launch at Login", systemImage: "power")
                    .font(.callout)
            }
            .toggleStyle(.switch)
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
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
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
