import SwiftUI
import Charts

extension View {
    @ViewBuilder func glassCard(_ radius: CGFloat = 14, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: .rect(cornerRadius: radius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.08)))
        }
    }
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
    @ViewBuilder func glassWindowBackground() -> some View {
        if #available(macOS 15.0, *) { containerBackground(.thinMaterial, for: .window) } else { self }
    }
}

struct Kbd: View {
    let keys: String
    var body: some View {
        Text(verbatim: keys).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Кільцевий індикатор, як у Activity Monitor
struct Gauge: View {
    let value: Double          // 0…100
    let label: String
    let symbol: String
    var size: CGFloat = 54
    var warn: Double = 85
    private var color: Color { value >= warn ? .red : (value >= warn * 0.75 ? .orange : .accentColor) }
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 6)
                Circle().trim(from: 0, to: max(0.005, min(1, value / 100))).stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.6), value: value)
                VStack(spacing: 0) {
                    Image(systemName: symbol).font(.system(size: size * 0.2)).foregroundStyle(.secondary)
                    Text(verbatim: String(format: "%.0f", value)).font(.system(size: size * 0.26, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }.frame(width: size, height: size)
            Text(verbatim: label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Горизонтальна смуга (диски)
struct Bar: View {
    let title: String
    let detail: String
    let percent: Double
    var warn: Double = 90
    private var color: Color { percent >= warn ? .red : (percent >= warn * 0.8 ? .orange : .accentColor) }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(verbatim: title).font(.caption.weight(.medium)); Spacer(); Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(color).frame(width: max(4, g.size.width * min(1, percent / 100))).animation(.smooth(duration: 0.6), value: percent)
                }
            }.frame(height: 7)
        }
    }
}

/// Спарклайн
struct Spark: View {
    let points: [Double]
    var color: Color = .accentColor
    var max: Double? = nil
    var body: some View {
        Chart(Array(points.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .chartYScale(domain: 0...(max ?? Swift.max(1, points.max() ?? 1)))
    }
}

struct StatusDot: View {
    let level: Snapshot.Level
    var size: CGFloat = 9
    @State private var pulse = false
    var body: some View {
        Circle().fill(level.color).frame(width: size, height: size)
            .shadow(color: level.color.opacity(0.7), radius: pulse && level != .ok ? 6 : 2)
            .onAppear { pulse = true }
            .animation(level != .ok ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
    }
}

struct Chip: View {
    let text: String
    var symbol: String? = nil
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 4) { if let symbol { Image(systemName: symbol) }; Text(verbatim: text) }
            .font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.14), in: Capsule())
    }
}
