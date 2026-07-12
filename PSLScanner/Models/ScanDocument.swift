import Foundation

struct ScanVector: Codable, Hashable {
    let x: Float
    let y: Float
    let z: Float
}

struct FeatureMetric: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let score: Float
    let rawValue: Float
    let rawUnit: String
    let explanation: String
}

struct DepthFusionMetrics: Codable, Hashable {
    let applied: Bool
    let sourceFrameCount: Int
    let highQualityFrameCount: Int
    let absoluteAccuracyFrameCount: Int
    let filteredFrameCount: Int
    let refinedVertexCount: Int
    let totalVertexCount: Int
    let coveragePercent: Float
    let medianResidualMM: Float
    let temporalNoiseMM: Float
    let meanBlendWeight: Float
    let mapping: String

    static func unavailable(sourceFrameCount: Int) -> DepthFusionMetrics {
        DepthFusionMetrics(
            applied: false,
            sourceFrameCount: sourceFrameCount,
            highQualityFrameCount: 0,
            absoluteAccuracyFrameCount: 0,
            filteredFrameCount: 0,
            refinedVertexCount: 0,
            totalVertexCount: 0,
            coveragePercent: 0,
            medianResidualMM: 0,
            temporalNoiseMM: 0,
            meanBlendWeight: 0,
            mapping: "unavailable"
        )
    }
}

struct RepeatabilityMetrics: Codable, Hashable {
    let scanCount: Int
    let requiredScanCount: Int
    let complete: Bool
    let passed: Bool
    let score: Int
    let medianVertexDeviationMM: Float
    let p90VertexDeviationMM: Float
    let stableVertexPercent: Float
    let scoreSpread: Float
    let scanScores: [Float]
    let scanQualities: [Int]
    let vertexDeviationMM: [Float]
    let status: String

    static func pending(
        scanCount: Int,
        requiredScanCount: Int,
        vertexCount: Int
    ) -> RepeatabilityMetrics {
        let remaining = max(requiredScanCount - scanCount, 0)
        let status: String
        if remaining > 0 {
            status = "Нужно ещё контрольных сканов: \(remaining)."
        } else {
            status = "Ожидается расчёт повторяемости."
        }

        return RepeatabilityMetrics(
            scanCount: scanCount,
            requiredScanCount: requiredScanCount,
            complete: scanCount >= requiredScanCount,
            passed: false,
            score: 0,
            medianVertexDeviationMM: 0,
            p90VertexDeviationMM: 0,
            stableVertexPercent: 0,
            scoreSpread: 0,
            scanScores: [],
            scanQualities: [],
            vertexDeviationMM: Array(repeating: 0, count: vertexCount),
            status: status
        )
    }
}

struct ScanMetrics: Codable, Hashable {
    let scanQuality: Int
    let reliability: String
    let overallPSLScore: Float
    let scoreRangeLow: Float
    let scoreRangeHigh: Float
    let category: String
    let categoryIsFinal: Bool
    let symmetryErrorMM: Float
    let stabilityErrorMM: Float
    let widthMM: Float
    let heightMM: Float
    let depthMM: Float
    let widthHeightRatio: Float
    let depthWidthRatio: Float
    let yawCoverageDegrees: Float
    let acceptedFrames: Int
    let rejectedFrames: Int
    let depthFrames: Int
    let depthFusion: DepthFusionMetrics
    let repeatability: RepeatabilityMetrics
    let featureMetrics: [FeatureMetric]
    let warnings: [String]
}

struct FaceScanDocument: Codable, Hashable {
    let format: String
    let version: Int
    let createdAt: Date
    let deviceModel: String
    let operatingSystem: String
    let coordinateSystem: String
    let units: String
    let vertexCount: Int
    let triangleCount: Int
    let metrics: ScanMetrics
    let vertices: [ScanVector]
    let arkitVertices: [ScanVector]
    let triangleIndices: [Int]
    let notice: String
}

struct ScanSummary {
    let quality: Int
    let reliability: String
    let pslScore: Float
    let scoreRangeLow: Float
    let scoreRangeHigh: Float
    let category: String
    let categoryIsFinal: Bool
    let symmetryErrorMM: Float
    let stabilityErrorMM: Float
    let widthMM: Float
    let heightMM: Float
    let depthMM: Float
    let yawCoverageDegrees: Float
    let acceptedFrames: Int
    let depthFusion: DepthFusionMetrics
    let repeatability: RepeatabilityMetrics
    let featureMetrics: [FeatureMetric]
    let warnings: [String]
}
