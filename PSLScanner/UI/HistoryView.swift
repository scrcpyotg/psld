import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var historyStore: ScanHistoryStore
    @Binding var selectedTab: RootTab
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

                            ForEach(historyStore.records) { record in
                                NavigationLink {
                                    HistoryDetailView(record: record)
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
                Text(record.savedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.bold())

                HStack(spacing: 10) {
                    Label("\(record.quality)/100", systemImage: "camera.metering.matrix")
                    Label("\(record.repeatabilityScore)%", systemImage: "checkmark.shield")
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
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct HistoryDetailView: View {
    @EnvironmentObject private var historyStore: ScanHistoryStore
    let record: SavedScanRecord

    @State private var document: FaceScanDocument?
    @State private var meshMode: MeshDisplayMode = .fused
    @State private var showingShareSheet = false
    @State private var shareItems = [Any]()
    @State private var showingDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss

    private let accent = Color(red: 0.56, green: 1.0, blue: 0.25)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                scoreCard
                comparisonCard

                if let document {
                    meshCard(document)
                }

                featureCard
                symmetryCard
                actions
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
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: shareItems)
        }
        .confirmationDialog(
            "Удалить этот анализ?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                historyStore.delete(record)
                dismiss()
            }
        }
    }

    private var scoreCard: some View {
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

    @ViewBuilder
    private var comparisonCard: some View {
        if let previous = historyStore.previousRecord(before: record) {
            let delta = record.score - previous.score
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Сравнение с предыдущим")
                        .font(.subheadline.bold())
                    Text(previous.savedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Text(String(format: "%@%.2f", delta >= 0 ? "+" : "", delta))
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(abs(delta) < 0.15 ? Color.white.opacity(0.64) : (delta > 0 ? accent : .orange))
            }
            .padding(14)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 17))
        }
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

    private var featureCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("3D-метрики", systemImage: "ruler")
                .font(.headline)
                .foregroundStyle(accent)

            ForEach(record.featureMetrics) { metric in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(metric.title)
                            .font(.subheadline.bold())
                        Text("Confidence \(metric.confidence)%")
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

    private var symmetryCard: some View {
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

    private var actions: some View {
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

            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Удалить анализ", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HistorySecondaryButtonStyle())
        }
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
