import Foundation

struct ScanVector: Codable {
    let x: Float
    let y: Float
    let z: Float
}

struct ScanMetrics: Codable {
    let scanQuality: Int
    let symmetryErrorMM: Float
    let widthMM: Float
    let heightMM: Float
    let depthMM: Float
    let widthHeightRatio: Float
    let depthWidthRatio: Float
    let yawCoverageDegrees: Float
    let acceptedFrames: Int
    let rejectedFrames: Int
    let depthFrames: Int
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
    let symmetryErrorMM: Float
    let widthMM: Float
    let heightMM: Float
    let depthMM: Float
    let yawCoverageDegrees: Float
    let acceptedFrames: Int
}
