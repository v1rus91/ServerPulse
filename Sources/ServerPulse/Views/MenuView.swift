import SwiftUI

/// Вміст вікна з рядка меню: картки серверів із ключовими метриками.
struct MenuView: View {
    @Environment(Monitor.self) private var monitor
    @State private var contentHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(spacing: 10) {
                    if monitor.servers.isEmpty { empty }
                    ForEach(monitor.servers.filter(\.enabled)) { s in ServerCard(server: s, compact: true) }
                    if !monitor.openAlerts.isEmpty { alertsBlock }
                }.padding(12)
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            .frame(height: min(640, max(120, contentHeight)))
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 440)
        .overlay(alignment: .top) {
            if let t = monitor.toast { Text(verbatim: t).font(.callout).padding(.horizontal, 14).padding(.vertical, 8).glassCard(999).padding(.top, 56).transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .animation(.spring(duration: 0.3), value: monitor.toast)
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(level: monitor.overall, size: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text("ServerPulse").font(.headline)
                Text(verbatim: monitor.lastPoll.map { L("Оновлено %@", Fmt.ago($0)) } ?? L("Ще не опитано")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !monitor.polling.isEmpty { ProgressView().controlSize(.small) }
            Button { monitor.pollAll() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Оновити зараз")
            Button { monitor.paused.toggle(); if !monitor.paused { monitor.pollAll() } } label: { Image(systemName: monitor.paused ? "play.circle" : "pause.circle") }.buttonStyle(.plain).foregroundStyle(.secondary).help(monitor.paused ? "Відновити" : "Призупинити")
            Button { AppState.shared.openDashboard() } label: { Image(systemName: "rectangle.3.group") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Дашборд")
            Button { AppState.shared.openSettings() } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Налаштування")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Серверів ще немає").font(.headline)
            Text("Імпортуйте хости з ~/.ssh/config або додайте вручну в Дашборді.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button { let n = monitor.importFromSSHConfig(); monitor.showToast(L("Імпортовано: %d", n)) } label: { Label("Імпортувати з ssh config", systemImage: "square.and.arrow.down") }.glassButton(prominent: true)
                Button { AppState.shared.openDashboard() } label: { Label("Додати вручну", systemImage: "plus") }.glassButton()
            }
        }.padding(.vertical, 30)
    }

    private var alertsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Label(L("Відкриті сповіщення: %d", monitor.openAlerts.count), systemImage: "bell.badge.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange); Spacer() }
            ForEach(monitor.openAlerts.prefix(4)) { a in
                HStack(spacing: 6) {
                    Text(verbatim: a.serverName).font(.caption.weight(.medium))
                    Text(verbatim: a.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { monitor.acknowledge(a) } label: { Image(systemName: "checkmark.circle") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Підтвердити")
                }
            }
        }.padding(12).glassCard(12, tint: .orange.opacity(0.15))
    }

    private var footer: some View {
        HStack {
            Text(verbatim: L("Кожні %d с", Prefs.interval)).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("Вийти") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).keyboardShortcut("q")
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Картка сервера: використовується і в меню (compact), і в дашборді.
struct ServerCard: View {
    let server: Server
    var compact = false
    @Environment(Monitor.self) private var monitor
    @State private var cmdOutput: String? = nil
    @State private var confirm: QuickCommand? = nil

    private var snap: Snapshot? { monitor.snapshots[server.id] }
    private var pts: [Point] { monitor.history[server.id] ?? [] }
    private var color: Color { Color(nsColor: server.nsColor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            head
            if let s = snap, s.reachable {
                metrics(s)
                if !s.disks.isEmpty { disks(s) }
                if !s.containers.isEmpty || !s.services.isEmpty { servicesRow(s) }
                if !compact { procs(s); if !s.log.isEmpty { logs(s) } }
                actions
            } else if let s = snap {
                Label(s.error ?? L("Недоступний"), systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.red)
                actions
            } else {
                HStack { ProgressView().controlSize(.small); Text("Опитування…").font(.callout).foregroundStyle(.secondary) }
            }
            if let out = cmdOutput {
                ScrollView { Text(verbatim: out).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140).padding(8).background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                Button("Сховати вивід") { cmdOutput = nil }.glassButton().controlSize(.small)
            }
        }
        .padding(14).glassCard(16, tint: (snap?.level ?? .ok) == .ok ? nil : (snap?.level ?? .ok).color.opacity(0.12))
        .overlay(alignment: .topLeading) { Rectangle().fill(color).frame(width: 4).clipShape(RoundedRectangle(cornerRadius: 2)).padding(.vertical, 14) }
        .confirmationDialog(confirm.map { L("Виконати «%@» на %@?", $0.title, server.name) } ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if let c = confirm { Button(c.title, role: .destructive) { run(c.command) }; Button("Скасувати", role: .cancel) {} }
        }
    }

    private var head: some View {
        HStack(spacing: 8) {
            StatusDot(level: snap?.level ?? .ok)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: server.name).font(.headline)
                    ForEach(server.tags, id: \.self) { Chip(text: $0, color: color) }
                }
                Text(verbatim: [snap?.hostname.isEmpty == false ? snap!.hostname : server.host, snap?.os ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let s = snap, s.reachable {
                VStack(alignment: .trailing, spacing: 1) {
                    Label(Fmt.uptime(s.uptime), systemImage: "power").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if s.updates > 0 { Chip(text: "\(s.updates) upd", symbol: "arrow.down.circle", color: s.updates > 30 ? .orange : .secondary) }
                        if s.rebootRequired { Chip(text: "reboot", symbol: "restart", color: .orange) }
                        Text(verbatim: String(format: "%.0f ms", s.rtt * 1000)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
            if monitor.polling.contains(server.id) { ProgressView().controlSize(.mini) }
        }
    }

    private func metrics(_ s: Snapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Gauge(value: s.cpuPercent ?? 0, label: "CPU", symbol: "cpu", warn: Double(Prefs.cpuWarn))
            Gauge(value: s.memPercent, label: Fmt.bytes(s.memUsed), symbol: "memorychip", warn: Double(Prefs.memWarn))
            Gauge(value: min(100, s.loadPercent), label: String(format: "%.2f", s.load1), symbol: "gauge.with.dots.needle.33percent", warn: 100)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Label(Fmt.rate(s.rxRate), systemImage: "arrow.down").font(.caption).foregroundStyle(.green)
                    Label(Fmt.rate(s.txRate), systemImage: "arrow.up").font(.caption).foregroundStyle(.blue)
                }.monospacedDigit()
                Spark(points: pts.suffix(compact ? 40 : 120).map(\.cpu), color: .accentColor, max: 100).frame(height: 34)
                HStack(spacing: 10) {
                    Text(verbatim: "\(s.cores) \(L("ядер"))").font(.caption2).foregroundStyle(.tertiary)
                    if let t = s.temp { Label(String(format: "%.0f°", t), systemImage: "thermometer.medium").font(.caption2).foregroundStyle(.tertiary) }
                    if s.swapTotal > 0 { Text(verbatim: "swap \(Fmt.pct(s.swapPercent))").font(.caption2).foregroundStyle(.tertiary) }
                    if s.users > 0 { Label("\(s.users)", systemImage: "person").font(.caption2).foregroundStyle(.tertiary) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func disks(_ s: Snapshot) -> some View {
        VStack(spacing: 6) {
            ForEach(s.disks.prefix(compact ? 2 : 6)) { d in
                Bar(title: d.mount, detail: "\(Fmt.bytes(d.used)) / \(Fmt.bytes(d.total))", percent: d.percent, warn: Double(Prefs.diskWarn))
            }
        }
    }

    private func servicesRow(_ s: Snapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(s.containers) { c in
                    Chip(text: c.name + (c.cpu.map { String(format: " %.0f%%", $0) } ?? ""), symbol: "shippingbox.fill", color: c.healthy ? .green : (c.state == "exited" ? .secondary : .red))
                        .help("\(c.image)\n\(c.status)" + (c.mem.map { "\n" + $0 } ?? ""))
                        .contextMenu {
                            Button { run("docker restart \(c.name)") } label: { Label("Перезапустити контейнер", systemImage: "arrow.clockwise") }
                            Button { run("docker logs --tail 60 \(c.name) 2>&1") } label: { Label("Останні 60 рядків логу", systemImage: "doc.text") }
                            if c.state == "running" { Button { run("docker stop \(c.name)") } label: { Label("Зупинити", systemImage: "stop.circle") } } else { Button { run("docker start \(c.name)") } label: { Label("Запустити", systemImage: "play.circle") } }
                        }
                }
                ForEach(s.services) { svc in
                    Chip(text: svc.name, symbol: "gearshape.2.fill", color: svc.active ? .green : .red)
                        .contextMenu { Button { run("systemctl restart \(svc.name) && systemctl is-active \(svc.name)") } label: { Label("systemctl restart", systemImage: "arrow.clockwise") } }
                }
            }
        }
    }

    private func procs(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Процеси").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(s.procs.prefix(5)) { p in
                HStack { Text(verbatim: p.name).font(.system(.caption, design: .monospaced)).lineLimit(1); Spacer(); Text(verbatim: String(format: "%.1f%% cpu · %.1f%% mem", p.cpu, p.mem)).font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
    }

    private func logs(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Журнал (warning+)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(s.log.suffix(6).enumerated()), id: \.offset) { _, l in Text(verbatim: l).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
        }
    }

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { monitor.openTerminal(server) } label: { Label("SSH", systemImage: "terminal") }
                if !server.webURL.isEmpty { Button { if let u = URL(string: server.webURL) { NSWorkspace.shared.open(u) } } label: { Label("Сайт", systemImage: "safari") } }
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(server.host, forType: .string); monitor.showToast(L("Скопійовано")) } label: { Label("IP", systemImage: "doc.on.doc") }
                Button { monitor.poll(server, force: true) } label: { Label("Оновити", systemImage: "arrow.clockwise") }
                ForEach(server.quickCommands) { q in
                    Button { if q.confirm { confirm = q } else { run(q.command) } } label: { Label(q.title, systemImage: q.symbol) }
                }
                Menu {
                    Button { run("docker compose ls 2>/dev/null; docker ps --format '{{.Names}}: {{.Status}}'") } label: { Label("Стан Docker", systemImage: "shippingbox") }
                    Button { run("df -h; echo; free -h") } label: { Label("Диск і памʼять", systemImage: "internaldrive") }
                    Button { run("journalctl -p err -n 30 --no-pager -o short-iso") } label: { Label("Помилки журналу", systemImage: "exclamationmark.triangle") }
                    Button { run("apt list --upgradable 2>/dev/null | head -40") } label: { Label("Доступні оновлення", systemImage: "arrow.down.circle") }
                    Button { run("docker builder prune -af 2>&1 | tail -2; df -h / | tail -1") } label: { Label("Очистити docker build cache", systemImage: "trash") }
                    Divider()
                    Button { confirm = QuickCommand(title: L("Перезавантажити сервер"), command: "reboot", confirm: true, symbol: "restart") } label: { Label("Перезавантажити сервер…", systemImage: "restart") }
                } label: { Label("Ще", systemImage: "ellipsis.circle") }
            }
        }
        .glassButton().controlSize(.small)
    }

    private func run(_ cmd: String) {
        cmdOutput = L("Виконую…")
        monitor.run(server, command: cmd) { cmdOutput = $0 }
    }
}
