import Foundation
import ARKit
import AVFoundation
import CoreVideo
import simd

struct DepthRefinedFrame {
    let points: [SIMD3<Float>]
    let validMask: [UInt8]
    let residualByVertex: [Float]
    let highQuality: Bool
    let absoluteAccuracy: Bool
    let filtered: Bool
    let mirroredMapping: Bool
}

struct DepthFusionResult {
    let mesh: [SIMD3<Float>]
    let metrics: DepthFusionMetrics
}

enum DepthFusionEngine {
    private static let minimumDepth: Float = 0.12
    private static let maximumDepth: Float = 1.20
    private static let maximumLocalCorrection: Float = 0.014

    static func capture(
        frame: ARFrame,
        face: ARFaceAnchor,
        arkitVertices: [SIMD3<Float>]
    ) -> DepthRefinedFrame? {
        guard !arkitVertices.isEmpty,
              let rawDepth = frame.capturedDepthData else {
            return nil
        }

        let depthData = rawDepth.depthDataType == kCVPixelFormatType_DepthFloat32
            ? rawDepth
            : rawDepth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)

        guard let calibration = depthData.cameraCalibrationData ?? rawDepth.cameraCalibrationData else {
            return nil
        }

        let depthMap = depthData.depthDataMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        guard width > 8, height > 8 else { return nil }

        let reference = calibration.intrinsicMatrixReferenceDimensions
        guard reference.width > 0, reference.height > 0 else { return nil }

        let scaleX = Float(width) / Float(reference.width)
        let scaleY = Float(height) / Float(reference.height)
        let intrinsic = calibration.intrinsicMatrix
        let fx = intrinsic.columns.0.x * scaleX
        let fy = intrinsic.columns.1.y * scaleY
        let cx = intrinsic.columns.2.x * scaleX
        let cy = intrinsic.columns.2.y * scaleY

        guard fx.isFinite, fy.isFinite, fx > 1, fy > 1 else { return nil }

        let cameraFromFace = simd_inverse(frame.camera.transform) * face.transform
        let faceFromCamera = simd_inverse(cameraFromFace)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        func sampleDepth(x: Int, y: Int) -> Float? {
            guard x >= 1, y >= 1, x < width - 1, y < height - 1 else { return nil }

            var values = [Float]()
            values.reserveCapacity(9)

            for dy in -1...1 {
                let row = baseAddress
                    .advanced(by: (y + dy) * bytesPerRow)
                    .assumingMemoryBound(to: Float.self)

                for dx in -1...1 {
                    let value = row[x + dx]
                    if value.isFinite,
                       value >= minimumDepth,
                       value <= maximumDepth {
                        values.append(value)
                    }
                }
            }

            guard values.count >= 3 else { return nil }
            values.sort()
            return values[values.count / 2]
        }

        func makeCandidate(mirrored: Bool) -> DepthCandidate {
            var points = Array(repeating: SIMD3<Float>.zero, count: arkitVertices.count)
            var validMask = Array(repeating: UInt8(0), count: arkitVertices.count)
            var residualByVertex = Array(repeating: Float.nan, count: arkitVertices.count)
            var residuals = [Float]()
            residuals.reserveCapacity(arkitVertices.count)

            for (index, localVertex) in arkitVertices.enumerated() {
                let camera4 = cameraFromFace * SIMD4<Float>(
                    localVertex.x,
                    localVertex.y,
                    localVertex.z,
                    1
                )
                let cameraPoint = SIMD3<Float>(camera4.x, camera4.y, camera4.z)
                let predictedDepth = -cameraPoint.z

                guard predictedDepth.isFinite,
                      predictedDepth >= minimumDepth,
                      predictedDepth <= maximumDepth else {
                    continue
                }

                let projectedU = fx * cameraPoint.x / predictedDepth + cx
                let projectedV = cy - fy * cameraPoint.y / predictedDepth
                let sampleU = mirrored ? Float(width - 1) - projectedU : projectedU

                guard sampleU.isFinite, projectedV.isFinite else { continue }

                let pixelX = Int(sampleU.rounded())
                let pixelY = Int(projectedV.rounded())
                guard let measuredDepth = sampleDepth(x: pixelX, y: pixelY) else { continue }

                let residual = abs(measuredDepth - predictedDepth)
                let residualLimit = min(0.055, max(0.020, predictedDepth * 0.12))
                guard residual <= residualLimit else { continue }

                // Keep the ARKit ray direction and replace only its measured distance.
                // This is safer than trusting a single low-resolution depth pixel for X/Y.
                let rayScale = measuredDepth / max(predictedDepth, 0.0001)
                let refinedCamera = SIMD4<Float>(
                    cameraPoint.x * rayScale,
                    cameraPoint.y * rayScale,
                    -measuredDepth,
                    1
                )
                let refinedLocal4 = faceFromCamera * refinedCamera
                let refinedLocal = SIMD3<Float>(
                    refinedLocal4.x,
                    refinedLocal4.y,
                    refinedLocal4.z
                )

                guard refinedLocal.x.isFinite,
                      refinedLocal.y.isFinite,
                      refinedLocal.z.isFinite else {
                    continue
                }

                let correction = simd_distance(refinedLocal, localVertex)
                guard correction <= 0.032 else { continue }

                points[index] = refinedLocal
                validMask[index] = 1
                residualByVertex[index] = residual
                residuals.append(residual)
            }

            return DepthCandidate(
                points: points,
                validMask: validMask,
                residualByVertex: residualByVertex,
                validCount: residuals.count,
                medianResidual: median(residuals),
                mirrored: mirrored
            )
        }

        let normal = makeCandidate(mirrored: false)
        let mirrored = makeCandidate(mirrored: true)
        let chosen = chooseCandidate(normal: normal, mirrored: mirrored)
        let minimumValid = max(70, arkitVertices.count / 10)

        guard chosen.validCount >= minimumValid,
              chosen.medianResidual <= 0.040 else {
            return nil
        }

        return DepthRefinedFrame(
            points: chosen.points,
            validMask: chosen.validMask,
            residualByVertex: chosen.residualByVertex,
            highQuality: depthData.depthDataQuality == .high,
            absoluteAccuracy: depthData.depthDataAccuracy == .absolute,
            filtered: depthData.isDepthDataFiltered,
            mirroredMapping: chosen.mirrored
        )
    }

    static func fuse(
        baseMesh: [SIMD3<Float>],
        frames: [DepthRefinedFrame],
        triangleIndices: [Int]
    ) -> DepthFusionResult {
        guard !baseMesh.isEmpty, !frames.isEmpty else {
            return DepthFusionResult(
                mesh: baseMesh,
                metrics: DepthFusionMetrics.unavailable(sourceFrameCount: frames.count)
            )
        }

        let vertexCount = baseMesh.count
        let usableFrames = frames.filter {
            $0.points.count == vertexCount &&
            $0.validMask.count == vertexCount &&
            $0.residualByVertex.count == vertexCount
        }

        guard !usableFrames.isEmpty else {
            return DepthFusionResult(
                mesh: baseMesh,
                metrics: DepthFusionMetrics.unavailable(sourceFrameCount: frames.count)
            )
        }

        let minimumSamples = max(4, min(10, usableFrames.count / 4))
        var rawCorrections = Array(repeating: SIMD3<Float>.zero, count: vertexCount)
        var correctionWeights = Array(repeating: Float.zero, count: vertexCount)
        var refinedMask = Array(repeating: UInt8(0), count: vertexCount)
        var allResiduals = [Float]()
        var allTemporalNoise = [Float]()
        var blendWeights = [Float]()

        for vertexIndex in 0..<vertexCount {
            var values = [SIMD3<Float>]()
            var residuals = [Float]()
            values.reserveCapacity(usableFrames.count)
            residuals.reserveCapacity(usableFrames.count)

            for frame in usableFrames where frame.validMask[vertexIndex] == 1 {
                values.append(frame.points[vertexIndex])
                let residual = frame.residualByVertex[vertexIndex]
                if residual.isFinite {
                    residuals.append(residual)
                }
            }

            guard values.count >= minimumSamples else { continue }

            let depthMedian = vectorMedian(values)
            let temporalDistances = values.map { simd_distance($0, depthMedian) }
            let temporalNoise = median(temporalDistances)
            let residual = median(residuals)

            guard temporalNoise <= 0.012,
                  residual <= 0.035 else {
                continue
            }

            var correction = depthMedian - baseMesh[vertexIndex]
            let correctionLength = simd_length(correction)
            guard correctionLength.isFinite, correctionLength <= 0.030 else { continue }

            if correctionLength > maximumLocalCorrection {
                correction *= maximumLocalCorrection / correctionLength
            }

            let sampleConfidence = min(1, Float(values.count) / 18)
            let residualConfidence = clamp(1 - residual / 0.030, lower: 0, upper: 1)
            let temporalConfidence = clamp(1 - temporalNoise / 0.009, lower: 0, upper: 1)
            let blendWeight = clamp(
                0.16 + 0.54 * sampleConfidence * residualConfidence * temporalConfidence,
                lower: 0.12,
                upper: 0.70
            )

            rawCorrections[vertexIndex] = correction
            correctionWeights[vertexIndex] = blendWeight
            refinedMask[vertexIndex] = 1
            allResiduals.append(residual)
            allTemporalNoise.append(temporalNoise)
            blendWeights.append(blendWeight)
        }

        let refinedCount = refinedMask.reduce(0) { $0 + Int($1) }
        let coveragePercent = Float(refinedCount) / Float(max(vertexCount, 1)) * 100
        let medianResidualMM = median(allResiduals) * 1000
        let temporalNoiseMM = median(allTemporalNoise) * 1000
        let meanBlendWeight = blendWeights.isEmpty
            ? 0
            : blendWeights.reduce(0, +) / Float(blendWeights.count)

        let applied =
            usableFrames.count >= 8 &&
            coveragePercent >= 18 &&
            medianResidualMM <= 25 &&
            temporalNoiseMM <= 8

        guard applied else {
            return DepthFusionResult(
                mesh: baseMesh,
                metrics: makeMetrics(
                    applied: false,
                    frames: usableFrames,
                    refinedCount: refinedCount,
                    vertexCount: vertexCount,
                    coveragePercent: coveragePercent,
                    medianResidualMM: medianResidualMM,
                    temporalNoiseMM: temporalNoiseMM,
                    meanBlendWeight: meanBlendWeight
                )
            )
        }

        let neighbors = buildNeighbors(
            vertexCount: vertexCount,
            triangleIndices: triangleIndices
        )
        var smoothedCorrections = rawCorrections

        for index in 0..<vertexCount where refinedMask[index] == 1 {
            let validNeighbors = neighbors[index].filter { refinedMask[$0] == 1 }
            guard !validNeighbors.isEmpty else { continue }

            var neighborAverage = SIMD3<Float>.zero
            for neighbor in validNeighbors {
                neighborAverage += rawCorrections[neighbor]
            }
            neighborAverage /= Float(validNeighbors.count)

            var smoothed = rawCorrections[index] * 0.78 + neighborAverage * 0.22
            let length = simd_length(smoothed)
            if length > maximumLocalCorrection {
                smoothed *= maximumLocalCorrection / length
            }
            smoothedCorrections[index] = smoothed
        }

        var fusedMesh = baseMesh
        for index in 0..<vertexCount where refinedMask[index] == 1 {
            fusedMesh[index] += smoothedCorrections[index] * correctionWeights[index]
        }

        return DepthFusionResult(
            mesh: fusedMesh,
            metrics: makeMetrics(
                applied: true,
                frames: usableFrames,
                refinedCount: refinedCount,
                vertexCount: vertexCount,
                coveragePercent: coveragePercent,
                medianResidualMM: medianResidualMM,
                temporalNoiseMM: temporalNoiseMM,
                meanBlendWeight: meanBlendWeight
            )
        )
    }

    private static func chooseCandidate(
        normal: DepthCandidate,
        mirrored: DepthCandidate
    ) -> DepthCandidate {
        let countDifference = abs(normal.validCount - mirrored.validCount)
        let meaningfulCountDifference = max(12, max(normal.validCount, mirrored.validCount) / 12)

        if countDifference >= meaningfulCountDifference {
            return normal.validCount > mirrored.validCount ? normal : mirrored
        }

        return normal.medianResidual <= mirrored.medianResidual ? normal : mirrored
    }

    private static func makeMetrics(
        applied: Bool,
        frames: [DepthRefinedFrame],
        refinedCount: Int,
        vertexCount: Int,
        coveragePercent: Float,
        medianResidualMM: Float,
        temporalNoiseMM: Float,
        meanBlendWeight: Float
    ) -> DepthFusionMetrics {
        let mirroredCount = frames.filter { $0.mirroredMapping }.count
        let mapping = mirroredCount > frames.count / 2 ? "mirrored" : "native"

        return DepthFusionMetrics(
            applied: applied,
            sourceFrameCount: frames.count,
            highQualityFrameCount: frames.filter { $0.highQuality }.count,
            absoluteAccuracyFrameCount: frames.filter { $0.absoluteAccuracy }.count,
            filteredFrameCount: frames.filter { $0.filtered }.count,
            refinedVertexCount: refinedCount,
            totalVertexCount: vertexCount,
            coveragePercent: coveragePercent,
            medianResidualMM: medianResidualMM,
            temporalNoiseMM: temporalNoiseMM,
            meanBlendWeight: meanBlendWeight,
            mapping: mapping
        )
    }

    private static func buildNeighbors(
        vertexCount: Int,
        triangleIndices: [Int]
    ) -> [[Int]] {
        var sets = Array(repeating: Set<Int>(), count: vertexCount)
        var index = 0

        while index + 2 < triangleIndices.count {
            let a = triangleIndices[index]
            let b = triangleIndices[index + 1]
            let c = triangleIndices[index + 2]
            index += 3

            guard a >= 0, b >= 0, c >= 0,
                  a < vertexCount, b < vertexCount, c < vertexCount else {
                continue
            }

            sets[a].insert(b)
            sets[a].insert(c)
            sets[b].insert(a)
            sets[b].insert(c)
            sets[c].insert(a)
            sets[c].insert(b)
        }

        return sets.map(Array.init)
    }

    private static func vectorMedian(_ values: [SIMD3<Float>]) -> SIMD3<Float> {
        SIMD3<Float>(
            median(values.map(\.x)),
            median(values.map(\.y)),
            median(values.map(\.z))
        )
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

private struct DepthCandidate {
    let points: [SIMD3<Float>]
    let validMask: [UInt8]
    let residualByVertex: [Float]
    let validCount: Int
    let medianResidual: Float
    let mirrored: Bool
}
