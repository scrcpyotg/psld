import SwiftUI

private enum ResultSection: String, CaseIterable, Identifiable {
    case overview
    case metrics
    case symmetry
    case mesh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Итог"
        case .metrics: return "3D-метрики"
        case .symmetry: return "Симметрия"
        case .mesh: return "Mesh"
        }
    }
}

struct ResultsView: View {
    @EnvironmentObject private var scanner: FaceScanner
    @EnvironmentObject private var historyStore: ScanHistoryStore

    let summary: ScanSummary
    let document: FaceScanDocument

    @State private var selectedSection: ResultSection = .overview
    @State private var showingShareSheet = false
    @State private var shareItems = [Any]()
    @State private var meshMode: MeshDisplayMode = .fused

    private let accent = Color(red: 0.56, green: 1.0, blue: 0.25)

    var body: some View {
        ZStack {
            background

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    topBar
                    scoreHero
                    sectionPicker

                    switch selectedSection {
                    case .overview:
                        overviewSection
                    case .metrics:
                        metricsSection
                    case .symmetry:
                        symmetrySection
                    case .mesh:
                        meshSection
                    }

                    actionSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 36)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: shareItems)
        }
        .task {
            historyStore.saveIfNeeded(document)
        }
    }

    private var background: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [accent.opacity(0.12), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
            .ignoresSafeArea()
        }
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("RESULTS v0.5")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                Text("TrueDepth · серия \(summary.repeatability.scanCount)/\(summary.repeatability.requiredScanCount)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()

            Button {
                shareAllExports()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.headline)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .foregroundStyle(.white)
            .disabled(scanner.exportURLs.isEmpty)
        }
    }

    private var scoreHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.categoryIsFinal ? "ИТОГОВЫЙ PSL" : "ПРЕДВАРИТЕЛЬНЫЙ PSL")
                        .font(.caption2.bold())
                        .foregroundStyle(accent)

                    Text(String(format: "%.2f", summary.pslScore))
                        .font(.system(size: 62, weight: .black, design: .rounded))
                        .foregroundStyle(scoreGradient)
                        .minimumScaleFactor(0.7)

                    Text("Диапазон \(String(format: "%.2f", summary.scoreRangeLow))–\(String(format: "%.2f", summary.scoreRangeHigh))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Text(summary.category)
                        .font(.system(size: summary.category.count > 8 ? 13 : 22, weight: .black, design: .rounded))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(categoryColor, in: Capsule())

                    reliabilityBadge
                }
            }

            Divider().overlay(.white.opacity(0.12))

            Text(categoryDescription)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.74))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                heroStat("Качество", "\(summary.quality)/100")
                heroStat("Повторяемость", "\(summary.repeatability.score)%")
                heroStat("Depth", summary.depthFusion.applied ? "ON" : "BASE")
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
        .overlay(cardBorder)
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ResultSection.allCases) { section in
                    Button(section.title) {
                        withAnimation(.easeInOut(duration: 0.20)) {
                            selectedSection = section
                        }
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        selectedSection == section ? accent : Color.white.opacity(0.07),
                        in: Capsule()
                    )
                    .foregroundStyle(selectedSection == section ? Color.black : Color.white)
                }
            }
        }
    }

    private var overviewSection: some View {
        VStack(spacing: 16) {
            repeatabilityCard
            depthFusionCard
            measurementsSnapshot

            if !summary.warnings.isEmpty {
                warningsCard
            }

            noticeCard
        }
    }

    private var repeatabilityCard: some View {
        let repeatability = summary.repeatability

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("Scan Reliability", icon: "checkmark.shield")
                Spacer()
                Text(repeatability.complete ? (repeatability.passed ? "PASSED" : "FAILED") : "\(repeatability.scanCount)/\(repeatability.requiredScanCount)")
                    .font(.caption2.bold())
                    .foregroundStyle(repeatability.passed ? Color.black : repeatabilityColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        repeatability.passed ? accent : repeatabilityColor.opacity(0.14),
                        in: Capsule()
                    )
            }

            Text(repeatability.status)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.62))

            HStack(spacing: 10) {
                metricTile("Median", String(format: "%.2f мм", repeatability.medianVertexDeviationMM))
                metricTile("P90", String(format: "%.2f мм", repeatability.p90VertexDeviationMM))
                metricTile("Stable", String(format: "%.0f%%", repeatability.stableVertexPercent))
            }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
        .overlay(cardBorder)
    }

    private var depthFusionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                sectionTitle("Depth Fusion", icon: "dot.radiowaves.left.and.right")
                Spacer()
                Text(summary.depthFusion.applied ? "ACTIVE" : "FALLBACK")
                    .font(.caption2.bold())
                    .foregroundStyle(summary.depthFusion.applied ? Color.black : Color.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(summary.depthFusion.applied ? accent : Color.orange.opacity(0.13), in: Capsule())
            }

            HStack(spacing: 10) {
                metricTile("Coverage", String(format: "%.0f%%", summary.depthFusion.coveragePercent))
                metricTile("Residual", String(format: "%.1f мм", summary.depthFusion.medianResidualMM))
                metricTile("Noise", String(format: "%.1f мм", summary.depthFusion.temporalNoiseMM))
            }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
        .overlay(cardBorder)
    }

    private var measurementsSnapshot: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("Базовые размеры", icon: "ruler")

            HStack(spacing: 10) {
                metricTile("Ширина", String(format: "%.1f мм", summary.widthMM))
                metricTile("Высота", String(format: "%.1f мм", summary.heightMM))
                metricTile("Глубина", String(format: "%.1f мм", summary.depthMM))
            }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
        .overlay(cardBorder)
    }

    private var metricsSection: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Feature scores", icon: "chart.bar.xaxis")
                ForEach(summary.featureMetrics) { metric in
                    featureRow(metric)
                }
            }
            .padding(16)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
            .overlay(cardBorder)

            VStack(alignment: .leading, spacing: 13) {
                sectionTitle("Raw 3D measurements", icon: "ruler.fill")

                ForEach(summary.surfaceMeasurements) { measurement in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(measurement.title)
                                .font(.subheadline.bold())
                            Text(measurement.explanation)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.44))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 10)

                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(String(format: measurement.unit == "ratio" ? "%.3f" : "%.2f", measurement.value)) \(measurement.unit)")
                                .font(.subheadline.bold().monospacedDigit())
                            Text("C \(measurement.confidence)%")
                                .font(.caption2.bold())
                                .foregroundStyle(confidenceColor(measurement.confidence))
                        }
                    }

                    Divider().overlay(.white.opacity(0.08))
                }
            }
            .padding(16)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
            .overlay(cardBorder)
        }
    }

    private var symmetrySection: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Региональная 3D-симметрия", icon: "face.smiling")

                ForEach(summary.regionalSymmetry) { region in
                    VStack(spacing: 7) {
                        HStack {
                            Text(region.title)
                                .font(.subheadline.bold())
                            Spacer()
                            Text(String(format: "%.2f мм", region.errorMM))
                                .font(.subheadline.bold().monospacedDigit())
                            Text("C \(region.confidence)%")
                                .font(.caption2.bold())
                                .foregroundStyle(confidenceColor(region.confidence))
                        }

                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.08))
                                Capsule()
                                    .fill(scoreGradient)
                                    .frame(width: geometry.size.width * CGFloat(max(0, min(region.score, 100)) / 100))
                            }
                        }
                        .frame(height: 7)
                    }

                    Divider().overlay(.white.opacity(0.08))
                }
            }
            .padding(16)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
            .overlay(cardBorder)

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Карта асимметрии", icon: "circle.lefthalf.filled")
                MeshPreviewView(document: document, mode: .asymmetry)
                    .frame(height: 320)
                    .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))

                HStack {
                    heatLegend(.green, "стабильно")
                    heatLegend(.yellow, "среднее")
                    heatLegend(.red, "выше")
                }
            }
            .padding(14)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
            .overlay(cardBorder)
        }
    }

    private var meshSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("3D mesh", icon: "cube.transparent")

            MeshPreviewView(document: document, mode: meshMode)
                .frame(height: 360)
                .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MeshDisplayMode.allCases) { mode in
                        Button(mode.title) {
                            meshMode = mode
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(meshMode == mode ? accent : Color.white.opacity(0.07), in: Capsule())
                        .foregroundStyle(meshMode == mode ? Color.black : Color.white)
                    }
                }
            }

            Text("Проведи пальцем по модели для вращения, сведи или разведи пальцы для масштаба.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.42))
        }
        .padding(14)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
        .overlay(cardBorder)
    }

    private var warningsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Ограничения", icon: "exclamationmark.triangle")

            ForEach(summary.warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 9) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.70))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        }
    }

    private var noticeCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(accent)
            Text(document.notice)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }

    private var actionSection: some View {
        VStack(spacing: 10) {
            if summary.repeatability.scanCount < summary.repeatability.requiredScanCount {
                Button {
                    scanner.continueReliabilitySeries()
                } label: {
                    Label(
                        "Контрольный скан \(summary.repeatability.scanCount + 1) из \(summary.repeatability.requiredScanCount)",
                        systemImage: "viewfinder.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ResultPrimaryButtonStyle(accent: accent))
            } else {
                Button {
                    shareAllExports()
                } label: {
                    Label("Экспорт JSON + OBJ + PLY", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ResultPrimaryButtonStyle(accent: accent))
                .disabled(scanner.exportURLs.isEmpty)
            }

            Button {
                scanner.resetForNewScan()
            } label: {
                Label("Новая серия из трёх сканов", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ResultSecondaryButtonStyle())
        }
    }

    private func featureRow(_ metric: FeatureMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(metric.title)
                    .font(.subheadline.bold())
                Spacer()
                Text(String(format: "%.0f", metric.score))
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(accent)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(scoreGradient)
                        .frame(width: geometry.size.width * CGFloat(max(0, min(metric.score, 100)) / 100))
                }
            }
            .frame(height: 7)

            HStack(alignment: .top) {
                Text(metric.explanation)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(String(format: "%.2f", metric.rawValue)) \(metric.rawUnit)")
                        .font(.caption2.monospacedDigit())
                    Text("Confidence \(metric.confidence)%")
                        .font(.caption2.bold())
                        .foregroundStyle(confidenceColor(metric.confidence))
                    if metric.crossScanSpread > 0 {
                        Text("spread \(String(format: "%.2f", metric.crossScanSpread))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.34))
                    }
                }
                .foregroundStyle(.white.opacity(0.48))
            }
        }
        .padding(.vertical, 5)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(accent)
            Text(title)
                .font(.headline.bold())
        }
    }

    private func heroStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metricTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.43))
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func heatLegend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.54))
        }
        .frame(maxWidth: .infinity)
    }

    private func shareAllExports() {
        shareItems = scanner.exportURLs.map { $0 as Any }
        showingShareSheet = !shareItems.isEmpty
    }

    private func confidenceColor(_ confidence: Int) -> Color {
        if confidence >= 82 { return accent }
        if confidence >= 62 { return .yellow }
        return .orange
    }

    private var reliabilityBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(reliabilityColor)
                .frame(width: 7, height: 7)
            Text("Надёжность: \(summary.reliability)")
                .font(.caption.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: Capsule())
    }

    private var categoryDescription: String {
        if !summary.categoryIsFinal {
            if summary.repeatability.complete {
                return "Категория скрыта: три скана расходятся сильнее допуска. Повтори серию и посмотри карту погрешности."
            }
            return "Категория пока предварительная. После трёх сканов приложение сравнит каждую вершину и рассчитает confidence отдельных метрик."
        }
        return "Финальная категория разблокирована после проверки повторяемости трёх TrueDepth-сканов."
    }

    private var repeatabilityColor: Color {
        if summary.repeatability.passed { return accent }
        if summary.repeatability.complete { return .orange }
        return .yellow
    }

    private var categoryColor: Color {
        summary.categoryIsFinal ? accent : Color.yellow
    }

    private var reliabilityColor: Color {
        switch summary.reliability {
        case "Высокая": return .green
        case "Средняя": return .yellow
        default: return .orange
        }
    }

    private var scoreGradient: LinearGradient {
        LinearGradient(
            colors: [Color.white, accent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 22)
            .stroke(.white.opacity(0.10), lineWidth: 1)
    }
}

private struct ResultPrimaryButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 14)
            .background(
                accent.opacity(configuration.isPressed ? 0.76 : 1),
                in: RoundedRectangle(cornerRadius: 15)
            )
            .foregroundStyle(.black)
    }
}

private struct ResultSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 14)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.08 : 0.13),
                in: RoundedRectangle(cornerRadius: 15)
            )
            .foregroundStyle(.white)
    }
}
