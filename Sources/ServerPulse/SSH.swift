import Foundation

/// Виконання команд через системний ssh з ControlMaster (одне зʼєднання на сервер, швидкі повторні запити).
enum SSH {
    static let controlDir: String = {
        let d = NSHomeDirectory() + "/.ssh/sp-cm"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()

    static func args(for s: Server, timeout: Int = 8) -> [String] {
        var a = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(timeout)", "-o", "StrictHostKeyChecking=accept-new",
                 "-o", "ControlMaster=auto", "-o", "ControlPath=\(controlDir)/%r@%h:%p", "-o", "ControlPersist=180",
                 "-o", "ServerAliveInterval=15", "-o", "LogLevel=ERROR"]
        if s.port != 22 { a += ["-p", String(s.port)] }
        if !s.keyPath.isEmpty { a += ["-i", (s.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        a.append(s.sshTarget)
        return a
    }

    /// Запускає команду; stdin — необовʼязковий скрипт. Повертає (stdout, stderr, код, тривалість).
    static func run(_ s: Server, command: String, stdin: String? = nil, timeout: Double = 25) -> (String, String, Int32, Double) {
        let start = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args(for: s) + [command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        do { try p.run() } catch { return ("", error.localizedDescription, -1, 0) }
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inp.fileHandleForWriting.close()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate() }
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self), p.terminationStatus, Date().timeIntervalSince(start))
    }

    /// Скрипт-збирач: один прохід — усі метрики, секції розділені ###.
    static func collector(services: [String], withDockerStats: Bool) -> String {
        let svc = services.map { $0.replacingOccurrences(of: "'", with: "") }.joined(separator: " ")
        return """
        echo "###cpu0"; head -1 /proc/stat
        echo "###net0"; tail -n +3 /proc/net/dev
        sleep 1
        echo "###host"; hostname; grep -E "^PRETTY_NAME" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"'; uname -r
        echo "###uptime"; cut -d' ' -f1 /proc/uptime
        echo "###load"; cat /proc/loadavg; nproc
        echo "###cpu"; head -1 /proc/stat
        echo "###mem"; grep -E "^(MemTotal|MemAvailable|SwapTotal|SwapFree)" /proc/meminfo
        echo "###disk"; df -P -B1 -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null | tail -n +2
        echo "###net"; tail -n +3 /proc/net/dev
        echo "###temp"; cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -1
        echo "###procs"; ps -eo pid,%cpu,%mem,args --sort=-%cpu 2>/dev/null | head -9 | tail -n +2 | grep -v " ps -eo" | cut -c1-110
        echo "###docker"; docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}|{{.Image}}' 2>/dev/null
        echo "###dockerstats"; \(withDockerStats ? "timeout 8 docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null" : "true")
        echo "###services"; for s in \(svc); do printf "%s|%s\\n" "$s" "$(systemctl is-active "$s" 2>/dev/null)"; done
        echo "###updates"; grep -oE "^[0-9]+" /var/lib/update-notifier/updates-available 2>/dev/null | head -1; [ -f /var/run/reboot-required ] && echo REBOOT
        echo "###who"; who 2>/dev/null | wc -l
        echo "###log"; (journalctl -n 40 --no-pager -o short-iso -p warning 2>/dev/null || tail -n 40 /var/log/syslog 2>/dev/null)
        echo "###end"
        """
    }

    /// Розбір виводу збирача у Snapshot. `previous` потрібен для CPU% і швидкості мережі.
    static func parse(_ out: String, previous: Snapshot?, elapsed: Double, filter: String) -> Snapshot {
        var s = Snapshot()
        var sections: [String: [String]] = [:]
        var cur = ""
        for line in out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("###") { cur = String(line.dropFirst(3)); sections[cur] = []; continue }
            sections[cur, default: []].append(line)
        }
        guard sections["end"] != nil else { s.reachable = false; s.error = L("Неповна відповідь від сервера"); return s }
        let host = sections["host"] ?? []
        let realHost = host.first ?? ""; s.hostname = Prefs.anonymize ? "" : realHost; s.os = host.count > 1 ? host[1] : ""; s.kernel = host.count > 2 ? host[2] : ""
        s.uptime = Double((sections["uptime"]?.first ?? "0").trimmingCharacters(in: .whitespaces)) ?? 0
        if let l = sections["load"]?.first?.split(separator: " "), l.count >= 3 { s.load1 = Double(l[0]) ?? 0; s.load5 = Double(l[1]) ?? 0; s.load15 = Double(l[2]) ?? 0 }
        s.cores = Int((sections["load"] ?? []).dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? "1") ?? 1
        if let c = sections["cpu"]?.first?.split(separator: " ").dropFirst().compactMap({ Double($0) }), c.count >= 4 {
            s.cpuTotal = c.reduce(0, +); s.cpuIdle = c[3] + (c.count > 4 ? c[4] : 0)
            if let p = previous, p.cpuTotal > 0, s.cpuTotal > p.cpuTotal {
                let dt = s.cpuTotal - p.cpuTotal, di = s.cpuIdle - p.cpuIdle
                s.cpuPercent = max(0, min(100, (dt - di) / dt * 100))
            } else if let c0 = sections["cpu0"]?.first?.split(separator: " ").dropFirst().compactMap({ Double($0) }), c0.count >= 4 {
                let t0 = c0.reduce(0, +), i0 = c0[3] + (c0.count > 4 ? c0[4] : 0)
                let dt = s.cpuTotal - t0, di = s.cpuIdle - i0
                if dt > 0 { s.cpuPercent = max(0, min(100, (dt - di) / dt * 100)) }
            }
        }
        for line in sections["mem"] ?? [] {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let v = Double(parts[1]) else { continue }
            let kb = v * 1024
            switch parts[0] { case "MemTotal:": s.memTotal = kb; case "MemAvailable:": s.memAvailable = kb; case "SwapTotal:": s.swapTotal = kb; case "SwapFree:": s.swapFree = kb; default: break }
        }
        for line in sections["disk"] ?? [] {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 6, let total = Double(p[1]), let used = Double(p[2]), total > 0 else { continue }
            s.disks.append(DiskInfo(device: String(p[0]), mount: String(p[5]), total: total, used: used))
        }
        func netTotals(_ lines: [String]) -> (Double, Double) {
            var rx = 0.0, tx = 0.0
            for line in lines {
                let p = line.replacingOccurrences(of: ":", with: " ").split(separator: " ", omittingEmptySubsequences: true)
                guard p.count >= 10, let r = Double(p[1]), let t = Double(p[9]) else { continue }
                let name = String(p[0])
                if name == "lo" || name.hasPrefix("veth") || name.hasPrefix("br-") || name.hasPrefix("docker") { continue }
                rx += r; tx += t
            }
            return (rx, tx)
        }
        (s.netRx, s.netTx) = netTotals(sections["net"] ?? [])
        if let p = previous, elapsed > 0, s.netRx >= p.netRx, s.netTx >= p.netTx {
            s.rxRate = (s.netRx - p.netRx) / elapsed; s.txRate = (s.netTx - p.netTx) / elapsed
        } else if let n0 = sections["net0"] {
            let (r0, t0) = netTotals(n0)
            if s.netRx >= r0, s.netTx >= t0 { s.rxRate = s.netRx - r0; s.txRate = s.netTx - t0 }   // за 1 с
        }
        if let t = sections["temp"]?.first, let v = Double(t.trimmingCharacters(in: .whitespaces)) { s.temp = v > 1000 ? v / 1000 : v }
        for line in sections["procs"] ?? [] {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 4, let pid = Int(p[0]), let cpu = Double(p[1]), let mem = Double(p[2]) else { continue }
            s.procs.append(ProcInfo(pid: pid, name: p[3...].joined(separator: " "), cpu: cpu, mem: mem))
        }
        var stats: [String: (Double, String)] = [:]
        for line in sections["dockerstats"] ?? [] {
            let p = line.split(separator: "|").map(String.init)
            guard p.count >= 3 else { continue }
            stats[p[0]] = (Double(p[1].replacingOccurrences(of: "%", with: "")) ?? 0, p[2].components(separatedBy: " / ").first ?? p[2])
        }
        for line in sections["docker"] ?? [] {
            let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 4 else { continue }
            var c = ContainerInfo(name: p[0], state: p[1], status: p[2], image: p[3])
            if let st = stats[p[0]] { c.cpu = st.0; c.mem = st.1 } else if let prev = previous?.containers.first(where: { $0.name == p[0] }) { c.cpu = prev.cpu; c.mem = prev.mem }
            s.containers.append(c)
        }
        for line in sections["services"] ?? [] {
            let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 2, !p[0].isEmpty else { continue }
            s.services.append(ServiceInfo(name: p[0], active: p[1] == "active"))
        }
        for line in sections["updates"] ?? [] {
            if line == "REBOOT" { s.rebootRequired = true } else if let n = Int(line.trimmingCharacters(in: .whitespaces)) { s.updates = n }
        }
        s.users = Int((sections["who"]?.first ?? "0").trimmingCharacters(in: .whitespaces)) ?? 0
        let filters = filter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        s.log = (sections["log"] ?? []).filter { l in !l.isEmpty && !l.hasPrefix("-- ") && !filters.contains { l.contains($0) } }.suffix(15).map { line in
            // прибираємо hostname для компактності
            var l = line
            if !realHost.isEmpty, let r = l.range(of: " " + realHost + " ") { l.removeSubrange(r.lowerBound..<r.upperBound); l.insert(" ", at: r.lowerBound) }
            return l
        }
        return s
    }

    /// Хости з ~/.ssh/config для імпорту.
    static func configHosts() -> [Server] {
        guard let text = try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8) else { return [] }
        var result: [Server] = []
        var cur: Server? = nil
        func flush() { if let c = cur, !c.host.isEmpty, !c.name.contains("*") { result.append(c) }; cur = nil }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), val = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "host":
                flush()
                let names = val.split(separator: " ").map(String.init)
                if names.count == 1, !names[0].contains("*"), !names[0].contains("?") { cur = Server(name: names[0], host: names[0], port: 22, user: "") }
            case "hostname": cur?.notes = val            // реальний хост показуємо в нотатках
            case "port": cur?.port = Int(val) ?? 22
            case "user": cur?.user = val
            case "identityfile": cur?.keyPath = val
            default: break
            }
        }
        flush()
        return result
    }
}
