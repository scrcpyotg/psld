import SwiftUI
import Charts

private enum ProgressMetric: String, CaseIterable, Identifiable {
    case psl
    case symmetry
    case quality
    case repeatability

    var id: String { rawValue }

    var title: String {
        switch self {
        case .psl: return "PSL"
        case .symmetry: return "Симметрия"
        case .quality: return "Качество"
        case .repeatability: return "Повторяемость"
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var historyStore: ScanHistoryStore
    @Binding var selectedTab: RootTab
    @State private var progressMetric: ProgressMetric = .psl
    private let accent = Color(red: 0.56, green: 1.0, blue: 0.25)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if historyStore.records.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 12) {
                            historyHeader
                            progressCard
                            compareButton

                            ForEach(historyStore.records) { record in
                                NavigationLink {
                                    HistoryDetailView(recordID: record.id)
                                } label: {
                                    HistoryRow(record: record)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("История")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var historyHeader: some View {
        HStack(spacing: 12) {
            stat("Анализы", "\(historyStore.statistics.count)")
            stat("Финальные", "\(historyStore.statistics.finalCount)")
            stat(
                "Средний PSL",
                historyStore.statistics.finalCount > 0
                    ? String(format: "%.2f", historyStore.statistics.averageScore)
                    : "—"
            )
        }
        .padding(.bottom, 4)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Прогресс", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                    .foregroundStyle(accent)
                Spacer()
                Picker("Метрика", selection: $progressMetric) {
                    ForEach(ProgressMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.menu)
                .tint(accent)
            }

            Chart(Array(historyStore.records.reversed())) { record in
                LineMark(
                    x: .value("Дата", record.savedAt),
                    y: .value(progressMetric.title, progressValue(record))
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(accent)

                PointMark(
                    x: .value("Дата", record.savedAt),
                    y: .value(progressMetric.title, progressValue(record))
                )
                .foregroundStyle(record.repeatabilityPassed ? accent : Color.orange)
                .symbolSize(record.isBaseline == true ? 95 : 45)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.05))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.07))
                    AxisValueLabel().foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(height: 190)

            Text("Оранжевая точка — серия с низкой повторяемостью. Крупная точка — базовый анализ.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.40))
        }
        .padding(15)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }

    private var compareButton: some View {
        NavigationLink {
            CompareScansView(
                initialBaselineID: historyStore.baselineRecord?.id,
                initialTargetID: historyStore.records.first?.id
            )
        } label: {
            HStack {
                Label("Сравнить два анализа", systemImage: "arrow.left.and.right.square")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
            }
            .padding(15)
            .background(accent, in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
        .disabled(historyStore.records.count < 2)
        .opacity(historyStore.records.count < 2 ? 0.45 : 1)
    }

    private func progressValue(_ record: SavedScanRecord) -> Double {
        switch progressMetric {
        case .psl:
            return Double(record.score)
        case .symmetry:
            let values = record.regionalSymmetry.map(\.score)
            return values.isEmpty ? 0 : Double(values.reduce(0, +) / Float(values.count))
        case .quality:
            return Double(record.quality)
        case .repeatability:
            return Double(record.repeatabilityScore)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 50))
                .foregroundStyle(accent)

            Text("История пока пустая")
                .font(.title3.bold())

            Text("После завершённой серии из трёх сканов анализ автоматически сохранится в личном кабинете.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.56))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button {
                selectedTab = .scan
            } label: {
                Label("Сделать первый анализ", systemImage: "viewfinder")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(accent, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
    }
}

private struct HistoryRow: View {
    let record: SavedScanRecord
    private let accent = Color(red: 0.56, green: 1.0, blue: 0.25)

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                Text(String(format: "%.2f", record.score))
                    .font(.system(size: 25, weight: .black, design: .rounded))
                    .foregroundStyle(record.categoryIsFinal ? accent : .yellow)
                Text(record.category)
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.50))
                    .lineLimit(1)
            }
            .frame(width: 74)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(record.savedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline.bold())
                    if record.isBaseline == true {
                        Text("БАЗА")
                            .font(.system(size: 9, weight: .black))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(accent, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }

                HStack(spacing: 10) {
                    Label("\(record.quality)/100", systemImage: "camera.metering.matrix")
                    Label("\(record.repeatabilityScore)%", systemImage: "checkmark.shield")
                    if record.note != nil {
                        Image(systemName: "note.text")
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.48))

                Text(record.categoryIsFinal ? "Финальный анализ" : "Серия без финальной категории")
                    .font(.caption2)
                    .foregroundStyle(record.categoryIsFinal ? accent.opacity(0.76) : Color.orange.opacity(0.82))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.28))
        }
        .padding(14)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(record.isBaseline == true ? accent.opacity(0.45) : .white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct HistoryDetailView: View {
    @EnvironmentObject private var historyStore: ScanHistoryStore
    let recordID: UUID

    @State private var document: FaceScanDocument?
    @State private var meshMode: MeshDisplayMode = .fused
    @State private var showingShareSheet = false
    @State private var shareItems = [Any]()
    @State private var showingDeleteConfirmation = false
    @State private var showingMetadataEditor = false
    @State private var note = ""
    @State private var weightText = ""
    @Environment(\.dismiss) private var dismiss

    private let accent = Color(red: 0.56, green: 1.0, blue: 0.25)

    var body: some View {
        Group {
            if let record = historyStore.record(id: recordID) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        scoreCard(record)
                        baselineAndComparison(record)
                        notesCard(record)

                        if let document {
                            meshCard(document)
                            diagnosticsCard(document)
                        }

                        featureCard(record)
                        symmetryCard(record)
                        actions(record)
                    }
                    .padding(16)
                    .padding(.bottom, 28)
                }
                .background(Color.black.ignoresSafeArea())
                .navigationTitle(record.savedAt.formatted(date: .abbreviated, time: .omitted))
                .navigationBarTitleDisplayMode(.inline)
                .task {
                    document = historyStore.document(for: record)
                }
            } else {
                VStack(spacing: 12) { Image(systemName: "trash").font(.largeTitle); Text("Анализ удалён").font(.headline) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.ignoresSafeArea())
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showingMetadataEditor) {
            metadataSheet
        }
        .confirmationDialog(
            "Удалить этот анализ?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let record = historyStore.record(id: recordID) {
                    historyStore.delete(record)
                }
                dismiss()
            }
        }
    }

    private func scoreCard(_ record: SavedScanRecord) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(record.categoryIsFinal ? "ФИНАЛЬНЫЙ PSL" : "АНАЛИЗ")
                    .font(.caption2.bold())
                    .foregroundStyle(accent)
                Text(String(format: "%.2f", record.score))
                    .font(.system(size: 54, weight: .black, design: .rounded))
                Text(String(format: "Диапазон %.2f–%.2f", record.scoreRangeLow, record.scoreRangeHigh))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.52))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Text(record.category)
                    .font(.headline.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(record.categoryIsFinal ? accent : Color.yellow, in: Capsule())
                Text("Repeatability \(record.repeatabilityScore)%")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.52))
            }
        }
        .padding(17)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
    }

    private func baselineAndComparison(_ record: SavedScanRecord) -> some View {
        VStack(spacing: 10) {
            Button {
                historyStore.setBaseline(record)
            } label: {
                HStack {
                    Label(
                        record.isBaseline == true ? "Это базовый анализ" : "Сделать базовым",
                        systemImage: record.isBaseline == true ? "bookmark.fill" : "bookmark"
                    )
                    Spacer()
                    if record.isBaseline == true {
                        Image(systemName: "checkmark")
                    }
                }
                .padding(14)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 15))
            }
            .foregroundStyle(record.isBaseline == true ? accent : .white)
            .disabled(record.isBaseline == true)

            if let baseline = historyStore.baselineRecord, baseline.id != record.id {
                NavigationLink {
                    CompareScansView(initialBaselineID: baseline.id, initialTargetID: record.id)
                } label: {
                    HStack {
                        Label("Сравнить с базовым", systemImage: "arrow.left.and.right.square")
                        Spacer()
                        Text(String(format: "%@%.2f PSL", record.score - baseline.score >= 0 ? "+" : "", record.score - baseline.score))
                            .font(.subheadline.bold().monospacedDigit())
                    }
                    .padding(14)
                    .background(accent, in: RoundedRectangle(cornerRadius: 15))
                    .foregroundStyle(.black)
                }
            } else if let previous = historyStore.previousRecord(before: record) {
                NavigationLink {
                    CompareScansView(initialBaselineID: previous.id, initialTargetID: record.id)
                } label: {
                    Label("Сравнить с предыдущим", systemImage: "arrow.left.and.right.square")
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(accent, in: RoundedRectangle(cornerRadius: 15))
                        .foregroundStyle(.black)
                }
            }
        }
        .font(.subheadline.bold())
    }

    private func notesCard(_ record: SavedScanRecord) -> some View {
        Button {
            note = record.note ?? ""
            if let weight = record.weightKG {
                weightText = String(format: "%.1f", weight)
            } else {
                weightText = ""
            }
            showingMetadataEditor = true
        } label: {
            HStack(alignment: .top) {
                Image(systemName: "note.text")
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Заметки")
                        .font(.subheadline.bold())
                    if let weight = record.weightKG {
                        Text(String(format: "Вес: %.1f кг", weight))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Text(record.note ?? "Добавить условия скана, вес или комментарий")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(record.note == nil ? 0.42 : 0.62))
                        .lineLimit(3)
                }
                Spacer()
                Image(systemName: "pencil")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(14)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private func meshCard(_ document: FaceScanDocument) -> some View {
        VStack(spacing: 12) {
            MeshPreviewView(document: document, mode: meshMode)
                .frame(height: 300)
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
        }
        .padding(14)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
    }

    private func diagnosticsCard(_ document: FaceScanDocument) -> some View {
        let metricConfidence = document.metrics.featureMetrics.map(\.confidence)
        let averageConfidence = metricConfidence.isEmpty
            ? 0
            : metricConfidence.reduce(0, +) / metricConfidence.count

        return VStack(alignment: .leading, spacing: 12) {
            Label("Диагностика измерения", systemImage: "stethoscope")
                .font(.headline)
                .foregroundStyle(accent)

            diagnosticRow("Depth Fusion", document.metrics.depthFusion.applied ? "ACTIVE" : "FALLBACK")
            diagnosticRow("Покрытие глубиной", String(format: "%.1f%%", document.metrics.depthFusion.coveragePercent))
            diagnosticRow("Медианная ошибка серии", String(format: "%.2f мм", document.metrics.repeatability.medianVertexDeviationMM))
            diagnosticRow("P90 ошибки серии", String(format: "%.2f мм", document.metrics.repeatability.p90VertexDeviationMM))
            diagnosticRow("Средний confidence метрик", "\(averageConfidence)%")

            ForEach(document.metrics.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange.opacity(0.88))
            }
        }
        .padding(15)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.bold().monospacedDigit())
        }
    }

    private func featureCard(_ record: SavedScanRecord) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("3D-метрики", systemImage: "ruler")
                .font(.headline)
                .foregroundStyle(accent)

            ForEach(record.featureMetrics) { metric in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(metric.title)
                            .font(.subheadline.bold())
                        Text(String(format: "%.2f %@ · Confidence %d%%", metric.rawValue, metric.rawUnit, metric.confidence))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    Spacer()
                    Text(String(format: "%.0f", metric.score))
                        .font(.headline.monospacedDigit())
                }
                Divider().overlay(.white.opacity(0.08))
            }
        }
        .padding(15)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
    }

    private func symmetryCard(_ record: SavedScanRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Региональная симметрия", systemImage: "face.smiling")
                .font(.headline)
                .foregroundStyle(accent)

            ForEach(record.regionalSymmetry) { region in
                HStack {
                    Text(region.title)
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f мм", region.errorMM))
                        .font(.subheadline.bold().monospacedDigit())
                }
            }
        }
        .padding(15)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
    }

    private func actions(_ record: SavedScanRecord) -> some View {
        VStack(spacing: 10) {
            Button {
                if let url = historyStore.exportURL(for: record) {
                    shareItems = [url]
                    showingShareSheet = true
                }
            } label: {
                Label("Экспорт JSON", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HistoryPrimaryButtonStyle(accent: accent))

            Button {
                if let document,
                   let url = PDFReportGenerator.makeReport(record: record, document: document) {
                    shareItems = [url]
                    showingShareSheet = true
                }
            } label: {
                Label("PDF-отчёт", systemImage: "doc.richtext")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HistorySecondaryButtonStyle())

            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Удалить анализ", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HistorySecondaryButtonStyle())
        }
    }

    private var metadataSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("Вес, кг — необязательно", text: $weightText)
                    .keyboardType(.decimalPad)
                    .padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                TextEditor(text: $note)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                Text("Заметка хранится только на устройстве. Она не доказывает причину изменения метрик.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.46))

                Button {
                    let normalized = weightText.replacingOccurrences(of: ",", with: ".")
                    historyStore.updateMetadata(
                        recordID: recordID,
                        note: note,
                        weightKG: Double(normalized)
                    )
                    showingMetadataEditor = false
                } label: {
                    Text("Сохранить")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(accent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.black)
                }

                Spacer()
            }
            .padding(20)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Заметка анализа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showingMetadataEditor = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct HistoryPrimaryButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 13)
            .background(accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.black)
    }
}

private struct HistorySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 13)
            .background(.white.opacity(configuration.isPressed ? 0.06 : 0.11), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
    }
}
