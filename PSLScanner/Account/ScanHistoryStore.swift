import Foundation
import Combine
import CryptoKit
import Security

struct SavedScanRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var profileID: UUID
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
    var documentFileName: String
    var note: String?
    var weightKG: Double?
    var isBaseline: Bool?
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
    @Published var lastMessage: String?

    let maximumRecordCount = 50

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
                documentFileName: fileName,
                note: nil,
                weightKG: nil,
                isBaseline: records.isEmpty
            )

            records.insert(record, at: 0)
            trimOldRecordsIfNeeded()
            persistIndex()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func record(id: UUID) -> SavedScanRecord? {
        records.first { $0.id == id }
    }

    var baselineRecord: SavedScanRecord? {
        records.first { $0.isBaseline == true }
    }

    func setBaseline(_ record: SavedScanRecord) {
        for index in records.indices {
            records[index].isBaseline = records[index].id == record.id
        }
        persistIndex()
        lastMessage = "Базовый анализ установлен."
    }

    func updateMetadata(recordID: UUID, note: String, weightKG: Double?) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        let cleanNote = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        records[index].note = cleanNote.isEmpty ? nil : cleanNote
        if let weightKG, weightKG >= 25, weightKG <= 350 {
            records[index].weightKG = weightKG
        } else {
            records[index].weightKG = nil
        }
        persistIndex()
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
        let wasBaseline = record.isBaseline == true
        records.removeAll { $0.id == record.id }
        let url = try? scansDirectory(profileID: profileID)
            .appendingPathComponent(record.documentFileName)
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        if wasBaseline, !records.isEmpty {
            records[records.count - 1].isBaseline = true
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
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return nil }
        let nextIndex = records.index(after: index)
        guard records.indices.contains(nextIndex) else { return nil }
        return records[nextIndex]
    }

    func createEncryptedBackup(password: String) -> URL? {
        guard let profileID else {
            lastError = "Профиль не выбран."
            return nil
        }
        guard password.count >= 6 else {
            lastError = "Пароль резервной копии должен содержать минимум 6 символов."
            return nil
        }

        do {
            var documents = [String: Data]()
            let directory = try scansDirectory(profileID: profileID)
            for record in records {
                let url = directory.appendingPathComponent(record.documentFileName)
                if FileManager.default.fileExists(atPath: url.path) {
                    documents[record.documentFileName] = try Data(contentsOf: url)
                }
            }

            let payload = HistoryBackupPayload(
                format: "psl-account-backup",
                version: 1,
                exportedAt: Date(),
                records: records,
                documents: documents
            )
            let payloadData = try encoder.encode(payload)
            let salt = try randomData(count: 16)
            let key = deriveKey(password: password, salt: salt)
            let sealed = try AES.GCM.seal(payloadData, using: key)
            guard let combined = sealed.combined else {
                throw HistoryError.encryptionFailed
            }

            let envelope = EncryptedBackupEnvelope(
                format: "psl-encrypted-backup",
                version: 1,
                salt: salt,
                encryptedPayload: combined
            )
            let data = try encoder.encode(envelope)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmm"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PSL-Backup-\(formatter.string(from: Date())).pslbackup")
            try? FileManager.default.removeItem(at: url)
            try data.write(to: url, options: .atomic)
            lastMessage = "Зашифрованная резервная копия создана."
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func importEncryptedBackup(from url: URL, password: String) -> Bool {
        guard let profileID else {
            lastError = "Профиль не выбран."
            return false
        }
        guard password.count >= 6 else {
            lastError = "Введите пароль резервной копии."
            return false
        }

        do {
            let data = try Data(contentsOf: url)
            let envelope = try decoder.decode(EncryptedBackupEnvelope.self, from: data)
            guard envelope.format == "psl-encrypted-backup" else {
                throw HistoryError.invalidBackup
            }
            let key = deriveKey(password: password, salt: envelope.salt)
            let box = try AES.GCM.SealedBox(combined: envelope.encryptedPayload)
            let payloadData = try AES.GCM.open(box, using: key)
            let payload = try decoder.decode(HistoryBackupPayload.self, from: payloadData)
            guard payload.format == "psl-account-backup" else {
                throw HistoryError.invalidBackup
            }

            let directory = try scansDirectory(profileID: profileID)
            var importedCount = 0

            for sourceRecord in payload.records.sorted(by: { $0.savedAt < $1.savedAt }) {
                guard !records.contains(where: { $0.sourceCreatedAt == sourceRecord.sourceCreatedAt }) else { continue }
                guard let documentData = payload.documents[sourceRecord.documentFileName] else { continue }

                let newID = UUID()
                let newFileName = "scan-\(newID.uuidString).json"
                try documentData.write(
                    to: directory.appendingPathComponent(newFileName),
                    options: .atomic
                )

                let imported = SavedScanRecord(
                    id: newID,
                    profileID: profileID,
                    sourceCreatedAt: sourceRecord.sourceCreatedAt,
                    savedAt: sourceRecord.savedAt,
                    score: sourceRecord.score,
                    scoreRangeLow: sourceRecord.scoreRangeLow,
                    scoreRangeHigh: sourceRecord.scoreRangeHigh,
                    category: sourceRecord.category,
                    categoryIsFinal: sourceRecord.categoryIsFinal,
                    reliability: sourceRecord.reliability,
                    quality: sourceRecord.quality,
                    repeatabilityScore: sourceRecord.repeatabilityScore,
                    repeatabilityPassed: sourceRecord.repeatabilityPassed,
                    featureMetrics: sourceRecord.featureMetrics,
                    surfaceMeasurements: sourceRecord.surfaceMeasurements,
                    regionalSymmetry: sourceRecord.regionalSymmetry,
                    documentFileName: newFileName,
                    note: sourceRecord.note,
                    weightKG: sourceRecord.weightKG,
                    isBaseline: nil
                )
                records.append(imported)
                importedCount += 1
            }

            records.sort { $0.savedAt > $1.savedAt }
            if baselineRecord == nil, !records.isEmpty {
                records[records.count - 1].isBaseline = true
            }
            trimOldRecordsIfNeeded()
            persistIndex()
            lastMessage = importedCount > 0
                ? "Импортировано анализов: \(importedCount)."
                : "Новых анализов в резервной копии нет."
            return true
        } catch {
            lastError = "Не удалось открыть резервную копию. Проверь пароль и файл."
            return false
        }
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
            if baselineRecord == nil, !records.isEmpty {
                records[records.count - 1].isBaseline = true
                persistIndex()
            }
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

    private func deriveKey(password: String, salt: Data) -> SymmetricKey {
        var material = Data(password.utf8)
        material.append(salt)
        var digest = Data(SHA256.hash(data: material))
        for _ in 0..<12_000 {
            var round = digest
            round.append(salt)
            digest = Data(SHA256.hash(data: round))
        }
        return SymmetricKey(data: digest)
    }

    private func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard result == errSecSuccess else { throw HistoryError.encryptionFailed }
        return Data(bytes)
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

private struct HistoryBackupPayload: Codable {
    let format: String
    let version: Int
    let exportedAt: Date
    let records: [SavedScanRecord]
    let documents: [String: Data]
}

private struct EncryptedBackupEnvelope: Codable {
    let format: String
    let version: Int
    let salt: Data
    let encryptedPayload: Data
}

private enum HistoryError: LocalizedError {
    case applicationSupportUnavailable
    case encryptionFailed
    case invalidBackup

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Не удалось открыть локальное хранилище приложения."
        case .encryptionFailed:
            return "Не удалось зашифровать резервную копию."
        case .invalidBackup:
            return "Формат резервной копии не поддерживается."
        }
    }
}
