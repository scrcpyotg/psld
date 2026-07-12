import Foundation
import simd

enum ReliabilityAnalyzer {
    static let requiredScanCount = 3

    static func consolidate(
        documents: [FaceScanDocument],
        requiredScanCount: Int = requiredScanCount
    ) -> (document: FaceScanDocument, summary: ScanSummary) {
        guard let latest = documents.last else {
            fatalError("ReliabilityAnalyzer requires at least one document")
        }

        let compatible = documents.filter {
            $0.vertexCount == latest.vertexCount &&
            $0.vertices.count == latest.vertices.count &&
            $0.arkitVertices.count == latest.arkitVertices.count &&
            $0.triangleIndices == latest.triangleIndices
        }

        let count = compatible.count
        let completed = count >= requiredScanCount
        let finalSet = Array(compatible.suffix(requiredScanCount))
        let meshes = finalSet.map { $0.vertices.map(simdVector) }
        let baseMeshes = finalSet.map { $0.arkitVertices.map(simdVector) }

        let consensusMesh = coordinateMedianMesh(meshes)
        let consensusBaseMesh = coordinateMedianMesh(baseMeshes)
        let vertexDeviationMM = vertexDeviation(
            meshes: meshes,
            consensus: consensusMesh
        )

        let medianDeviation = percentile(vertexDeviationMM, fraction: 0.50)
        let p90Deviation = percentile(vertexDeviationMM, fraction: 0.90)
        let stablePercent: Float
        if vertexDeviationMM.isEmpty {
            stablePercent = 0
        } else {
            let stableCount = vertexDeviationMM.filter { $0 <= 1.80 }.count
            stablePercent = Float(stableCount) / Float(vertexDeviationMM.count) * 100
        }

        let scanScores = finalSet.map { $0.metrics.overallPSLScore }
        let scanQualities = finalSet.map { $0.metrics.scanQuality }
        let scoreSpread = (scanScores.max() ?? 0) - (scanScores.min() ?? 0)

        let repeatabilityScore = makeRepeatabilityScore(
            scanCount: count,
            requiredScanCount: requiredScanCount,
            medianDeviationMM: medianDeviation,
            p90DeviationMM: p90Deviation,
            stableVertexPercent: stablePercent,
            scoreSpread: scoreSpread
        )

        let passed = completed &&
            medianDeviation <= 1.60 &&
            p90Deviation <= 3.50 &&
            stablePercent >= 74 &&
            scoreSpread <= 0.90

        let status: String
        if !completed {
            status = "Предварительно: выполнено \(count) из \(requiredScanCount) сканов."
        } else if passed {
            status = "Три скана согласуются. Итоговая категория разблокирована."
        } else {
            status = "Сканы расходятся сильнее допуска. Итоговая категория скрыта."
        }

        let repeatability = RepeatabilityMetrics(
            scanCount: count,
            requiredScanCount: requiredScanCount,
            complete: completed,
            passed: passed,
            score: repeatabilityScore,
            medianVertexDeviationMM: medianDeviation,
            p90VertexDeviationMM: p90Deviation,
            stableVertexPercent: stablePercent,
            scoreSpread: scoreSpread,
            scanScores: scanScores,
            scanQualities: scanQualities,
            vertexDeviationMM: vertexDeviationMM,
            status: status
        )

        let finalScore = median(scanScores.isEmpty ? [latest.metrics.overallPSLScore] : scanScores)
        let averagedFeatures = aggregateFeatures(finalSet.map { $0.metrics.featureMetrics })
        let quality = Int(median(scanQualities.map { Float($0) }).rounded())
        let finalCategory: String
        let categoryIsFinal: Bool

        if !completed {
            finalCategory = "ПРЕДВАРИТЕЛЬНО"
            categoryIsFinal = false
        } else if passed {
            finalCategory = category(for: finalScore)
            categoryIsFinal = true
        } else {
            finalCategory = "НЕТ ЗАМЕРА"
            categoryIsFinal = false
        }

        let reliability: String
        if passed && repeatabilityScore >= 86 && quality >= 80 {
            reliability = "Высокая"
        } else if completed && repeatabilityScore >= 66 {
            reliability = "Средняя"
        } else {
            reliability = "Предварительная"
        }

        let crossScanUncertainty = completed
            ? max(0.16, scoreSpread * 0.60 + medianDeviation * 0.10)
            : max(0.48, latest.metrics.scoreRangeHigh - latest.metrics.overallPSLScore)
        let low = clamp(finalScore - crossScanUncertainty, lower: 1, upper: 10)
        let high = clamp(finalScore + crossScanUncertainty, lower: 1, upper: 10)

        var warnings = latest.metrics.warnings.filter {
            !$0.hasPrefix("Повторяемость:")
        }
        warnings.insert("Повторяемость: \(status)", at: 0)

        if completed && !passed {
            if medianDeviation > 1.60 {
                warnings.append("Медианное расхождение сетки выше 1.6 мм.")
            }
            if p90Deviation > 3.50 {
                warnings.append("В нестабильных зонах 90-й перцентиль превышает 3.5 мм.")
            }
            if stablePercent < 74 {
                warnings.append("Менее 74% вершин повторяются в пределах 1.8 мм.")
            }
            if scoreSpread > 0.90 {
                warnings.append("Разброс предварительного балла между сканами превышает 0.9.")
            }
        }

        let selectedMesh = completed && !consensusMesh.isEmpty
            ? consensusMesh.map(scanVector)
            : latest.vertices
        let selectedBaseMesh = completed && !consensusBaseMesh.isEmpty
            ? consensusBaseMesh.map(scanVector)
            : latest.arkitVertices

        let selectedSymmetry = completed
            ? median(finalSet.map { $0.metrics.symmetryErrorMM })
            : latest.metrics.symmetryErrorMM
        let selectedStability = completed
            ? median(finalSet.map { $0.metrics.stabilityErrorMM })
            : latest.metrics.stabilityErrorMM
        let selectedWidth = completed
            ? median(finalSet.map { $0.metrics.widthMM })
            : latest.metrics.widthMM
        let selectedHeight = completed
            ? median(finalSet.map { $0.metrics.heightMM })
            : latest.metrics.heightMM
        let selectedDepth = completed
            ? median(finalSet.map { $0.metrics.depthMM })
            : latest.metrics.depthMM
        let selectedYaw = completed
            ? median(finalSet.map { $0.metrics.yawCoverageDegrees })
            : latest.metrics.yawCoverageDegrees
        let selectedAccepted = completed
            ? Int(median(finalSet.map { Float($0.metrics.acceptedFrames) }).rounded())
            : latest.metrics.acceptedFrames

        let metrics = ScanMetrics(
            scanQuality: quality,
            reliability: reliability,
            overallPSLScore: finalScore,
            scoreRangeLow: low,
            scoreRangeHigh: high,
            category: finalCategory,
            categoryIsFinal: categoryIsFinal,
            symmetryErrorMM: selectedSymmetry,
            stabilityErrorMM: selectedStability,
            widthMM: selectedWidth,
            heightMM: selectedHeight,
            depthMM: selectedDepth,
            widthHeightRatio: selectedWidth / max(selectedHeight, 0.001),
            depthWidthRatio: selectedDepth / max(selectedWidth, 0.001),
            yawCoverageDegrees: selectedYaw,
            acceptedFrames: selectedAccepted,
            rejectedFrames: latest.metrics.rejectedFrames,
            depthFrames: latest.metrics.depthFrames,
            depthFusion: latest.metrics.depthFusion,
            repeatability: repeatability,
            featureMetrics: averagedFeatures.isEmpty ? latest.metrics.featureMetrics : averagedFeatures,
            warnings: warnings
        )

        let document = FaceScanDocument(
            format: "psl-truedepth-reliability-session",
            version: 4,
            createdAt: Date(),
            deviceModel: latest.deviceModel,
            operatingSystem: latest.operatingSystem,
            coordinateSystem: latest.coordinateSystem,
            units: latest.units,
            vertexCount: latest.vertexCount,
            triangleCount: latest.triangleCount,
            metrics: metrics,
            vertices: selectedMesh,
            arkitVertices: selectedBaseMesh,
            triangleIndices: latest.triangleIndices,
            notice: latest.notice + " Итоговая категория считается финальной только после трёх согласованных сканов."
        )

        return (document, makeSummary(document))
    }

    static func makeSummary(_ document: FaceScanDocument) -> ScanSummary {
        let metrics = document.metrics
        return ScanSummary(
            quality: metrics.scanQuality,
            reliability: metrics.reliability,
            pslScore: metrics.overallPSLScore,
            scoreRangeLow: metrics.scoreRangeLow,
            scoreRangeHigh: metrics.scoreRangeHigh,
            category: metrics.category,
            categoryIsFinal: metrics.categoryIsFinal,
            symmetryErrorMM: metrics.symmetryErrorMM,
            stabilityErrorMM: metrics.stabilityErrorMM,
            widthMM: metrics.widthMM,
            heightMM: metrics.heightMM,
            depthMM: metrics.depthMM,
            yawCoverageDegrees: metrics.yawCoverageDegrees,
            acceptedFrames: metrics.acceptedFrames,
            depthFusion: metrics.depthFusion,
            repeatability: metrics.repeatability,
            featureMetrics: metrics.featureMetrics,
            warnings: metrics.warnings
        )
    }

    private static func aggregateFeatures(_ groups: [[FeatureMetric]]) -> [FeatureMetric] {
        guard let reference = groups.first else { return [] }

        return reference.compactMap { metric in
            let matches = groups.compactMap { group in
                group.first { $0.id == metric.id }
            }
            guard !matches.isEmpty else { return nil }

            return FeatureMetric(
                id: metric.id,
                title: metric.title,
                score: median(matches.map { $0.score }),
                rawValue: median(matches.map { $0.rawValue }),
                rawUnit: metric.rawUnit,
                explanation: metric.explanation
            )
        }
    }

    private static func coordinateMedianMesh(_ meshes: [[SIMD3<Float>]]) -> [SIMD3<Float>] {
        guard let first = meshes.first, !first.isEmpty else { return [] }
        guard meshes.allSatisfy({ $0.count == first.count }) else { return [] }

        return first.indices.map { index in
            SIMD3<Float>(
                median(meshes.map { $0[index].x }),
                median(meshes.map { $0[index].y }),
                median(meshes.map { $0[index].z })
            )
        }
    }

    private static func vertexDeviation(
        meshes: [[SIMD3<Float>]],
        consensus: [SIMD3<Float>]
    ) -> [Float] {
        guard meshes.count >= 2, !consensus.isEmpty else {
            return Array(repeating: 0, count: consensus.count)
        }

        return consensus.indices.map { index in
            let distances = meshes.map {
                simd_distance($0[index], consensus[index]) * 1000
            }
            return median(distances)
        }
    }

    private static func makeRepeatabilityScore(
        scanCount: Int,
        requiredScanCount: Int,
        medianDeviationMM: Float,
        p90DeviationMM: Float,
        stableVertexPercent: Float,
        scoreSpread: Float
    ) -> Int {
        guard scanCount >= 2 else { return 0 }

        let medianScore = clamp(1 - medianDeviationMM / 2.6, lower: 0, upper: 1)
        let tailScore = clamp(1 - p90DeviationMM / 5.2, lower: 0, upper: 1)
        let stableScore = clamp(stableVertexPercent / 100, lower: 0, upper: 1)
        let scoreAgreement = clamp(1 - scoreSpread / 1.5, lower: 0, upper: 1)
        let completeness = clamp(
            Float(scanCount) / Float(max(requiredScanCount, 1)),
            lower: 0,
            upper: 1
        )

        let value = (
            medianScore * 0.34 +
            tailScore * 0.24 +
            stableScore * 0.22 +
            scoreAgreement * 0.12 +
            completeness * 0.08
        ) * 100

        return Int(clamp(value.rounded(), lower: 0, upper: 100))
    }

    private static func category(for score: Float) -> String {
        switch score {
        case ..<3.0: return "SUB 3"
        case ..<4.5: return "SUB 5"
        case ..<5.3: return "LTN"
        case ..<6.1: return "MTN"
        case ..<7.1: return "HTN"
        default: return "CHAD"
        }
    }

    private static func simdVector(_ value: ScanVector) -> SIMD3<Float> {
        SIMD3<Float>(value.x, value.y, value.z)
    }

    private static func scanVector(_ value: SIMD3<Float>) -> ScanVector {
        ScanVector(x: value.x, y: value.y, z: value.z)
    }

    private static func percentile(_ values: [Float], fraction: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = clamp(fraction, lower: 0, upper: 1)
        let index = min(
            sorted.count - 1,
            Int((Float(sorted.count - 1) * clamped).rounded())
        )
        return sorted[index]
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func clamp<T: Comparable>(
        _ value: T,
        lower: T,
        upper: T
    ) -> T {
        min(max(value, lower), upper)
    }
}
