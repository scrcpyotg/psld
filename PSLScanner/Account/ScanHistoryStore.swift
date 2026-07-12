import Foundation
import Combine

struct SavedScanRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let profileID: UUID
    let sourceCreatedAt: Date
    let savedAt: Date
    let score: Float
    let scoreRangeLow: Float
    let scoreRangeHigh: Float
    let category: String
    let categoryIsFinal: Bool
    let reliability: String
    let quality: Int
    let repeatabilityScore: Int
    let repeatabilityPassed: Bool
    let featureMetrics: [FeatureMetric]
    let surfaceMeasurements: [SurfaceMeasurement]
    let regionalSymmetry: [RegionalSymmetryMetric]
    let documentFileName: String
}

struct HistoryStatistics {
    let count: Int
    let finalCount: Int
    let averageScore: Float
    let bestScore: Float
    let latestScore: Float?
    let latestCategory: String?
}

final class ScanHistoryStore: ObservableObject {
    @Published private(set) var records = [SavedScanRecord]()
    @Published private(set) var profileID: UUID?
    @Published var lastError: String?

    let maximumRecordCount = 20

    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        value.dateEncodingStrategy = .iso8601
        return value
    }()

    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }()

    func configure(profileID: UUID?) {
        guard self.profileID != profileID else { return }
        self.profileID = profileID
        loadIndex()
    }

    func saveIfNeeded(_ document: FaceScanDocument) {
        guard let profileID else { return }
        guard document.metrics.repeatability.complete else { return }
        guard !records.contains(where: { $0.sourceCreatedAt == document.createdAt }) else { return }

        do {
            let id = UUID()
            let fileName = "scan-\(id.uuidString).json"
            let fileURL = try scansDirectory(profileID: profileID)
                .appendingPathComponent(fileName)
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)

            let record = SavedScanRecord(
                id: id,
                profileID: profileID,
                sourceCreatedAt: document.createdAt,
                savedAt: Date(),
                score: document.metrics.overallPSLScore,
                scoreRangeLow: document.metrics.scoreRangeLow,
                scoreRangeHigh: document.metrics.scoreRangeHigh,
                category: document.metrics.category,
                categoryIsFinal: document.metrics.categoryIsFinal,
                reliability: document.metrics.reliability,
                quality: document.metrics.scanQuality,
                repeatabilityScore: document.metrics.repeatability.score,
                repeatabilityPassed: document.metrics.repeatability.passed,
                featureMetrics: document.metrics.featureMetrics,
                surfaceMeasurements: document.metrics.surfaceMeasurements,
                regionalSymmetry: document.metrics.regionalSymmetry,
                documentFileName: fileName
            )

            records.insert(record, at: 0)
            trimOldRecordsIfNeeded()
            persistIndex()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func document(for record: SavedScanRecord) -> FaceScanDocument? {
        guard let profileID, record.profileID == profileID else { return nil }
        do {
            let url = try scansDirectory(profileID: profileID)
                .appendingPathComponent(record.documentFileName)
            let data = try Data(contentsOf: url)
            return try decoder.decode(FaceScanDocument.self, from: data)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func exportURL(for record: SavedScanRecord) -> URL? {
        guard let profileID, record.profileID == profileID else { return nil }
        return try? scansDirectory(profileID: profileID)
            .appendingPathComponent(record.documentFileName)
    }

    func delete(_ record: SavedScanRecord) {
        guard let profileID else { return }
        records.removeAll { $0.id == record.id }
        let url = try? scansDirectory(profileID: profileID)
            .appendingPathComponent(record.documentFileName)
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        persistIndex()
    }

    func deleteAll() {
        guard let profileID else { return }
        let directory = try? profileDirectory(profileID: profileID)
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        records = []
        persistIndex()
    }

    var statistics: HistoryStatistics {
        let finalRecords = records.filter(\.categoryIsFinal)
        let scores = finalRecords.map(\.score)
        return HistoryStatistics(
            count: records.count,
            finalCount: finalRecords.count,
            averageScore: scores.isEmpty ? 0 : scores.reduce(0, +) / Float(scores.count),
            bestScore: scores.max() ?? 0,
            latestScore: records.first?.score,
            latestCategory: records.first?.category
        )
    }

    func previousRecord(before record: SavedScanRecord) -> SavedScanRecord? {
        guard let index = records.firstIndex(of: record) else { return nil }
        let nextIndex = records.index(after: index)
        guard records.indices.contains(nextIndex) else { return nil }
        return records[nextIndex]
    }

    private func loadIndex() {
        guard let profileID else {
            records = []
            return
        }

        do {
            let url = try indexURL(profileID: profileID)
            guard FileManager.default.fileExists(atPath: url.path) else {
                records = []
                return
            }
            let data = try Data(contentsOf: url)
            records = try decoder.decode([SavedScanRecord].self, from: data)
                .sorted { $0.savedAt > $1.savedAt }
        } catch {
            records = []
            lastError = error.localizedDescription
        }
    }

    private func persistIndex() {
        guard let profileID else { return }
        do {
            let data = try encoder.encode(records)
            try data.write(to: try indexURL(profileID: profileID), options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func trimOldRecordsIfNeeded() {
        guard records.count > maximumRecordCount else { return }
        let removed = Array(records.dropFirst(maximumRecordCount))
        records = Array(records.prefix(maximumRecordCount))

        guard let profileID else { return }
        for record in removed {
            if let url = try? scansDirectory(profileID: profileID)
                .appendingPathComponent(record.documentFileName) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func indexURL(profileID: UUID) throws -> URL {
        try profileDirectory(profileID: profileID)
            .appendingPathComponent("index.json")
    }

    private func profileDirectory(profileID: UUID) throws -> URL {
        let base = try applicationSupportDirectory()
            .appendingPathComponent("PSLScanner", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        return base
    }

    private func scansDirectory(profileID: UUID) throws -> URL {
        let directory = try profileDirectory(profileID: profileID)
            .appendingPathComponent("Scans", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func applicationSupportDirectory() throws -> URL {
        guard let url = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw HistoryError.applicationSupportUnavailable
        }
        return url
    }
}

private enum HistoryError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        "Не удалось открыть локальное хранилище приложения."
    }
}
