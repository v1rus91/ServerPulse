import SwiftUI
import AppKit

@MainActor
final class AppState {
    static let shared = AppState()
    let monitor = Monitor()
    private var settingsWindow: NSWindow?

    private var dashboardWindow: NSWindow?
    func openDashboard() {
        if dashboardWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.contentViewController = NSHostingController(rootView: DashboardView().environment(monitor))
            w.title = "ServerPulse"; w.titlebarAppearsTransparent = true; w.isReleasedWhenClosed = false; w.center()
            dashboardWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environment(monitor)))
            w.title = L("Налаштування ServerPulse"); w.styleMask = [.titled, .closable]; w.isReleasedWhenClosed = false; w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct ServerPulseApp: App {
    private let state = AppState.shared
    private var monitor: Monitor { state.monitor }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environment(monitor)
        } label: {
            menuLabel
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder private var menuLabel: some View {
        let level = monitor.overall
        let cpu = monitor.servers.filter(\.enabled).compactMap { monitor.snapshots[$0.id]?.cpuPercent }.max()
        HStack(spacing: 4) {
            Image(systemName: level == .ok ? "waveform.path.ecg" : (level == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
            if Prefs.showCPUInBar, let cpu { Text(verbatim: String(format: "%.0f%%", cpu)) }
            if !monitor.openAlerts.isEmpty { Text(verbatim: "·\(monitor.openAlerts.count)") }
        }
    }
}
