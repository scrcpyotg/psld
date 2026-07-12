import Foundation
import simd

struct ComparisonMetricDelta: Identifiable, Hashable {
    let id: String
    let title: String
    let baselineValue: Float
    let targetValue: Float
    let delta: Float
    let unit: String
    let confidence: Int
}

struct ScanComparisonResult: Hashable {
    let scoreDelta: Float
    let qualityDelta: Int
    let repeatabilityDelta: Int
    let medianSurfaceChangeMM: Float
    let p90SurfaceChangeMM: Float
    let reliableVertexPercent: Float
    let signedVertexChangeMM: [Float]
    let magnitudeVertexChangeMM: [Float]
    let reliableVertices: [Bool]
    let featureDeltas: [ComparisonMetricDelta]
    let symmetryDeltas: [ComparisonMetricDelta]
    let alignedTargetVertices: [ScanVector]
}

enum ScanComparisonAnalyzer {
    static func compare(
        baseline: FaceScanDocument,
        target: FaceScanDocument
    ) -> ScanComparisonResult? {
        let count = min(baseline.vertices.count, target.vertices.count)
        guard count > 100 else { return nil }

        let base = Array(baseline.vertices.prefix(count)).map(vector)
        let current = Array(target.vertices.prefix(count)).map(vector)
        let baseAnchor = anchorCentroid(base)
        let targetAnchor = anchorCentroid(current)
        let translation = targetAnchor - baseAnchor
        let aligned = current.map { $0 - translation }

        let baseNoise = baseline.metrics.repeatability.vertexDeviationMM
        let targetNoise = target.metrics.repeatability.vertexDeviationMM

        var signed = [Float]()
        var magnitude = [Float]()
        var reliable = [Bool]()
        signed.reserveCapacity(count)
        magnitude.reserveCapacity(count)
        reliable.reserveCapacity(count)

        for index in 0..<count {
            let delta = aligned[index] - base[index]
            let signedMM = delta.z * 1000
            let magnitudeMM = simd_length(delta) * 1000
            let baseDeviation = baseNoise.indices.contains(index) ? baseNoise[index] : 0
            let targetDeviation = targetNoise.indices.contains(index) ? targetNoise[index] : 0
            let isReliable = baseDeviation <= 3.0 && targetDeviation <= 3.0 && magnitudeMM <= 12
            signed.append(signedMM)
            magnitude.append(magnitudeMM)
            reliable.append(isReliable)
        }

        let reliableMagnitudes = zip(magnitude, reliable)
            .compactMap { $0.1 ? $0.0 : nil }
        let reliablePercent = Float(reliable.filter { $0 }.count) / Float(count) * 100

        return ScanComparisonResult(
            scoreDelta: target.metrics.overallPSLScore - baseline.metrics.overallPSLScore,
            qualityDelta: target.metrics.scanQuality - baseline.metrics.scanQuality,
            repeatabilityDelta: target.metrics.repeatability.score - baseline.metrics.repeatability.score,
            medianSurfaceChangeMM: percentile(reliableMagnitudes, fraction: 0.50),
            p90SurfaceChangeMM: percentile(reliableMagnitudes, fraction: 0.90),
            reliableVertexPercent: reliablePercent,
            signedVertexChangeMM: signed,
            magnitudeVertexChangeMM: magnitude,
            reliableVertices: reliable,
            featureDeltas: featureDeltas(
                baseline: baseline.metrics.featureMetrics,
                target: target.metrics.featureMetrics
            ),
            symmetryDeltas: symmetryDeltas(
                baseline: baseline.metrics.regionalSymmetry,
                target: target.metrics.regionalSymmetry
            ),
            alignedTargetVertices: aligned.map {
                ScanVector(x: $0.x, y: $0.y, z: $0.z)
            }
        )
    }

    private static func featureDeltas(
        baseline: [FeatureMetric],
        target: [FeatureMetric]
    ) -> [ComparisonMetricDelta] {
        let baseByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        return target.compactMap { item in
            guard let base = baseByID[item.id] else { return nil }
            return ComparisonMetricDelta(
                id: item.id,
                title: item.title,
                baselineValue: base.rawValue,
                targetValue: item.rawValue,
                delta: item.rawValue - base.rawValue,
                unit: item.rawUnit,
                confidence: min(base.confidence, item.confidence)
            )
        }
    }

    private static func symmetryDeltas(
        baseline: [RegionalSymmetryMetric],
        target: [RegionalSymmetryMetric]
    ) -> [ComparisonMetricDelta] {
        let baseByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        return target.compactMap { item in
            guard let base = baseByID[item.id] else { return nil }
            return ComparisonMetricDelta(
                id: "symmetry-\(item.id)",
                title: item.title,
                baselineValue: base.errorMM,
                targetValue: item.errorMM,
                delta: item.errorMM - base.errorMM,
                unit: "мм ошибки",
                confidence: min(base.confidence, item.confidence)
            )
        }
    }

    private static func anchorCentroid(_ vertices: [SIMD3<Float>]) -> SIMD3<Float> {
        guard
            let minX = vertices.map(\.x).min(),
            let maxX = vertices.map(\.x).max(),
            let minY = vertices.map(\.y).min(),
            let maxY = vertices.map(\.y).max()
        else { return .zero }

        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        let halfWidth = max((maxX - minX) / 2, 0.0001)
        let halfHeight = max((maxY - minY) / 2, 0.0001)

        let anchors = vertices.filter {
            abs(($0.x - centerX) / halfWidth) < 0.42 &&
            (($0.y - centerY) / halfHeight) > 0.22 &&
            (($0.y - centerY) / halfHeight) < 0.82
        }
        let source = anchors.isEmpty ? vertices : anchors
        let sum = source.reduce(SIMD3<Float>.zero, +)
        return sum / Float(max(source.count, 1))
    }

    private static func vector(_ value: ScanVector) -> SIMD3<Float> {
        SIMD3<Float>(value.x, value.y, value.z)
    }

    private static func percentile(_ values: [Float], fraction: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = Float(sorted.count - 1) * max(0, min(fraction, 1))
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        guard lower != upper else { return sorted[lower] }
        let weight = position - Float(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
