import SwiftUI

struct ResultsView: View {
    @EnvironmentObject private var scanner: FaceScanner
    let summary: ScanSummary
    let document: FaceScanDocument

    @State private var showingShareSheet = false
    @State private var shareItems = [Any]()
    @State private var meshMode: MeshDisplayMode = .fused
    private let accent = Color(red: 0.56, green: 1.0, blue: 0.25)

    var body: some View {
        ZStack {
            background

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    topBar
                    scoreHero
                    repeatabilitySection
                    meshCard
                    depthFusionSection
                    componentSection
                    measurementsSection

                    if !summary.warnings.isEmpty {
                        warningsSection
                    }

                    noticeSection
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
                Text("RESULTS")
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
                        .font(.system(size: 64, weight: .black, design: .rounded))
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

            Divider()
                .overlay(.white.opacity(0.12))

            Text(categoryDescription)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.74))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                heroStat("Качество", "\(summary.quality)/100")
                heroStat("Кадры", "\(summary.acceptedFrames)")
                heroStat("Покрытие", String(format: "%.0f°", summary.yawCoverageDegrees))
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
        .overlay(cardBorder)
    }

    private var repeatabilitySection: some View {
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
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)

            ProgressView(
                value: Double(repeatability.scanCount),
                total: Double(max(repeatability.requiredScanCount, 1))
            )
            .tint(repeatability.passed ? accent : repeatabilityColor)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                measurementTile("Повторяемость", repeatability.scanCount >= 2 ? "\(repeatability.score)/100" : "—")
                measurementTile("Медиана", repeatability.scanCount >= 2 ? String(format: "%.2f мм", repeatability.medianVertexDeviationMM) : "—")
                measurementTile("P90", repeatability.scanCount >= 2 ? String(format: "%.2f мм", repeatability.p90VertexDeviationMM) : "—")
                measurementTile("Стабильные вершины", repeatability.scanCount >= 2 ? String(format: "%.0f%%", repeatability.stableVertexPercent) : "—")
                measurementTile("Разброс балла", repeatability.scanCount >= 2 ? String(format: "%.2f", repeatability.scoreSpread) : "—")
                measurementTile("Сканы", repeatability.scanScores.map { String(format: "%.2f", $0) }.joined(separator: " · ").nilIfEmpty ?? "—")
            }

            if repeatability.scanCount >= 2 {
                HStack(spacing: 8) {
                    heatLegend(color: .green, text: "≤ 1.0 мм")
                    heatLegend(color: .yellow, text: "1–2 мм")
                    heatLegend(color: .red, text: "> 2 мм")
                }
            }
        }
        .padding(16)
        .background(repeatabilityColor.opacity(0.065), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(repeatabilityColor.opacity(0.24), lineWidth: 1)
        }
    }

    private var meshCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("3D MESH", systemImage: "cube.transparent")
                    .font(.headline.bold())
                Spacer()
                Text("Вращай пальцем")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.48))
            }

            Picker("Сетка", selection: $meshMode) {
                Text("Depth Fusion").tag(MeshDisplayMode.fused)
                Text("ARKit base").tag(MeshDisplayMode.base)
                if summary.repeatability.scanCount >= 2 {
                    Text("Погрешность").tag(MeshDisplayMode.uncertainty)
                }
            }
            .pickerStyle(.segmented)

            MeshPreviewView(document: document, mode: meshMode)
                .frame(height: 320)
                .background(
                    LinearGradient(
                        colors: [accent.opacity(0.08), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))

            HStack {
                meshStat("Вершины", "\(document.vertexCount)")
                meshStat("Уточнено", "\(summary.depthFusion.refinedVertexCount)")
                meshStat("Depth", String(format: "%.0f%%", summary.depthFusion.coveragePercent))
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
        .overlay(cardBorder)
    }

    private var depthFusionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("Depth Fusion", icon: "dot.radiowaves.left.and.right")
                Spacer()

                Text(summary.depthFusion.applied ? "ACTIVE" : "FALLBACK")
                    .font(.caption2.bold())
                    .foregroundStyle(summary.depthFusion.applied ? Color.black : Color.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        summary.depthFusion.applied ? accent : Color.orange.opacity(0.14),
                        in: Capsule()
                    )
            }

            Text(depthFusionDescription)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                measurementTile("Кадры depth", "\(summary.depthFusion.sourceFrameCount)")
                measurementTile("Уточнено", "\(summary.depthFusion.refinedVertexCount)/\(summary.depthFusion.totalVertexCount)")
                measurementTile("Остаток", String(format: "%.1f мм", summary.depthFusion.medianResidualMM))
                measurementTile("Шум времени", String(format: "%.1f мм", summary.depthFusion.temporalNoiseMM))
                measurementTile("Blend", String(format: "%.0f%%", summary.depthFusion.meanBlendWeight * 100))
                measurementTile("Mapping", summary.depthFusion.mapping == "mirrored" ? "Mirrored" : "Native")
            }
        }
        .padding(16)
        .background(
            (summary.depthFusion.applied ? accent : Color.orange).opacity(0.065),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(
                    (summary.depthFusion.applied ? accent : Color.orange).opacity(0.24),
                    lineWidth: 1
                )
        }
    }

    private var componentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Компоненты", icon: "chart.bar.xaxis")

            ForEach(summary.featureMetrics) { metric in
                componentRow(metric)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
        .overlay(cardBorder)
    }

    private var measurementsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Измерения сетки", icon: "ruler")

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                measurementTile("Ширина", String(format: "%.1f мм", summary.widthMM))
                measurementTile("Высота", String(format: "%.1f мм", summary.heightMM))
                measurementTile("Глубина", String(format: "%.1f мм", summary.depthMM))
                measurementTile("3D-асимметрия", String(format: "%.2f мм", summary.symmetryErrorMM))
                measurementTile("Внутри скана", String(format: "%.2f мм", summary.stabilityErrorMM))
                measurementTile("Поворот", String(format: "%.1f°", summary.yawCoverageDegrees))
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
        .overlay(cardBorder)
    }

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Что учесть", icon: "exclamationmark.triangle")

            ForEach(Array(summary.warnings.enumerated()), id: \.offset) { _, warning in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
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

    private var noticeSection: some View {
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

    private func componentRow(_ metric: FeatureMetric) -> some View {
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
                    Capsule()
                        .fill(.white.opacity(0.08))
                    Capsule()
                        .fill(componentGradient)
                        .frame(width: geometry.size.width * CGFloat(max(0, min(metric.score, 100)) / 100))
                }
            }
            .frame(height: 7)

            HStack(alignment: .firstTextBaseline) {
                Text(metric.explanation)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.50))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Text("\(String(format: "%.2f", metric.rawValue)) \(metric.rawUnit)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.38))
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

    private func meshStat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.caption.bold().monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.42))
        }
        .frame(maxWidth: .infinity)
    }

    private func measurementTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.48))
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private func heatLegend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity)
    }

    private func shareAllExports() {
        shareItems = scanner.exportURLs.map { $0 as Any }
        showingShareSheet = !shareItems.isEmpty
    }

    private var depthFusionDescription: String {
        if summary.depthFusion.applied {
            return "Итоговая сетка уточнена временной медианой нескольких синхронных карт глубины. Выбросы отбрасываются, а максимальная коррекция каждой вершины ограничена."
        }

        return "Карты глубины были получены, но не прошли контроль покрытия, остатка или временной стабильности. Для результата используется безопасная медианная ARKit-сетка."
    }

    private var categoryDescription: String {
        if !summary.categoryIsFinal {
            if summary.repeatability.complete {
                return "Категория скрыта: три скана расходятся сильнее допуска. Посмотри карту погрешности и повтори серию."
            }
            return "Категория пока не финальная. Выполни три последовательных скана, чтобы приложение проверило повторяемость формы."
        }

        switch summary.category {
        case "SUB 3": return "Нижний диапазон экспериментальной шкалы после проверки повторяемости."
        case "SUB 5": return "Ниже среднего диапазона текущей экспериментальной калибровки."
        case "LTN": return "Нижняя часть среднего диапазона текущей экспериментальной калибровки."
        case "MTN": return "Средняя зона текущей экспериментальной калибровки."
        case "HTN": return "Верхняя часть среднего диапазона текущей экспериментальной калибровки."
        case "CHAD": return "Верхний диапазон демонстрационной шкалы, подтверждённый серией сканов."
        default: return "Результат требует повторного сканирования."
        }
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

    private var componentGradient: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.65), accent],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 22)
            .stroke(.white.opacity(0.10), lineWidth: 1)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
