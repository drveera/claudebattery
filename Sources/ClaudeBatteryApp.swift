import SwiftUI

@main
struct ClaudeBatteryApp: App {
    @StateObject private var monitor = UsageMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(monitor)
        } label: {
            BatteryLabel(percentage: monitor.percentageRemaining)
        }
        .menuBarExtraStyle(.window)
    }
}
