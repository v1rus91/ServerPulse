import Foundation
import Observation
import AppKit
import UserNotifications

/// Опитує сервери, зберігає історію, генерує сповіщення.
@MainActor
@Observable
final class Monitor {
    var servers: [Server] = []
    var snapshots: [UUID: Snapshot] = [:]
    var history: [UUID: [Point]] = [:]
    var alerts: [AlertEvent] = []
    var polling: Set<UUID> = []
    var paused = false
    var lastPoll: Date? = nil
    var toast: String? = nil
    private var timer: Timer?
    private var pollCount = 0
    private var toastJob: Task<Void, Never>?
    private var breachCount: [String: Int] = [:]   // "serverId:kind" → кількість поспіль

    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ServerPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    var overall: Snapshot.Level {
        servers.filter(\.enabled).map { snapshots[$0.id]?.level ?? .down }.max() ?? .ok
    }
    var openAlerts: [AlertEvent] { alerts.filter { !$0.resolved } }

    init() {
        load()
        requestNotifications()
        restart()
    }

    // MARK: цикл
    func restart() {
        timer?.invalidate()
        let interval = Double(max(10, Prefs.interval))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollAll() } }
        pollAll()
    }

    func pollAll() {
        guard !paused else { return }
        pollCount += 1
        for s in servers where s.enabled { poll(s) }
    }

    func poll(_ s: Server, force: Bool = false) {
        guard !polling.contains(s.id) else { return }
        polling.insert(s.id)
        let previous = snapshots[s.id]
        let withStats = force || pollCount % max(1, Prefs.dockerStatsEvery) == 0
        let script = SSH.collector(services: s.services, withDockerStats: withStats)
        let elapsed = previous.map { Date().timeIntervalSince($0.date) } ?? 0
        let filter = s.logFilter
        Task.detached {
            let (out, err, code, rtt) = SSH.run(s, command: "bash -s", stdin: script, timeout: 40)
            var snap: Snapshot
            if code == 0 || out.contains("###end") {
                snap = SSH.parse(out, previous: previous, elapsed: elapsed, filter: filter)
            } else {
                snap = Snapshot(); snap.reachable = false
                snap.error = err.split(separator: "\n").last.map(String.init) ?? L("Немає зʼєднання (код %d)", code)
            }
            snap.rtt = rtt
            let final = snap; await MainActor.run { self.apply(final, to: s) }
        }
    }

    private func apply(_ snap: Snapshot, to s: Server) {
        polling.remove(s.id)
        let previous = snapshots[s.id]
        snapshots[s.id] = snap
        lastPoll = Date()
        if snap.reachable {
            var pts = history[s.id] ?? []
            pts.append(Point(t: snap.date, cpu: snap.cpuPercent ?? previous?.cpuPercent ?? 0, mem: snap.memPercent, rx: snap.rxRate ?? 0, tx: snap.txRate ?? 0, load: snap.load1))
            let cutoff = Date().addingTimeInterval(-Double(max(1, Prefs.historyHours)) * 3600)
            pts.removeAll { $0.t < cutoff }
            history[s.id] = pts
        }
        evaluateAlerts(s, snap, previous: previous)
        updateBadge()
        scheduleSave()
    }

    // MARK: сповіщення
    private func evaluateAlerts(_ s: Server, _ snap: Snapshot, previous: Snapshot?) {
        func check(_ kind: String, _ condition: Bool, needed: Int = 2, message: @autoclosure () -> String) {
            let key = "\(s.id):\(kind)"
            if condition {
                breachCount[key, default: 0] += 1
                if breachCount[key] == needed { raise(s, kind: kind, message: message()) }
            } else {
                if (breachCount[key] ?? 0) >= needed { resolve(s, kind: kind) }
                breachCount[key] = 0
            }
        }
        check("down", !snap.reachable, needed: 2, message: L("Сервер недоступний: %@", snap.error ?? ""))
        guard snap.reachable else { return }
        if let cpu = snap.cpuPercent { check("cpu", cpu > Double(Prefs.cpuWarn), message: L("CPU %.0f%% (поріг %d%%)", cpu, Prefs.cpuWarn)) }
        check("mem", snap.memPercent > Double(Prefs.memWarn), message: L("Памʼять %.0f%% (поріг %d%%)", snap.memPercent, Prefs.memWarn))
        for d in snap.disks { check("disk:\(d.mount)", d.percent > Double(Prefs.diskWarn), needed: 1, message: L("Диск %@ заповнено на %.0f%%", d.mount, d.percent)) }
        for svc in snap.services { check("service:\(svc.name)", !svc.active, needed: 1, message: L("Сервіс %@ не працює", svc.name)) }
        for c in snap.containers where c.state != "exited" || previous?.containers.first(where: { $0.name == c.name })?.state == "running" {
            check("container:\(c.name)", !c.healthy, needed: 1, message: L("Контейнер %@: %@", c.name, c.status))
        }
        if let p = previous, p.reachable, p.containers.count > 0, snap.containers.isEmpty {
            raise(s, kind: "containers-gone", message: L("Усі контейнери зникли (було %d)", p.containers.count))
        }
        if let p = previous, p.reachable, snap.uptime < p.uptime - 30 { raise(s, kind: "reboot", message: L("Сервер перезавантажився")) }
        check("reboot-required", snap.rebootRequired, needed: 1, message: L("Потрібне перезавантаження після оновлень"))
    }

    private func raise(_ s: Server, kind: String, message: String) {
        if let i = alerts.firstIndex(where: { $0.serverId == s.id && $0.kind == kind && !$0.resolved }) { alerts[i].message = message; return }
        let a = AlertEvent(serverId: s.id, serverName: s.name, kind: kind, message: message)
        alerts.insert(a, at: 0)
        if alerts.count > 200 { alerts.removeLast(alerts.count - 200) }
        if Prefs.sound { NSSound(named: "Basso")?.play() }
        if Prefs.notify, Bundle.main.bundleIdentifier != nil {
            let c = UNMutableNotificationContent(); c.title = "\(s.name): \(L("увага"))"; c.body = message
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: a.id.uuidString, content: c, trigger: nil))
        }
    }

    private func resolve(_ s: Server, kind: String) {
        for i in alerts.indices where alerts[i].serverId == s.id && alerts[i].kind == kind && !alerts[i].resolved { alerts[i].resolved = true }
    }

    func clearAlerts() { alerts.removeAll(); scheduleSave() }
    func acknowledge(_ a: AlertEvent) { if let i = alerts.firstIndex(of: a) { alerts[i].resolved = true; scheduleSave() } }

    private func requestNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func updateBadge() {
        let n = openAlerts.count
        NSApp.dockTile.badgeLabel = (Prefs.showBadge && n > 0) ? String(n) : nil
    }

    // MARK: дії на сервері
    func run(_ s: Server, command: String, completion: @escaping (String) -> Void) {
        Task.detached {
            let (out, err, code, _) = SSH.run(s, command: command, timeout: 60)
            let text = (out + (err.isEmpty ? "" : "\n" + err)).trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run { completion(text.isEmpty ? (code == 0 ? L("Готово") : L("Помилка (код %d)", code)) : text); self.poll(s, force: true) }
        }
    }

    func openTerminal(_ s: Server) {
        var cmd = "ssh"
        if s.port != 22 { cmd += " -p \(s.port)" }
        if !s.keyPath.isEmpty { cmd += " -i \(s.keyPath)" }
        cmd += " \(s.sshTarget)"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd)\"\nend tell"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    func showToast(_ t: String) {
        toastJob?.cancel(); toast = t
        toastJob = Task { try? await Task.sleep(for: .seconds(2.2)); if !Task.isCancelled { toast = nil } }
    }

    // MARK: сервери
    func add(_ s: Server) { servers.append(s); scheduleSave(); poll(s, force: true) }
    func update(_ s: Server) { if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s; scheduleSave(); poll(s, force: true) } }
    func remove(_ s: Server) { servers.removeAll { $0.id == s.id }; snapshots[s.id] = nil; history[s.id] = nil; scheduleSave() }
    func move(from: IndexSet, to: Int) { servers.move(fromOffsets: from, toOffset: to); scheduleSave() }

    func importFromSSHConfig() -> Int {
        var n = 0
        for var s in SSH.configHosts() where !servers.contains(where: { $0.host == s.host }) {
            s.color = Pin.palette[servers.count % Pin.palette.count]
            servers.append(s); n += 1
        }
        scheduleSave(); pollAll()
        return n
    }

    // MARK: збереження
    private var saveJob: Task<Void, Never>?
    private func scheduleSave() {
        saveJob?.cancel()
        saveJob = Task { [weak self] in try? await Task.sleep(for: .milliseconds(500)); if !Task.isCancelled { self?.save() } }
    }
    func saveNow() { saveJob?.cancel(); save() }
    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        try? enc.encode(servers).write(to: Self.dir.appendingPathComponent("servers.json"))
        try? enc.encode(alerts).write(to: Self.dir.appendingPathComponent("alerts.json"))
        try? enc.encode(history.mapValues { Array($0.suffix(2000)) }).write(to: Self.dir.appendingPathComponent("history.json"))
    }
    private func load() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        if let d = try? Data(contentsOf: Self.dir.appendingPathComponent("servers.json")), let s = try? dec.decode([Server].self, from: d) { servers = s }
        if let d = try? Data(contentsOf: Self.dir.appendingPathComponent("alerts.json")), let a = try? dec.decode([AlertEvent].self, from: d) { alerts = a }
        if let d = try? Data(contentsOf: Self.dir.appendingPathComponent("history.json")), let h = try? dec.decode([UUID: [Point]].self, from: d) { history = h }
    }
}
