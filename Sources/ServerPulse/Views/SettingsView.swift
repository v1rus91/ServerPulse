import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(Monitor.self) private var monitor
    @State private var interval = Prefs.interval
    @State private var cpu = Prefs.cpuWarn
    @State private var mem = Prefs.memWarn
    @State private var disk = Prefs.diskWarn
    @State private var notify = Prefs.notify
    @State private var sound = Prefs.sound
    @State private var showCPU = Prefs.showCPUInBar
    @State private var badge = Prefs.showBadge
    @State private var hours = Prefs.historyHours
    @State private var statsEvery = Prefs.dockerStatsEvery
    @State private var launch = SMAppService.mainApp.status == .enabled
    @State private var language = Prefs.language
    @State private var needsRelaunch = false

    var body: some View {
        Form {
            Section("Опитування") {
                Picker("Інтервал", selection: $interval) { Text("10 с").tag(10); Text("15 с").tag(15); Text("30 с").tag(30); Text("60 с").tag(60); Text("5 хв").tag(300) }
                    .onChange(of: interval) { _, v in Prefs.interval = v; monitor.restart() }
                Stepper(value: $statsEvery, in: 1...10) { Text(verbatim: L("Docker stats кожне %d-е опитування", statsEvery)) }.onChange(of: statsEvery) { _, v in Prefs.dockerStatsEvery = v }
                Stepper(value: $hours, in: 1...168) { Text(verbatim: L("Зберігати історію: %d год", hours)) }.onChange(of: hours) { _, v in Prefs.historyHours = v }
                Text("Через ssh з ControlMaster: одне зʼєднання на сервер тримається відкритим, тож повторні опитування займають частки секунди. Без агентів на серверах.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Пороги сповіщень") {
                Stepper(value: $cpu, in: 50...100, step: 5) { Text(verbatim: L("CPU понад %d%% (два опитування поспіль)", cpu)) }.onChange(of: cpu) { _, v in Prefs.cpuWarn = v }
                Stepper(value: $mem, in: 50...100, step: 5) { Text(verbatim: L("Памʼять понад %d%%", mem)) }.onChange(of: mem) { _, v in Prefs.memWarn = v }
                Stepper(value: $disk, in: 50...100, step: 5) { Text(verbatim: L("Диск понад %d%%", disk)) }.onChange(of: disk) { _, v in Prefs.diskWarn = v }
                Text("Також завжди: недоступний сервер, неактивний сервіс, нездоровий контейнер, зникнення всіх контейнерів, несподіваний ребут, потреба ребуту після оновлень.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Сповіщення та вигляд") {
                Toggle("Системні сповіщення", isOn: $notify).onChange(of: notify) { _, v in Prefs.notify = v }
                Toggle("Звук при тривозі", isOn: $sound).onChange(of: sound) { _, v in Prefs.sound = v }
                Toggle("Показувати CPU у рядку меню", isOn: $showCPU).onChange(of: showCPU) { _, v in Prefs.showCPUInBar = v }
                Toggle("Лічильник тривог на іконці в Dock", isOn: $badge).onChange(of: badge) { _, v in Prefs.showBadge = v }
            }
            Section("Мова") {
                Picker("Мова інтерфейсу", selection: $language) { Text("Системна").tag("system"); Text(verbatim: "Українська").tag("uk"); Text(verbatim: "English").tag("en") }
                    .onChange(of: language) { _, v in Prefs.language = v; needsRelaunch = true }
                if needsRelaunch { HStack { Label("Щоб застосувати мову, перезапустіть ServerPulse", systemImage: "arrow.clockwise").foregroundStyle(.orange); Spacer(); Button("Перезапустити") { relaunch() }.glassButton(prominent: true) } }
            }
            Section("Система") {
                Toggle("Запускати при вході", isOn: $launch).onChange(of: launch) { _, v in
                    do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { launch = SMAppService.mainApp.status == .enabled }
                }
                Text("Дані зберігаються в ~/Library/Application Support/ServerPulse. Паролі не використовуються: лише SSH-ключі з ~/.ssh/config або агента.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped).frame(width: 560, height: 640)
    }

    private func relaunch() {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/sh"); task.arguments = ["-c", "sleep 0.6; open \"\(Bundle.main.bundleURL.path)\""]; try? task.run(); NSApp.terminate(nil)
    }
}
