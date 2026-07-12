import SwiftUI

struct CompareScansView: View {
    @EnvironmentObject private var historyStore: ScanHistoryStore

    @State private var baselineID: UUID?
    @State private var targetID: UUID?
    @State private var baselineDocument: FaceScanDocument?
    @State private var targetDocument: FaceScanDocument?
    @State private var comparison: ScanComparisonResult?

    private let accent = Color(red: 0.56, green: 1.0, blue: 0.25)

    init(initialBaselineID: UUID? = nil, initialTargetID: UUID? = nil) {
        _baselineID = State(initialValue: initialBaselineID)
        _targetID = State(initialValue: initialTargetID)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                selectors

                if let comparison,
                   let baselineRecord,
                   let targetRecord,
                   let targetDocument {
                    summaryCard(
                        comparison: comparison,
                        baseline: baselineRecord,
                        target: targetRecord
                    )
                    meshCard(document: targetDocument, result: comparison)
                    featureDeltaCard(comparison.featureDeltas)
                    symmetryDeltaCard(comparison.symmetryDeltas)
                    warningCard(comparison)
                } else {
                    placeholder
                }
            }
            .padding(16)
            .padding(.bottom, 28)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Сравнение сканов")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            configureDefaults()
            reloadComparison()
        }
        .onChange(of: baselineID) { _ in reloadComparison() }
        .onChange(of: targetID) { _ in reloadComparison() }
    }

    private var selectors: some View {
        VStack(spacing: 12) {
            scanPicker(title: "Базовый", selection: $baselineID)
            scanPicker(title: "Текущий", selection: $targetID)
        }
        .padding(15)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }

    private func scanPicker(title: String, selection: Binding<UUID?>) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.white.opacity(0.58))
            Spacer()
            Picker(title, selection: selection) {
                ForEach(historyStore.records) { record in
                    Text(record.savedAt.formatted(date: .abbreviated, time: .shortened))
                        .tag(Optional(record.id))
                }
            }
            .pickerStyle(.menu)
            .tint(accent)
        }
    }

    private func summaryCard(
        comparison: ScanComparisonResult,
        baseline: SavedScanRecord,
        target: SavedScanRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PSL estimate")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.48))
                    Text(String(format: "%.2f → %.2f", baseline.score, target.score))
                        .font(.system(size: 29, weight: .black, design: .rounded))
                }
                Spacer()
                deltaBadge(comparison.scoreDelta, decimals: 2)
            }

            HStack(spacing: 10) {
                compactStat(
                    "Поверхность",
                    String(format: "%.2f мм", comparison.medianSurfaceChangeMM)
                )
                compactStat(
                    "P90",
                    String(format: "%.2f мм", comparison.p90SurfaceChangeMM)
                )
                compactStat(
                    "Надёжно",
                    String(format: "%.0f%%", comparison.reliableVertexPercent)
                )
            }

            HStack {
                Label(
                    String(format: "%@%d качества", comparison.qualityDelta >= 0 ? "+" : "", comparison.qualityDelta),
                    systemImage: "camera.metering.matrix"
                )
                Spacer()
                Label(
                    String(format: "%@%d repeatability", comparison.repeatabilityDelta >= 0 ? "+" : "", comparison.repeatabilityDelta),
                    systemImage: "checkmark.shield"
                )
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.52))
        }
        .padding(16)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
    }

    private func meshCard(
        document: FaceScanDocument,
        result: ScanComparisonResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Карта изменений", systemImage: "square.3.layers.3d")
                .font(.headline)
                .foregroundStyle(accent)

            ComparisonMeshView(document: document, result: result)
                .frame(height: 330)
                .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))

            HStack(spacing: 8) {
                legend(color: .blue, text: "назад")
                legend(color: .green, text: "≈ 0")
                legend(color: .red, text: "вперёд")
                legend(color: .gray, text: "ненадёжно")
            }
            .font(.caption2)

            Text("Шкала цвета ограничена диапазоном −4…+4 мм. Модель выровнена по центральной верхней зоне лица.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(15)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
    }

    private func featureDeltaCard(_ values: [ComparisonMetricDelta]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Изменение 3D-метрик", systemImage: "ruler")
                .font(.headline)
                .foregroundStyle(accent)

            ForEach(values) { metric in
                metricDeltaRow(metric, lowerIsBetter: false)
                if metric.id != values.last?.id {
                    Divider().overlay(.white.opacity(0.08))
                }
            }
        }
        .padding(15)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
    }

    private func symmetryDeltaCard(_ values: [ComparisonMetricDelta]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Изменение асимметрии", systemImage: "face.smiling")
                .font(.headline)
                .foregroundStyle(accent)

            ForEach(values) { metric in
                metricDeltaRow(metric, lowerIsBetter: true)
                if metric.id != values.last?.id {
                    Divider().overlay(.white.opacity(0.08))
                }
            }
        }
        .padding(15)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
    }

    private func metricDeltaRow(
        _ metric: ComparisonMetricDelta,
        lowerIsBetter: Bool
    ) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(metric.title)
                    .font(.subheadline.bold())
                Text(String(format: "%.2f → %.2f %@ · C %d%%", metric.baselineValue, metric.targetValue, metric.unit, metric.confidence))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.44))
            }
            Spacer()
            let improved = lowerIsBetter ? metric.delta < 0 : metric.delta > 0
            Text(String(format: "%@%.2f", metric.delta >= 0 ? "+" : "", metric.delta))
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(abs(metric.delta) < 0.05 ? .white.opacity(0.55) : (improved ? accent : .orange))
        }
    }

    private func warningCard(_ result: ScanComparisonResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Интерпретация", systemImage: "exclamationmark.triangle")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)

            Text(result.reliableVertexPercent >= 70
                ? "Сравнение пригодно для наблюдения. Небольшие различия до 1–2 мм могут оставаться результатом мимики, положения головы и погрешности TrueDepth."
                : "Надёжных вершин недостаточно. Не делай выводы по этой карте — лучше повторить анализ в одинаковом освещении и с нейтральной мимикой.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 17))
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.left.and.right.square")
                .font(.system(size: 42))
                .foregroundStyle(accent)
            Text("Выбери два разных анализа")
                .font(.headline)
            Text("Для 3D-сравнения нужны сохранённые meshes с одинаковой топологией.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.48))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private func configureDefaults() {
        if baselineID == nil {
            baselineID = historyStore.baselineRecord?.id ?? historyStore.records.last?.id
        }
        if targetID == nil {
            targetID = historyStore.records.first?.id
        }
        if baselineID == targetID, historyStore.records.count > 1 {
            baselineID = historyStore.records.last?.id
            targetID = historyStore.records.first?.id
        }
    }

    private func reloadComparison() {
        guard
            let baselineRecord,
            let targetRecord,
            baselineRecord.id != targetRecord.id
        else {
            comparison = nil
            return
        }
        let base = historyStore.document(for: baselineRecord)
        let target = historyStore.document(for: targetRecord)
        baselineDocument = base
        targetDocument = target
        if let base, let target {
            comparison = ScanComparisonAnalyzer.compare(baseline: base, target: target)
        } else {
            comparison = nil
        }
    }

    private var baselineRecord: SavedScanRecord? {
        guard let baselineID else { return nil }
        return historyStore.record(id: baselineID)
    }

    private var targetRecord: SavedScanRecord? {
        guard let targetID else { return nil }
        return historyStore.record(id: targetID)
    }

    private func compactStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.42))
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func deltaBadge(_ value: Float, decimals: Int) -> some View {
        let formatted = decimals == 2
            ? String(format: "%@%.2f", value >= 0 ? "+" : "", value)
            : String(format: "%@%.1f", value >= 0 ? "+" : "", value)
        return Text(formatted)
            .font(.title3.bold().monospacedDigit())
            .foregroundStyle(abs(value) < 0.15 ? .white.opacity(0.62) : (value > 0 ? accent : .orange))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.white.opacity(0.06), in: Capsule())
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.white.opacity(0.48))
        }
    }
}
