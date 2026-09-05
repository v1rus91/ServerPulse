import SwiftUI

Prefs.register()
if CommandLine.arguments.contains("--probe") {
    // Перевірка збору метрик без UI: імпортує хости з ~/.ssh/config і опитує кожен двічі.
    let hosts = SSH.configHosts()
    print("hosts from ~/.ssh/config: \(hosts.map(\.name))")
    for h in hosts {
        var prev: Snapshot? = nil
        for i in 0..<2 {
            let t0 = Date()
            let (out, err, code, rtt) = SSH.run(h, command: SSH.collector(services: h.services, withDockerStats: i == 1), timeout: 30)
            guard code == 0 else { print("\(h.name): FAIL code \(code) \(err.suffix(200))"); break }
            let s = SSH.parse(out, previous: prev, elapsed: prev.map { t0.timeIntervalSince($0.date) } ?? 0, filter: h.logFilter)
            print(String(format: "%@ #%d rtt=%.2fs cpu=%@ mem=%.0f%% load=%.2f/%d disks=%d net=%@/%@ docker=%d svc=%@ upd=%d log=%d", h.name, i, rtt, s.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "-", s.memPercent, s.load1, s.cores, s.disks.count, Fmt.rate(s.rxRate), Fmt.rate(s.txRate), s.containers.count, s.services.map { "\($0.name)=\($0.active)" }.joined(separator: ","), s.updates, s.log.count))
            for c in s.containers { print("   ▸ \(c.name) \(c.state) \(c.status) cpu=\(c.cpu ?? -1) mem=\(c.mem ?? "-")") }
            prev = s
            if i == 0 { sleep(3) }
        }
    }
    exit(0)
}
MainActor.assumeIsolated {
    _ = AppState.shared
    if CommandLine.arguments.contains("--import") { let n = AppState.shared.monitor.importFromSSHConfig(); AppState.shared.monitor.saveNow(); print("imported \(n)"); exit(0) }
    if CommandLine.arguments.contains("--dashboard") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { AppState.shared.openDashboard() } }
    if CommandLine.arguments.contains("--settings") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { AppState.shared.openSettings() } }
}
ServerPulseApp.main()
