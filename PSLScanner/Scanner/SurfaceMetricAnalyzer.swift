import Foundation
import simd

struct SurfaceAnalysisResult {
    let pslScore: Float
    let scoreRangeLow: Float
    let scoreRangeHigh: Float
    let category: String
    let reliability: String
    let features: [FeatureMetric]
    let measurements: [SurfaceMeasurement]
    let regionalSymmetry: [RegionalSymmetryMetric]
    let surfaceMaps: SurfaceMapData
    let warnings: [String]

    static func empty(vertexCount: Int) -> SurfaceAnalysisResult {
        SurfaceAnalysisResult(
            pslScore: 1,
            scoreRangeLow: 1,
            scoreRangeHigh: 1,
            category: "НЕТ ЗАМЕРА",
            reliability: "Низкая",
            features: [],
            measurements: [],
            regionalSymmetry: [],
            surfaceMaps: .empty(vertexCount: vertexCount),
            warnings: ["Не удалось выделить поверхность лица для расчёта."]
        )
    }
}

enum SurfaceMetricAnalyzer {
    static func analyze(
        mesh: [SIMD3<Float>],
        triangleIndices: [Int],
        widthMM: Float,
        heightMM: Float,
        depthMM: Float,
        symmetryErrorMM: Float,
        stabilityErrorMM: Float,
        quality: Int,
        yawCoverageDegrees: Float,
        acceptedFrames: Int,
        rejectedFrames: Int,
        depthFusion: DepthFusionMetrics
    ) -> SurfaceAnalysisResult {
        guard
            !mesh.isEmpty,
            let minX = mesh.map(\.x).min(),
            let maxX = mesh.map(\.x).max(),
            let minY = mesh.map(\.y).min(),
            let maxY = mesh.map(\.y).max()
        else {
            return .empty(vertexCount: mesh.count)
        }

        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        let halfWidth = max((maxX - minX) / 2, 0.0001)
        let halfHeight = max((maxY - minY) / 2, 0.0001)
        let centerZ = median(mesh.map(\.z))

        var normalized = mesh.map {
            NormalizedPoint(
                x: ($0.x - centerX) / halfWidth,
                y: ($0.y - centerY) / halfHeight,
                z: ($0.z - centerZ) / max(halfWidth * 2, 0.0001)
            )
        }

        let rawNose = zoneDepth(normalized) {
            abs($0.x) < 0.14 && $0.y > 0.02 && $0.y < 0.52
        }
        let rawLateral = zoneDepth(normalized) {
            abs($0.x) > 0.36 && abs($0.x) < 0.68 && $0.y > -0.02 && $0.y < 0.42
        }
        let forwardSign: Float = rawNose >= rawLateral ? 1 : -1
        normalized = normalized.map {
            NormalizedPoint(x: $0.x, y: $0.y, z: $0.z * forwardSign)
        }

        let cheekDepth = zoneDepth(normalized) {
            abs($0.x) > 0.36 && abs($0.x) < 0.72 && $0.y > -0.08 && $0.y < 0.38
        }
        let templeDepth = zoneDepth(normalized) {
            abs($0.x) > 0.66 && abs($0.x) < 0.94 && $0.y > 0.28 && $0.y < 0.72
        }
        let jawDepth = zoneDepth(normalized) {
            abs($0.x) > 0.36 && abs($0.x) < 0.78 && $0.y > -0.70 && $0.y < -0.20
        }
        let chinDepth = zoneDepth(normalized) {
            abs($0.x) < 0.24 && $0.y > -0.96 && $0.y < -0.56
        }
        let mouthDepth = zoneDepth(normalized) {
            abs($0.x) < 0.34 && $0.y > -0.46 && $0.y < -0.10
        }
        let midCenterDepth = zoneDepth(normalized) {
            abs($0.x) < 0.28 && $0.y > -0.04 && $0.y < 0.38
        }
        let midSideDepth = zoneDepth(normalized) {
            abs($0.x) > 0.30 && abs($0.x) < 0.58 && $0.y > -0.04 && $0.y < 0.38
        }
        let noseDepth = zoneDepth(normalized) {
            abs($0.x) < 0.13 && $0.y > 0.02 && $0.y < 0.52
        }
        let noseSideDepth = zoneDepth(normalized) {
            abs($0.x) > 0.17 && abs($0.x) < 0.34 && $0.y > 0.02 && $0.y < 0.52
        }
        let orbitalDepth = zoneDepth(normalized) {
            abs($0.x) > 0.15 && abs($0.x) < 0.46 && $0.y > 0.18 && $0.y < 0.48
        }
        let infraorbitalDepth = zoneDepth(normalized) {
            abs($0.x) > 0.18 && abs($0.x) < 0.50 && $0.y > -0.02 && $0.y < 0.20
        }

        let cheekHalfWidth = bandHalfWidth(normalized, yRange: -0.08...0.34)
        let jawHalfWidth = bandHalfWidth(normalized, yRange: -0.70...(-0.24))
        let cheekWidthMM = cheekHalfWidth * widthMM
        let jawWidthMM = jawHalfWidth * widthMM
        let jawWidthRatio = jawWidthMM / max(cheekWidthMM, 0.001)

        let widthHeightRatio = widthMM / max(heightMM, 0.001)
        let depthWidthRatio = depthMM / max(widthMM, 0.001)
        let zygomaticProjectionMM = (cheekDepth - templeDepth) * widthMM
        let chinProjectionMM = (chinDepth - mouthDepth) * widthMM
        let midfaceProjectionMM = (midCenterDepth - midSideDepth) * widthMM
        let nasalProjectionMM = (noseDepth - noseSideDepth) * widthMM
        let orbitalSupportMM = (orbitalDepth - infraorbitalDepth) * widthMM

        let jawAngleDegrees = bilateralJawAngle(
            mesh: mesh,
            normalized: normalized
        )
        let convexityDegrees = facialConvexityAngle(
            mesh: mesh,
            normalized: normalized
        )

        let curvatureRaw = curvatureMap(
            mesh: mesh,
            triangleIndices: triangleIndices,
            widthMM: widthMM
        )
        let curvatureP75 = percentile(curvatureRaw, fraction: 0.75)
        let curvatureP90 = percentile(curvatureRaw, fraction: 0.90)
        let curvatureNormalized = normalizeMap(curvatureRaw, upperPercentile: 0.95)

        let vertexAsymmetry = vertexAsymmetryMM(mesh: mesh)
        let symmetryRegions = makeRegionalSymmetry(
            normalized: normalized,
            vertexAsymmetryMM: vertexAsymmetry,
            quality: quality,
            stabilityErrorMM: stabilityErrorMM
        )

        let baseConfidence = confidenceBase(
            quality: quality,
            stabilityErrorMM: stabilityErrorMM,
            yawCoverageDegrees: yawCoverageDegrees,
            depthFusion: depthFusion
        )

        let symmetryScore = clamp(100 - symmetryErrorMM * 10.5, lower: 10, upper: 100)
        let harmonyScore =
            bellScore(widthHeightRatio, target: 0.78, tolerance: 0.18) * 0.62 +
            bellScore(depthWidthRatio, target: 0.50, tolerance: 0.22) * 0.38
        let angularityScore = bellScore(curvatureP75, target: 1.45, tolerance: 1.25)
        let zygomaticScore = bellScore(zygomaticProjectionMM, target: 3.8, tolerance: 6.5)
        let mandibleScore =
            bellScore(jawWidthRatio, target: 0.80, tolerance: 0.20) * 0.58 +
            bellScore(abs(cheekDepth - jawDepth) * widthMM, target: 4.5, tolerance: 7.0) * 0.22 +
            bellScore(jawAngleDegrees, target: 124, tolerance: 28) * 0.20
        let jawAngleScore = bellScore(jawAngleDegrees, target: 124, tolerance: 28)
        let chinScore = bellScore(chinProjectionMM, target: 2.2, tolerance: 7.5)
        let midfaceScore = bellScore(midfaceProjectionMM, target: 3.5, tolerance: 8.0)
        let nasalScore = bellScore(nasalProjectionMM, target: 8.5, tolerance: 10.5)
        let convexityScore = bellScore(convexityDegrees, target: 166, tolerance: 25)
        let orbitalScore = bellScore(orbitalSupportMM, target: 0.8, tolerance: 6.0)

        let features = [
            feature(
                id: "symmetry3d",
                title: "3D-симметрия",
                score: symmetryScore,
                rawValue: symmetryErrorMM,
                unit: "мм ошибки",
                confidence: baseConfidence,
                explanation: "Дистанция между одной стороной поверхности и зеркальной второй стороной."
            ),
            feature(
                id: "harmony3d",
                title: "3D-гармония",
                score: harmonyScore,
                rawValue: widthHeightRatio,
                unit: "W/H",
                confidence: baseConfidence,
                explanation: "Баланс ширины, высоты и общей глубины наружной сетки."
            ),
            feature(
                id: "angularity",
                title: "Surface angularity",
                score: angularityScore,
                rawValue: curvatureP75,
                unit: "индекс",
                confidence: min(baseConfidence, triangleIndices.isEmpty ? 45 : 94),
                explanation: "Локальная кривизна поверхности по соседним вершинам сетки."
            ),
            feature(
                id: "zygomatic",
                title: "Zygomatic surface proxy",
                score: zygomaticScore,
                rawValue: zygomaticProjectionMM,
                unit: "мм",
                confidence: baseConfidence,
                explanation: "Наружная проекция скуловой зоны относительно височной поверхности."
            ),
            feature(
                id: "mandible",
                title: "Mandibular surface proxy",
                score: mandibleScore,
                rawValue: jawWidthRatio,
                unit: "jaw/cheek",
                confidence: baseConfidence,
                explanation: "Ширина нижней зоны, перепад глубины и геометрия угла челюсти."
            ),
            feature(
                id: "jawAngle",
                title: "Jaw angle proxy",
                score: jawAngleScore,
                rawValue: jawAngleDegrees,
                unit: "°",
                confidence: max(40, baseConfidence - 6),
                explanation: "Угол наружного контура между боковой челюстью и подбородочной зоной."
            ),
            feature(
                id: "chin",
                title: "Chin projection",
                score: chinScore,
                rawValue: chinProjectionMM,
                unit: "мм",
                confidence: baseConfidence,
                explanation: "Проекция подбородка относительно околоротовой поверхности."
            ),
            feature(
                id: "midface",
                title: "Midface surface proxy",
                score: midfaceScore,
                rawValue: midfaceProjectionMM,
                unit: "мм",
                confidence: baseConfidence,
                explanation: "Глубина центральной средней зоны относительно латеральной поверхности."
            ),
            feature(
                id: "nasal",
                title: "Nasal projection",
                score: nasalScore,
                rawValue: nasalProjectionMM,
                unit: "мм",
                confidence: baseConfidence,
                explanation: "Проекция поверхности носа относительно соседней средней зоны."
            ),
            feature(
                id: "convexity",
                title: "Facial convexity proxy",
                score: convexityScore,
                rawValue: convexityDegrees,
                unit: "°",
                confidence: max(35, baseConfidence - 10),
                explanation: "Сагиттальный угол между лобной, носовой и подбородочной поверхностью."
            ),
            feature(
                id: "orbital",
                title: "Orbital support proxy",
                score: orbitalScore,
                rawValue: orbitalSupportMM,
                unit: "мм",
                confidence: max(35, baseConfidence - 8),
                explanation: "Перепад поверхности между орбитальной и подглазничной зонами."
            )
        ]

        let weights: [Float] = [
            0.18, 0.14, 0.10, 0.11, 0.12, 0.07,
            0.07, 0.07, 0.05, 0.05, 0.04
        ]
        let weightedMean = zip(features, weights).reduce(Float.zero) {
            $0 + $1.0.score * $1.1
        }
        let weakest = features.map(\.score).min() ?? weightedMean
        let composite = weightedMean * 0.90 + weakest * 0.10
        let normalizedScore = clamp(composite / 100, lower: 0, upper: 1)
        let pslScore = clamp(
            1.2 + 7.8 * Float(pow(Double(normalizedScore), 1.82)),
            lower: 1,
            upper: 9
        )

        let rejectionRatio = Float(rejectedFrames) /
            Float(max(acceptedFrames + rejectedFrames, 1))
        let depthUncertainty: Float
        if depthFusion.applied {
            depthUncertainty =
                max(0, 42 - depthFusion.coveragePercent) * 0.004 +
                max(0, depthFusion.medianResidualMM - 8) * 0.010 +
                max(0, depthFusion.temporalNoiseMM - 2.5) * 0.018
        } else {
            depthUncertainty = 0.24
        }

        let uncertainty = clamp(
            0.18 +
            Float(100 - quality) * 0.0085 +
            max(0, 24 - yawCoverageDegrees) * 0.011 +
            rejectionRatio * 0.28 +
            max(0, stabilityErrorMM - 0.7) * 0.075 +
            depthUncertainty,
            lower: 0.18,
            upper: 1.45
        )

        let low = clamp(pslScore - uncertainty, lower: 1, upper: 10)
        let high = clamp(pslScore + uncertainty, lower: 1, upper: 10)
        let reliability: String
        if quality >= 86,
           stabilityErrorMM <= 0.85,
           yawCoverageDegrees >= 25,
           depthFusion.applied,
           depthFusion.coveragePercent >= 35,
           depthFusion.medianResidualMM <= 16 {
            reliability = "Высокая"
        } else if quality >= 68,
                  stabilityErrorMM <= 1.45,
                  yawCoverageDegrees >= 18 {
            reliability = "Средняя"
        } else {
            reliability = "Низкая"
        }

        let measurements = [
            measurement("faceWidth", "Ширина поверхности", widthMM, "мм", baseConfidence, "Максимальная ширина 3D-сетки."),
            measurement("faceHeight", "Высота поверхности", heightMM, "мм", baseConfidence, "Высота отслеживаемой ARKit-сетки, без волос."),
            measurement("faceDepth", "Глубина поверхности", depthMM, "мм", baseConfidence, "Диапазон глубины наружной сетки."),
            measurement("cheekWidth", "Ширина скуловой зоны", cheekWidthMM, "мм", baseConfidence, "Ширина поверхности на уровне скуловой зоны."),
            measurement("jawWidth", "Ширина нижней зоны", jawWidthMM, "мм", baseConfidence, "Ширина поверхности в нижнечелюстной зоне."),
            measurement("jawCheek", "Jaw / cheek", jawWidthRatio, "ratio", baseConfidence, "Отношение ширины нижней зоны к скуловой."),
            measurement("jawAngle", "Угол челюсти proxy", jawAngleDegrees, "°", max(40, baseConfidence - 6), "Угол наружного контура, не угол кости."),
            measurement("zygomaticProjection", "Скуловая проекция", zygomaticProjectionMM, "мм", baseConfidence, "Глубинный перепад скуловой и височной зон."),
            measurement("chinProjection", "Проекция подбородка", chinProjectionMM, "мм", baseConfidence, "Глубинный перепад подбородка и околоротовой зоны."),
            measurement("midfaceProjection", "Проекция средней зоны", midfaceProjectionMM, "мм", baseConfidence, "Центральная средняя зона относительно боковой."),
            measurement("nasalProjection", "Проекция носовой зоны", nasalProjectionMM, "мм", baseConfidence, "Носовая поверхность относительно соседней зоны."),
            measurement("orbitalSupport", "Orbital support proxy", orbitalSupportMM, "мм", max(35, baseConfidence - 8), "Перепад орбитальной и подглазничной поверхности."),
            measurement("convexity", "Facial convexity proxy", convexityDegrees, "°", max(35, baseConfidence - 10), "Сагиттальный угол наружной поверхности."),
            measurement("curvatureP90", "Кривизна P90", curvatureP90, "индекс", max(40, baseConfidence - 4), "90-й перцентиль локальной кривизны сетки.")
        ]

        var warnings = [String]()
        if quality < 70 {
            warnings.append("Качество скана ниже рекомендуемого: диапазон результата расширен.")
        }
        if yawCoverageDegrees < 22 {
            warnings.append("Недостаточное покрытие боковых ракурсов. Поверни голову чуть сильнее в обе стороны.")
        }
        if stabilityErrorMM > 1.20 {
            warnings.append("Сетка заметно менялась между кадрами. Держи мимику и расстояние стабильнее.")
        }
        if rejectionRatio > 0.32 {
            warnings.append("Много кадров отклонено из-за движения, моргания или выражения лица.")
        }
        if !depthFusion.applied {
            warnings.append("Depth Fusion не прошёл контроль покрытия или согласованности. Используется медианная ARKit-сетка.")
        } else if depthFusion.coveragePercent < 35 {
            warnings.append("Карта глубины уточнила только часть вершин. Попробуй более ровный свет и медленнее поворачивай голову.")
        }
        warnings.append("Zygomatic, maxilla, orbit и mandible здесь являются наружными surface proxy, а не измерением внутренних костей.")

        return SurfaceAnalysisResult(
            pslScore: pslScore,
            scoreRangeLow: low,
            scoreRangeHigh: high,
            category: category(for: pslScore),
            reliability: reliability,
            features: features,
            measurements: measurements,
            regionalSymmetry: symmetryRegions,
            surfaceMaps: SurfaceMapData(
                vertexAsymmetryMM: vertexAsymmetry,
                vertexCurvatureIndex: curvatureNormalized
            ),
            warnings: warnings
        )
    }

    private static func feature(
        id: String,
        title: String,
        score: Float,
        rawValue: Float,
        unit: String,
        confidence: Int,
        explanation: String
    ) -> FeatureMetric {
        FeatureMetric(
            id: id,
            title: title,
            score: clamp(score, lower: 0, upper: 100),
            rawValue: rawValue,
            rawUnit: unit,
            confidence: clamp(confidence, lower: 0, upper: 100),
            crossScanSpread: 0,
            explanation: explanation
        )
    }

    private static func measurement(
        _ id: String,
        _ title: String,
        _ value: Float,
        _ unit: String,
        _ confidence: Int,
        _ explanation: String
    ) -> SurfaceMeasurement {
        SurfaceMeasurement(
            id: id,
            title: title,
            value: value,
            unit: unit,
            confidence: clamp(confidence, lower: 0, upper: 100),
            explanation: explanation
        )
    }

    private static func confidenceBase(
        quality: Int,
        stabilityErrorMM: Float,
        yawCoverageDegrees: Float,
        depthFusion: DepthFusionMetrics
    ) -> Int {
        let qualityPart = Float(quality) * 0.52
        let stabilityPart = clamp(1 - stabilityErrorMM / 2.4, lower: 0, upper: 1) * 20
        let coveragePart = clamp(yawCoverageDegrees / 28, lower: 0, upper: 1) * 10
        let depthPart: Float
        if depthFusion.applied {
            depthPart = clamp(depthFusion.coveragePercent / 55, lower: 0, upper: 1) * 18
        } else {
            depthPart = 5
        }
        return Int(clamp((qualityPart + stabilityPart + coveragePart + depthPart).rounded(), lower: 20, upper: 98))
    }

    private static func makeRegionalSymmetry(
        normalized: [NormalizedPoint],
        vertexAsymmetryMM: [Float],
        quality: Int,
        stabilityErrorMM: Float
    ) -> [RegionalSymmetryMetric] {
        let definitions: [(String, String, (NormalizedPoint) -> Bool)] = [
            ("upper", "Лоб и надбровье", { $0.y > 0.42 }),
            ("orbital", "Орбитальная зона", { abs($0.x) < 0.62 && $0.y > 0.08 && $0.y <= 0.45 }),
            ("zygomatic", "Скуловая зона", { abs($0.x) > 0.28 && abs($0.x) < 0.78 && $0.y > -0.12 && $0.y <= 0.30 }),
            ("nose", "Носовая зона", { abs($0.x) <= 0.22 && $0.y > -0.18 && $0.y <= 0.46 }),
            ("mouth", "Губы и околоротовая зона", { abs($0.x) < 0.50 && $0.y > -0.52 && $0.y <= -0.08 }),
            ("jaw", "Нижняя челюсть", { abs($0.x) > 0.22 && $0.y > -0.82 && $0.y <= -0.28 }),
            ("chin", "Подбородок", { abs($0.x) <= 0.30 && $0.y <= -0.52 })
        ]

        let baseConfidence = Int(clamp(
            Float(quality) * 0.72 + clamp(1 - stabilityErrorMM / 2.2, lower: 0, upper: 1) * 28,
            lower: 20,
            upper: 98
        ))

        return definitions.map { definition in
            let indices = normalized.indices.filter { definition.2(normalized[$0]) }
            let values = indices.compactMap { index -> Float? in
                guard vertexAsymmetryMM.indices.contains(index) else { return nil }
                return vertexAsymmetryMM[index]
            }
            let error = percentile(values, fraction: 0.50)
            let countConfidence = min(100, Int(Float(values.count) / 90 * 100))
            let expressionPenalty = definition.0 == "mouth" ? 8 : 0
            let confidence = max(20, min(baseConfidence, countConfidence) - expressionPenalty)
            return RegionalSymmetryMetric(
                id: definition.0,
                title: definition.1,
                errorMM: error,
                score: clamp(100 - error * 11, lower: 0, upper: 100),
                confidence: confidence
            )
        }
    }

    private static func vertexAsymmetryMM(mesh: [SIMD3<Float>]) -> [Float] {
        guard !mesh.isEmpty else { return [] }
        let centerX = median(mesh.map(\.x))
        let leftIndices = mesh.indices.filter { mesh[$0].x < centerX - 0.0008 }
        let rightIndices = mesh.indices.filter { mesh[$0].x > centerX + 0.0008 }
        var result = Array(repeating: Float.zero, count: mesh.count)

        for index in mesh.indices {
            let point = mesh[index]
            if abs(point.x - centerX) <= 0.0008 {
                result[index] = 0
                continue
            }

            let candidates = point.x < centerX ? rightIndices : leftIndices
            let mirrored = SIMD3<Float>(2 * centerX - point.x, point.y, point.z)
            var best = Float.greatestFiniteMagnitude
            for candidateIndex in candidates {
                let squared = simd_length_squared(mirrored - mesh[candidateIndex])
                if squared < best { best = squared }
            }
            result[index] = best.isFinite ? sqrt(best) * 1000 : 0
        }
        return result
    }

    private static func curvatureMap(
        mesh: [SIMD3<Float>],
        triangleIndices: [Int],
        widthMM: Float
    ) -> [Float] {
        guard !mesh.isEmpty else { return [] }
        var neighbors = Array(repeating: Set<Int>(), count: mesh.count)
        var index = 0
        while index + 2 < triangleIndices.count {
            let a = triangleIndices[index]
            let b = triangleIndices[index + 1]
            let c = triangleIndices[index + 2]
            if mesh.indices.contains(a), mesh.indices.contains(b), mesh.indices.contains(c) {
                neighbors[a].formUnion([b, c])
                neighbors[b].formUnion([a, c])
                neighbors[c].formUnion([a, b])
            }
            index += 3
        }

        let widthMeters = max(widthMM / 1000, 0.001)
        return mesh.indices.map { vertexIndex in
            let adjacent = neighbors[vertexIndex]
            guard !adjacent.isEmpty else { return 0 }
            let average = adjacent.reduce(SIMD3<Float>.zero) {
                $0 + mesh[$1]
            } / Float(adjacent.count)
            return simd_distance(mesh[vertexIndex], average) / widthMeters * 100
        }
    }

    private static func normalizeMap(
        _ values: [Float],
        upperPercentile: Float
    ) -> [Float] {
        let upper = max(percentile(values, fraction: upperPercentile), 0.0001)
        return values.map { clamp($0 / upper * 100, lower: 0, upper: 100) }
    }

    private static func bilateralJawAngle(
        mesh: [SIMD3<Float>],
        normalized: [NormalizedPoint]
    ) -> Float {
        let left = jawAngle(mesh: mesh, normalized: normalized, side: -1)
        let right = jawAngle(mesh: mesh, normalized: normalized, side: 1)
        let valid = [left, right].filter { $0 > 0 }
        return valid.isEmpty ? 0 : median(valid)
    }

    private static func jawAngle(
        mesh: [SIMD3<Float>],
        normalized: [NormalizedPoint],
        side: Float
    ) -> Float {
        guard
            let cheek = zoneCentroid(mesh: mesh, normalized: normalized, predicate: {
                $0.x * side > 0.36 && $0.x * side < 0.82 && $0.y > -0.15 && $0.y < 0.25
            }),
            let gonial = zoneCentroid(mesh: mesh, normalized: normalized, predicate: {
                $0.x * side > 0.42 && $0.x * side < 0.86 && $0.y > -0.72 && $0.y < -0.30
            }),
            let chin = zoneCentroid(mesh: mesh, normalized: normalized, predicate: {
                $0.x * side > 0.02 && $0.x * side < 0.30 && $0.y > -0.96 && $0.y < -0.58
            })
        else { return 0 }

        return angleDegrees(a: cheek - gonial, b: chin - gonial)
    }

    private static func facialConvexityAngle(
        mesh: [SIMD3<Float>],
        normalized: [NormalizedPoint]
    ) -> Float {
        guard
            let forehead = zoneCentroid(mesh: mesh, normalized: normalized, predicate: {
                abs($0.x) < 0.18 && $0.y > 0.50 && $0.y < 0.88
            }),
            let nose = zoneCentroid(mesh: mesh, normalized: normalized, predicate: {
                abs($0.x) < 0.12 && $0.y > 0.02 && $0.y < 0.40
            }),
            let chin = zoneCentroid(mesh: mesh, normalized: normalized, predicate: {
                abs($0.x) < 0.20 && $0.y > -0.96 && $0.y < -0.58
            })
        else { return 0 }

        let upper = SIMD3<Float>(0, forehead.y - nose.y, forehead.z - nose.z)
        let lower = SIMD3<Float>(0, chin.y - nose.y, chin.z - nose.z)
        return angleDegrees(a: upper, b: lower)
    }

    private static func angleDegrees(a: SIMD3<Float>, b: SIMD3<Float>) -> Float {
        let lengthProduct = simd_length(a) * simd_length(b)
        guard lengthProduct > 0.000001 else { return 0 }
        let cosine = clamp(simd_dot(a, b) / lengthProduct, lower: -1, upper: 1)
        return acos(cosine) * 180 / .pi
    }

    private static func zoneCentroid(
        mesh: [SIMD3<Float>],
        normalized: [NormalizedPoint],
        predicate: (NormalizedPoint) -> Bool
    ) -> SIMD3<Float>? {
        let indices = normalized.indices.filter { predicate(normalized[$0]) }
        guard !indices.isEmpty else { return nil }
        return indices.reduce(SIMD3<Float>.zero) { $0 + mesh[$1] } / Float(indices.count)
    }

    private static func zoneDepth(
        _ points: [NormalizedPoint],
        predicate: (NormalizedPoint) -> Bool
    ) -> Float {
        median(points.filter(predicate).map(\.z))
    }

    private static func bandHalfWidth(
        _ points: [NormalizedPoint],
        yRange: ClosedRange<Float>
    ) -> Float {
        let values = points
            .filter { yRange.contains($0.y) }
            .map { abs($0.x) }
            .sorted()
        return percentile(values, fraction: 0.88)
    }

    private static func bellScore(
        _ value: Float,
        target: Float,
        tolerance: Float
    ) -> Float {
        guard tolerance > 0 else { return 0 }
        let distance = abs(value - target) / tolerance
        return clamp(100 * Float(exp(-Double(distance * distance))), lower: 0, upper: 100)
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

    private static func percentile(_ values: [Float], fraction: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let fraction = clamp(fraction, lower: 0, upper: 1)
        let index = min(
            sorted.count - 1,
            Int((Float(sorted.count - 1) * fraction).rounded())
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

private struct NormalizedPoint {
    let x: Float
    let y: Float
    let z: Float
}
