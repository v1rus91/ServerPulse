import SwiftUI
import Charts

/// Головне вікно: список серверів, графіки, сповіщення, редагування.
struct DashboardView: View {
    @Environment(Monitor.self) private var monitor
    @State private var selected: UUID?
    @State private var editing: Server? = nil
    @State private var adding = false
    @State private var range: Int = 60   // хвилин

    private var server: Server? { monitor.servers.first { $0.id == selected } ?? monitor.servers.first }

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Section("Сервери") {
                    ForEach(monitor.servers) { s in
                        HStack(spacing: 8) {
                            StatusDot(level: monitor.snapshots[s.id]?.level ?? .ok)
                            VStack(alignment: .leading) {
                                Text(verbatim: s.name).font(.body.weight(.medium))
                                Text(verbatim: cpuLine(s)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !s.enabled { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
                        }
                        .tag(s.id)
                        .contextMenu {
                            Button { editing = s } label: { Label("Редагувати…", systemImage: "pencil") }
                            Button { var c = s; c.enabled.toggle(); monitor.update(c) } label: { Label(s.enabled ? "Призупинити" : "Увімкнути", systemImage: s.enabled ? "pause" : "play") }
                            Button(role: .destructive) { monitor.remove(s) } label: { Label("Видалити", systemImage: "trash") }
                        }
                    }
                    .onMove { monitor.move(from: $0, to: $1) }
                }
                if !monitor.alerts.isEmpty {
                    Section("Сповіщення") {
                        ForEach(monitor.alerts.prefix(30)) { a in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: a.resolved ? "checkmark.circle" : "exclamationmark.triangle.fill").foregroundStyle(a.resolved ? Color.secondary : Color.orange)
                                VStack(alignment: .leading) {
                                    Text(verbatim: "\(a.serverName): \(a.message)").font(.caption).lineLimit(2)
                                    Text(verbatim: a.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Button("Очистити сповіщення") { monitor.clearAlerts() }.font(.caption)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
            .toolbar {
                ToolbarItemGroup {
                    Button { adding = true } label: { Label("Додати сервер", systemImage: "plus") }
                    Button { let n = monitor.importFromSSHConfig(); monitor.showToast(L("Імпортовано: %d", n)) } label: { Label("Імпорт з ssh config", systemImage: "square.and.arrow.down") }
                }
            }
        } detail: {
            if let s = server {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ServerCard(server: s)
                            charts(s).id("charts")
                        }.padding(20)
                    }
                    .onAppear { if CommandLine.arguments.contains("--scroll-charts") { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { proxy.scrollTo("charts", anchor: .top) } } } }
                }
                .navigationTitle(s.name)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Picker("Період", selection: $range) { Text("15 хв").tag(15); Text("1 год").tag(60); Text("6 год").tag(360); Text("24 год").tag(1440); Text("7 д").tag(10080) }.pickerStyle(.segmented)
                        Button { editing = s } label: { Label("Редагувати", systemImage: "pencil") }
                        Button { monitor.poll(s, force: true) } label: { Label("Оновити", systemImage: "arrow.clockwise") }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Додайте перший сервер").font(.title3.weight(.semibold))
                    Text("Хости з ~/.ssh/config імпортуються одним кліком. Потрібен ключовий доступ без пароля.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 380)
                    HStack {
                        Button { let n = monitor.importFromSSHConfig(); monitor.showToast(L("Імпортовано: %d", n)) } label: { Label("Імпортувати з ssh config", systemImage: "square.and.arrow.down") }.glassButton(prominent: true)
                        Button { adding = true } label: { Label("Додати вручну", systemImage: "plus") }.glassButton()
                    }
                }
            }
        }
        .glassWindowBackground()
        .frame(minWidth: 980, minHeight: 640)
        .sheet(item: $editing) { s in ServerEditor(server: s) { monitor.update($0) } onDelete: { monitor.remove($0) } }
        .sheet(isPresented: $adding) { ServerEditor(server: Server(name: "", host: "")) { monitor.add($0) } onDelete: { _ in } }
        .overlay(alignment: .bottom) {
            if let t = monitor.toast { Text(verbatim: t).font(.callout).padding(.horizontal, 14).padding(.vertical, 8).glassCard(999).padding(.bottom, 16).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.spring(duration: 0.3), value: monitor.toast)
        .onAppear { if selected == nil { selected = monitor.servers.first?.id } }
    }

    private func cpuLine(_ s: Server) -> String {
        guard let snap = monitor.snapshots[s.id] else { return L("опитування…") }
        guard snap.reachable else { return L("недоступний") }
        return "CPU \(Fmt.pct(snap.cpuPercent)) · RAM \(Fmt.pct(snap.memPercent)) · " + (snap.disks.first.map { "Disk \(Fmt.pct($0.percent))" } ?? "")
    }

    private func charts(_ s: Server) -> some View {
        let cutoff = Date().addingTimeInterval(-Double(range) * 60)
        let raw = (monitor.history[s.id] ?? []).filter { $0.t >= cutoff }
        let pts = downsample(raw, to: 360)
        return VStack(alignment: .leading, spacing: 12) {
            if raw.count > 1 { stats(raw) }
            chart("CPU, %", pts.map { ($0.t, $0.cpu) }, color: .accentColor, max: 100)
            chart(L("Памʼять, %"), pts.map { ($0.t, $0.mem) }, color: .purple, max: 100)
            chart(L("Load (1 хв)"), pts.map { ($0.t, $0.load) }, color: .orange, max: nil)
            netChart(pts)
        }
    }

    /// Усереднення у кошики, щоб тижневі графіки не мали десятків тисяч точок.
    private func downsample(_ pts: [Point], to n: Int) -> [Point] {
        guard pts.count > n * 2 else { return pts }
        let size = pts.count / n
        return stride(from: 0, to: pts.count, by: size).map { i in
            let b = pts[i..<min(i + size, pts.count)]; let c = Double(b.count)
            return Point(t: b[b.startIndex].t, cpu: b.map(\.cpu).reduce(0, +) / c, mem: b.map(\.mem).reduce(0, +) / c, rx: b.map(\.rx).reduce(0, +) / c, tx: b.map(\.tx).reduce(0, +) / c, load: b.map(\.load).reduce(0, +) / c)
        }
    }

    /// Підсумок за період: середнє/максимум CPU і памʼяті, пік load, сумарний трафік.
    private func stats(_ pts: [Point]) -> some View {
        let c = Double(pts.count)
        let cpuAvg = pts.map(\.cpu).reduce(0, +) / c, cpuMax = pts.map(\.cpu).max() ?? 0
        let memAvg = pts.map(\.mem).reduce(0, +) / c, memMax = pts.map(\.mem).max() ?? 0
        let loadMax = pts.map(\.load).max() ?? 0
        var rxTotal = 0.0, txTotal = 0.0
        for i in 1..<pts.count { let dt = min(600, pts[i].t.timeIntervalSince(pts[i - 1].t)); rxTotal += pts[i].rx * dt; txTotal += pts[i].tx * dt }
        let span = pts.last!.t.timeIntervalSince(pts.first!.t)
        return HStack(spacing: 0) {
            statCell("CPU", String(format: "%.0f%%", cpuAvg), String(format: "max %.0f%%", cpuMax), "cpu")
            statCell(L("Памʼять"), String(format: "%.0f%%", memAvg), String(format: "max %.0f%%", memMax), "memorychip")
            statCell("Load", String(format: "%.2f", loadMax), L("пік"), "gauge.with.dots.needle.33percent")
            statCell(L("Трафік"), "↓ " + Fmt.bytes(rxTotal), "↑ " + Fmt.bytes(txTotal), "network")
            statCell(L("Період"), Fmt.uptime(span), L("%d точок", pts.count), "clock")
        }.padding(.vertical, 10).glassCard(12)
    }

    private func statCell(_ title: String, _ value: String, _ sub: String, _ symbol: String) -> some View {
        VStack(spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(verbatim: sub).font(.caption2).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity)
    }

    private func chart(_ title: String, _ data: [(Date, Double)], color: Color, max: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(verbatim: title).font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); if let last = data.last { Text(verbatim: String(format: "%.1f", last.1)).font(.caption).monospacedDigit() } }
            Chart(Array(data.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("t", p.0), y: .value("v", p.1)).foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom)).interpolationMethod(.catmullRom)
                LineMark(x: .value("t", p.0), y: .value("v", p.1)).foregroundStyle(color).interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 0...(max ?? Swift.max(1, (data.map(\.1).max() ?? 1) * 1.2)))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisGridLine(); AxisValueLabel(format: range >= 1440 ? .dateTime.day().month(.abbreviated).hour() : .dateTime.hour().minute()) } }
            .frame(height: 120)
        }.padding(12).glassCard(12)
    }

    private func netChart(_ pts: [Point]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("Мережа").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer()
                if let l = pts.last { Text(verbatim: "↓ \(Fmt.rate(l.rx))  ↑ \(Fmt.rate(l.tx))").font(.caption).monospacedDigit() } }
            Chart {
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("t", p.t), y: .value("rx", p.rx / 1024), series: .value("s", "rx")).foregroundStyle(.green).interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", p.t), y: .value("tx", p.tx / 1024), series: .value("s", "tx")).foregroundStyle(.blue).interpolationMethod(.catmullRom)
                }
            }
            .chartYAxisLabel("KB/s")
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisGridLine(); AxisValueLabel(format: range >= 1440 ? .dateTime.day().month(.abbreviated).hour() : .dateTime.hour().minute()) } }
            .frame(height: 120)
        }.padding(12).glassCard(12)
    }
}

// MARK: - Редактор сервера

struct ServerEditor: View {
    @State var server: Server
    let onSave: (Server) -> Void
    let onDelete: (Server) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var services = ""
    @State private var tags = ""
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(server.name.isEmpty ? "Новий сервер" : server.name, systemImage: "server.rack").font(.title3.weight(.semibold))
            Form {
                TextField("Назва", text: $server.name)
                TextField("Хост або аліас із ~/.ssh/config", text: $server.host)
                HStack {
                    TextField("Користувач", text: $server.user)
                    TextField("Порт", value: $server.port, format: .number).frame(width: 90)
                }
                HStack {
                    TextField("Ключ (порожньо — з ssh config або агента)", text: $server.keyPath)
                    Button("Обрати…") { let p = NSOpenPanel(); p.canChooseFiles = true; p.showsHiddenFiles = true; p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh"); if p.runModal() == .OK, let u = p.url { server.keyPath = u.path } }
                }
                TextField("systemd-сервіси для контролю (через пробіл)", text: $services)
                TextField("Сайт (URL)", text: $server.webURL)
                TextField("Теги (через кому)", text: $tags)
                TextField("Ховати з журналу рядки, що містять (через кому)", text: $server.logFilter)
                Picker("Колір", selection: $server.color) { ForEach(Pin.palette, id: \.self) { c in HStack { Circle().fill(Color(nsColor: Pin.color(c))).frame(width: 10, height: 10); Text(verbatim: c) }.tag(c) } }
                Toggle("Увімкнено", isOn: $server.enabled)
                Section("Швидкі команди") {
                    ForEach($server.quickCommands) { $q in
                        HStack {
                            TextField("Назва", text: $q.title).frame(width: 140)
                            TextField("Команда", text: $q.command).font(.system(.body, design: .monospaced))
                            Toggle("Підтвердження", isOn: $q.confirm).toggleStyle(.checkbox)
                            Button { server.quickCommands.removeAll { $0.id == q.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }
                    }
                    Button { server.quickCommands.append(QuickCommand(title: L("Нова команда"), command: "docker compose -f /opt/app/compose.yml ps")) } label: { Label("Додати команду", systemImage: "plus") }
                }
            }
            .formStyle(.grouped).frame(height: 460)
            HStack {
                Button { test() } label: { HStack { if testing { ProgressView().controlSize(.small) }; Label("Перевірити зʼєднання", systemImage: "bolt.horizontal") } }.glassButton().disabled(testing)
                Text(verbatim: testResult).font(.caption).foregroundStyle(testResult.hasPrefix("✓") ? .green : .red).lineLimit(2)
                Spacer()
                if !server.name.isEmpty { Button("Видалити", role: .destructive) { onDelete(server); dismiss() } }
                Button("Скасувати") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Зберегти") { save() }.keyboardShortcut(.defaultAction).glassButton(prominent: true).disabled(server.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 640)
        .onAppear { services = server.services.joined(separator: " "); tags = server.tags.joined(separator: ", ") }
    }

    private func save() {
        if server.name.isEmpty { server.name = server.host }
        server.services = services.split(separator: " ").map(String.init)
        server.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        onSave(server); dismiss()
    }

    private func test() {
        testing = true; testResult = ""
        let s = server
        Task.detached {
            let (out, err, code, rtt) = SSH.run(s, command: "hostname && uptime", timeout: 15)
            await MainActor.run {
                testing = false
                testResult = code == 0 ? "✓ \(out.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " · ")) (\(Int(rtt * 1000)) ms)" : "✗ " + (err.split(separator: "\n").last.map(String.init) ?? L("код %d", code))
            }
        }
    }
}
