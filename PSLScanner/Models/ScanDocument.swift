import Foundation

struct ScanVector: Codable {
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

struct ScanMetrics: Codable {
    let scanQuality: Int
    let reliability: String
    let overallPSLScore: Float
    let scoreRangeLow: Float
    let scoreRangeHigh: Float
    let category: String
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
    let featureMetrics: [FeatureMetric]
    let warnings: [String]
}

struct FaceScanDocument: Codable {
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
    let symmetryErrorMM: Float
    let stabilityErrorMM: Float
    let widthMM: Float
    let heightMM: Float
    let depthMM: Float
    let yawCoverageDegrees: Float
    let acceptedFrames: Int
    let featureMetrics: [FeatureMetric]
    let warnings: [String]
}
