import Foundation
import SwiftUI

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
func L(_ key: String, _ args: CVarArg...) -> String { String(format: NSLocalizedString(key, comment: ""), arguments: args) }

// MARK: - Сервер

struct Server: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var host: String               // хост або аліас із ~/.ssh/config
    var port: Int = 22
    var user: String = "root"
    var keyPath: String = ""       // порожньо — ssh сам знайде (config / agent)
    var color: String = "blue"
    var enabled = true
    var services: [String] = ["docker", "ssh", "cron"]   // systemd-сервіси для перевірки
    var webURL: String = ""
    var tags: [String] = []
    var quickCommands: [QuickCommand] = []
    var logFilter: String = "UFW BLOCK"                   // рядки, які ховати з логу
    var notes: String = ""

    var sshTarget: String { user.isEmpty ? host : "\(user)@\(host)" }
    var nsColor: NSColor { Pin.color(color) }

    static let sample: [Server] = []
}

struct QuickCommand: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var command: String
    var confirm = false
    var symbol = "terminal"
}

enum Pin {
    static let palette = ["red", "orange", "yellow", "green", "teal", "blue", "indigo", "purple", "pink", "gray"]
    static func color(_ name: String) -> NSColor {
        switch name {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "teal": return .systemTeal
        case "blue": return .systemBlue
        case "indigo": return .systemIndigo
        case "purple": return .systemPurple
        case "pink": return .systemPink
        default: return .systemGray
        }
    }
}

// MARK: - Знімок метрик

struct DiskInfo: Codable, Hashable, Identifiable {
    var id: String { mount }
    var device: String
    var mount: String
    var total: Double
    var used: Double
    var percent: Double { total > 0 ? used / total * 100 : 0 }
}

struct ProcInfo: Codable, Hashable, Identifiable {
    var id: Int { pid }
    var pid: Int
    var name: String
    var cpu: Double
    var mem: Double
}

struct ContainerInfo: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var state: String      // running / exited / restarting
    var status: String     // Up 2 days (healthy)
    var image: String
    var cpu: Double? = nil
    var mem: String? = nil
    var healthy: Bool { state == "running" && !status.lowercased().contains("unhealthy") }
}

struct ServiceInfo: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var active: Bool
}

struct Snapshot: Codable, Hashable {
    var date = Date()
    var reachable = true
    var error: String? = nil
    var rtt: Double = 0                    // час запиту, с
    var hostname = ""
    var os = ""
    var kernel = ""
    var uptime: Double = 0
    var load1 = 0.0, load5 = 0.0, load15 = 0.0
    var cores = 1
    var cpuTotal: Double = 0               // сирі лічильники /proc/stat для дельти
    var cpuIdle: Double = 0
    var cpuPercent: Double? = nil
    var memTotal: Double = 0, memAvailable: Double = 0, swapTotal: Double = 0, swapFree: Double = 0
    var disks: [DiskInfo] = []
    var netRx: Double = 0, netTx: Double = 0        // сумарні байти по фізичних інтерфейсах
    var rxRate: Double? = nil, txRate: Double? = nil // байт/с
    var temp: Double? = nil
    var procs: [ProcInfo] = []
    var containers: [ContainerInfo] = []
    var services: [ServiceInfo] = []
    var updates: Int = 0
    var rebootRequired = false
    var users = 0
    var log: [String] = []

    var memUsed: Double { max(0, memTotal - memAvailable) }
    var memPercent: Double { memTotal > 0 ? memUsed / memTotal * 100 : 0 }
    var swapPercent: Double { swapTotal > 0 ? (swapTotal - swapFree) / swapTotal * 100 : 0 }
    var loadPercent: Double { cores > 0 ? load1 / Double(cores) * 100 : 0 }

    /// Сукупний стан: ok / warn / down
    var level: Level {
        if !reachable { return .down }
        if containers.contains(where: { !$0.healthy && $0.state != "exited" }) || services.contains(where: { !$0.active }) { return .warn }
        if (cpuPercent ?? 0) > 90 || memPercent > 90 || disks.contains(where: { $0.percent > 90 }) { return .warn }
        return .ok
    }

    enum Level: Int, Comparable { case ok, warn, down
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var color: Color { switch self { case .ok: return .green; case .warn: return .orange; case .down: return .red } }
        var label: String { switch self { case .ok: return L("Усе добре"); case .warn: return L("Увага"); case .down: return L("Недоступний") } }
    }
}

/// Точка історії для графіків (компактна).
struct Point: Codable, Hashable {
    var t: Date
    var cpu: Double
    var mem: Double
    var rx: Double
    var tx: Double
    var load: Double
}

// MARK: - Сповіщення

struct AlertEvent: Identifiable, Codable, Hashable {
    var id = UUID()
    var date = Date()
    var serverId: UUID
    var serverName: String
    var kind: String            // cpu / mem / disk / service / container / down / updates / reboot
    var message: String
    var resolved = false
}

// MARK: - Форматування

enum Fmt {
    static func bytes(_ b: Double) -> String {
        let f = ByteCountFormatter(); f.countStyle = .memory; f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]; return f.string(fromByteCount: Int64(b))
    }
    static func rate(_ b: Double?) -> String { b.map { bytes($0) + "/s" } ?? "—" }
    static func uptime(_ s: Double) -> String {
        let d = Int(s) / 86400, h = (Int(s) % 86400) / 3600, m = (Int(s) % 3600) / 60
        if d > 0 { return L("%d д %d год", d, h) }
        if h > 0 { return L("%d год %d хв", h, m) }
        return L("%d хв", m)
    }
    static func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? "—" }
    static func ago(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 5 { return L("щойно") }
        if s < 60 { return L("%d с тому", Int(s)) }
        if s < 3600 { return L("%d хв тому", Int(s / 60)) }
        return L("%d год тому", Int(s / 3600))
    }
}

// MARK: - Налаштування

enum Prefs {
    /// --anonymize: ховає реальні hostname (для скріншотів)
    static let anonymize = CommandLine.arguments.contains("--anonymize")
    static let d = UserDefaults.standard
    static func register() {
        d.register(defaults: ["interval": 30, "cpuWarn": 85, "memWarn": 90, "diskWarn": 90, "notify": true, "sound": true,
                              "showCPUInBar": true, "showBadge": true, "launchAtLogin": false, "historyHours": 24, "dockerStatsEvery": 2, "language": "system"])
    }
    static var interval: Int { get { d.integer(forKey: "interval") } set { d.set(newValue, forKey: "interval") } }
    static var cpuWarn: Int { get { d.integer(forKey: "cpuWarn") } set { d.set(newValue, forKey: "cpuWarn") } }
    static var memWarn: Int { get { d.integer(forKey: "memWarn") } set { d.set(newValue, forKey: "memWarn") } }
    static var diskWarn: Int { get { d.integer(forKey: "diskWarn") } set { d.set(newValue, forKey: "diskWarn") } }
    static var notify: Bool { get { d.bool(forKey: "notify") } set { d.set(newValue, forKey: "notify") } }
    static var sound: Bool { get { d.bool(forKey: "sound") } set { d.set(newValue, forKey: "sound") } }
    static var showCPUInBar: Bool { get { d.bool(forKey: "showCPUInBar") } set { d.set(newValue, forKey: "showCPUInBar") } }
    static var showBadge: Bool { get { d.bool(forKey: "showBadge") } set { d.set(newValue, forKey: "showBadge") } }
    static var historyHours: Int { get { d.integer(forKey: "historyHours") } set { d.set(newValue, forKey: "historyHours") } }
    static var dockerStatsEvery: Int { get { d.integer(forKey: "dockerStatsEvery") } set { d.set(newValue, forKey: "dockerStatsEvery") } }
    static var onboarded: Bool { get { d.bool(forKey: "onboarded") } set { d.set(newValue, forKey: "onboarded") } }
    static var language: String { get { d.string(forKey: "language") ?? "system" } set { d.set(newValue, forKey: "language"); if newValue == "system" { d.removeObject(forKey: "AppleLanguages") } else { d.set([newValue], forKey: "AppleLanguages") } } }
}
