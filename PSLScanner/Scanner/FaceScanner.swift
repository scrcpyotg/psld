import Foundation
import ARKit
import SceneKit
import Combine
import UIKit
import simd

enum ScannerState: Equatable {
    case checking
    case unsupported
    case ready
    case scanning
    case processing
    case complete
    case failed(String)
}

final class FaceScanner: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var state: ScannerState = .checking
    @Published private(set) var statusText = "Проверяем камеру TrueDepth…"
    @Published private(set) var progress: Double = 0
    @Published private(set) var acceptedFrames = 0
    @Published private(set) var rejectedFrames = 0
    @Published private(set) var trueDepthDetected = false
    @Published private(set) var summary: ScanSummary?
    @Published private(set) var resultDocument: FaceScanDocument?
    @Published private(set) var exportURL: URL?

    private weak var sceneView: ARSCNView?
    private let sessionQueue = DispatchQueue(label: "com.psllens.scanner.session", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "com.psllens.scanner.analysis", qos: .userInitiated)

    private var collecting = false
    private var samples: [[SIMD3<Float>]] = []
    private var triangleIndices: [Int] = []
    private var lastAcceptedTimestamp: TimeInterval = 0
    private var yawMinimum: Float = .greatestFiniteMagnitude
    private var yawMaximum: Float = -.greatestFiniteMagnitude
    private var depthFrames = 0
    private var totalObservedFrames = 0

    private let targetFrameCount = 100
    private let maximumFrameCount = 170
    private let minimumSampleInterval: TimeInterval = 0.075

    func attach(to view: ARSCNView) {
        sceneView = view
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = true
        view.session.delegate = self
        view.session.delegateQueue = sessionQueue

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }

        guard ARFaceTrackingConfiguration.isSupported else {
            publish {
                self.state = .unsupported
                self.statusText = "ARKit Face Tracking не поддерживается на этом устройстве."
            }
            return
        }

        runSession(reset: true)
    }

    func pauseSession() {
        sceneView?.session.pause()
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func startScan() {
        sessionQueue.async {
            self.samples.removeAll(keepingCapacity: true)
            self.triangleIndices.removeAll(keepingCapacity: true)
            self.lastAcceptedTimestamp = 0
            self.yawMinimum = .greatestFiniteMagnitude
            self.yawMaximum = -.greatestFiniteMagnitude
            self.depthFrames = 0
            self.totalObservedFrames = 0
            self.collecting = true

            self.publish {
                self.state = .scanning
                self.statusText = "Смотри прямо, затем медленно поверни голову в обе стороны."
                self.progress = 0
                self.acceptedFrames = 0
                self.rejectedFrames = 0
                self.trueDepthDetected = false
                self.summary = nil
                self.resultDocument = nil
                self.exportURL = nil
            }
        }
    }

    func cancelScan() {
        sessionQueue.async {
            self.collecting = false
            self.publish {
                self.state = .ready
                self.statusText = "Сканирование отменено."
                self.progress = 0
            }
        }
    }

    func resetForNewScan() {
        collecting = false
        pauseSession()
        publish {
            self.state = .ready
            self.statusText = "Готово. Держи iPhone вертикально на расстоянии 30–50 см."
            self.progress = 0
            self.acceptedFrames = 0
            self.rejectedFrames = 0
            self.trueDepthDetected = false
            self.summary = nil
            self.resultDocument = nil
            self.exportURL = nil
        }
    }

    private func runSession(reset: Bool) {
        guard let sceneView else { return }

        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = true
        configuration.maximumNumberOfTrackedFaces = 1

        let options: ARSession.RunOptions = reset
            ? [.resetTracking, .removeExistingAnchors]
            : []

        sceneView.session.run(configuration, options: options)

        publish {
            self.state = .ready
            self.statusText = "Готово. Держи iPhone вертикально на расстоянии 30–50 см."
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard collecting else { return }
        guard let frame = session.currentFrame else { return }
        guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              face.isTracked else {
            publishStatus("Помести всё лицо в кадр.")
            return
        }

        totalObservedFrames += 1

        if frame.capturedDepthData != nil {
            depthFrames += 1
            if !trueDepthDetected {
                publish {
                    self.trueDepthDetected = true
                }
            }
        }

        guard frame.timestamp - lastAcceptedTimestamp >= minimumSampleInterval else {
            return
        }

        let pose = poseAngles(from: face.transform)
        let yaw = pose.y
        let pitch = pose.x
        let roll = pose.z

        let jawOpen = blend(face, .jawOpen)
        let smile = max(blend(face, .mouthSmileLeft), blend(face, .mouthSmileRight))
        let blink = max(blend(face, .eyeBlinkLeft), blend(face, .eyeBlinkRight))

        let poseIsUsable =
            abs(yaw) < 0.72 &&
            abs(pitch) < 0.38 &&
            abs(roll) < 0.26

        let expressionIsUsable =
            jawOpen < 0.20 &&
            smile < 0.34 &&
            blink < 0.80

        guard poseIsUsable, expressionIsUsable else {
            rejectedFrames += 1
            let rejected = rejectedFrames
            publish {
                self.rejectedFrames = rejected
            }

            if abs(roll) >= 0.26 {
                publishStatus("Не наклоняй голову к плечу.")
            } else if abs(pitch) >= 0.38 {
                publishStatus("Держи подбородок ровно.")
            } else {
                publishStatus("Расслабь губы, глаза и брови.")
            }
            return
        }

        let vertices = face.geometry.vertices.map {
            SIMD3<Float>($0.x, $0.y, $0.z)
        }

        guard !vertices.isEmpty else { return }

        if let first = samples.first, first.count != vertices.count {
            rejectedFrames += 1
            return
        }

        if triangleIndices.isEmpty {
            triangleIndices = face.geometry.triangleIndices.map(Int.init)
        }

        samples.append(vertices)
        lastAcceptedTimestamp = frame.timestamp
        yawMinimum = min(yawMinimum, yaw)
        yawMaximum = max(yawMaximum, yaw)

        let count = samples.count
        let coverage = max(0, yawMaximum - yawMinimum)
        let framePart = min(1.0, Double(count) / Double(targetFrameCount))
        let coveragePart = min(1.0, Double(coverage / 0.42))
        let progressValue = min(0.99, framePart * 0.76 + coveragePart * 0.24)

        publish {
            self.acceptedFrames = count
            self.progress = progressValue
            self.statusText = self.guidanceText(
                count: count,
                yawMin: self.yawMinimum,
                yawMax: self.yawMaximum
            )
        }

        let hasCoverage = yawMinimum < -0.17 && yawMaximum > 0.17
        if count >= targetFrameCount && hasCoverage {
            finishScan(session: session)
        } else if count >= maximumFrameCount {
            finishScan(session: session)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        collecting = false
        publish {
            self.state = .failed(error.localizedDescription)
            self.statusText = "AR-сессия завершилась с ошибкой."
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        publishStatus("Сканирование приостановлено системой.")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        runSession(reset: true)
    }

    private func finishScan(session: ARSession) {
        guard collecting else { return }
        collecting = false

        let capturedSamples = samples
        let capturedTriangles = triangleIndices
        let capturedDepthFrames = depthFrames
        let capturedRejected = rejectedFrames
        let capturedYawMin = yawMinimum
        let capturedYawMax = yawMaximum
        let observed = max(totalObservedFrames, 1)

        publish {
            self.state = .processing
            self.statusText = "Усредняем 3D-сетку и считаем поверхностные прокси…"
            self.progress = 1
        }

        analysisQueue.async {
            guard capturedDepthFrames > 0 else {
                self.publish {
                    self.state = .failed("ARKit не выдал карту глубины. Нужен iPhone с активной фронтальной TrueDepth-камерой.")
                    self.statusText = "TrueDepth не обнаружен."
                }
                return
            }

            do {
                let result = try self.makeDocument(
                    samples: capturedSamples,
                    triangles: capturedTriangles,
                    depthFrames: capturedDepthFrames,
                    rejectedFrames: capturedRejected,
                    yawMin: capturedYawMin,
                    yawMax: capturedYawMax,
                    observedFrames: observed
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(result.document)

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let fileName = "PSL-TrueDepth-v2-\(formatter.string(from: Date())).json"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try data.write(to: url, options: .atomic)

                self.publish {
                    self.statusText = "3D-скан готов. Результат рассчитан локально."
                    self.summary = result.summary
                    self.resultDocument = result.document
                    self.exportURL = url
                    self.state = .complete
                }
            } catch {
                self.publish {
                    self.state = .failed(error.localizedDescription)
                    self.statusText = "Не удалось сформировать 3D-скан."
                }
            }
        }
    }

    private func makeDocument(
        samples: [[SIMD3<Float>]],
        triangles: [Int],
        depthFrames: Int,
        rejectedFrames: Int,
        yawMin: Float,
        yawMax: Float,
        observedFrames: Int
    ) throws -> (document: FaceScanDocument, summary: ScanSummary) {
        guard let first = samples.first, !first.isEmpty else {
            throw ScannerError.notEnoughData
        }

        let vertexCount = first.count
        guard samples.allSatisfy({ $0.count == vertexCount }) else {
            throw ScannerError.inconsistentMesh
        }

        var medianMesh = [SIMD3<Float>]()
        medianMesh.reserveCapacity(vertexCount)

        for index in 0..<vertexCount {
            var xs = [Float]()
            var ys = [Float]()
            var zs = [Float]()
            xs.reserveCapacity(samples.count)
            ys.reserveCapacity(samples.count)
            zs.reserveCapacity(samples.count)

            for sample in samples {
                let value = sample[index]
                xs.append(value.x)
                ys.append(value.y)
                zs.append(value.z)
            }

            medianMesh.append(
                SIMD3<Float>(
                    median(xs),
                    median(ys),
                    median(zs)
                )
            )
        }

        guard
            let minX = medianMesh.map(\.x).min(),
            let maxX = medianMesh.map(\.x).max(),
            let minY = medianMesh.map(\.y).min(),
            let maxY = medianMesh.map(\.y).max(),
            let minZ = medianMesh.map(\.z).min(),
            let maxZ = medianMesh.map(\.z).max()
        else {
            throw ScannerError.notEnoughData
        }

        let widthMM = (maxX - minX) * 1000
        let heightMM = (maxY - minY) * 1000
        let depthMM = (maxZ - minZ) * 1000
        let symmetryErrorMM = mirroredNearestNeighborError(mesh: medianMesh) * 1000
        let stabilityErrorMM = meshStabilityError(samples: samples, medianMesh: medianMesh) * 1000
        let yawCoverageDegrees = max(0, yawMax - yawMin) * 180 / .pi

        let frameScore = min(1, Float(samples.count) / Float(targetFrameCount))
        let coverageScore = min(1, yawCoverageDegrees / 28)
        let depthScore = min(1, Float(depthFrames) / Float(max(observedFrames, 1)))
        let acceptanceScore = Float(samples.count) / Float(max(samples.count + rejectedFrames, 1))
        let stabilityScore = clamp(1 - stabilityErrorMM / 2.2, lower: 0, upper: 1)

        let qualityFloat =
            frameScore * 20 +
            coverageScore * 20 +
            depthScore * 20 +
            acceptanceScore * 15 +
            stabilityScore * 25

        let quality = Int(clamp(qualityFloat.rounded(), lower: 0, upper: 100))
        let analysis = analyzeSurface(
            mesh: medianMesh,
            widthMM: widthMM,
            heightMM: heightMM,
            depthMM: depthMM,
            symmetryErrorMM: symmetryErrorMM,
            stabilityErrorMM: stabilityErrorMM,
            quality: quality,
            yawCoverageDegrees: yawCoverageDegrees,
            acceptedFrames: samples.count,
            rejectedFrames: rejectedFrames
        )

        let metrics = ScanMetrics(
            scanQuality: quality,
            reliability: analysis.reliability,
            overallPSLScore: analysis.pslScore,
            scoreRangeLow: analysis.scoreRangeLow,
            scoreRangeHigh: analysis.scoreRangeHigh,
            category: analysis.category,
            symmetryErrorMM: symmetryErrorMM,
            stabilityErrorMM: stabilityErrorMM,
            widthMM: widthMM,
            heightMM: heightMM,
            depthMM: depthMM,
            widthHeightRatio: widthMM / max(heightMM, 0.001),
            depthWidthRatio: depthMM / max(widthMM, 0.001),
            yawCoverageDegrees: yawCoverageDegrees,
            acceptedFrames: samples.count,
            rejectedFrames: rejectedFrames,
            depthFrames: depthFrames,
            featureMetrics: analysis.features,
            warnings: analysis.warnings
        )

        let vectors = medianMesh.map {
            ScanVector(x: $0.x, y: $0.y, z: $0.z)
        }

        let document = FaceScanDocument(
            format: "psl-truedepth-mesh",
            version: 2,
            createdAt: Date(),
            deviceModel: deviceModel(),
            operatingSystem: UIDevice.current.systemVersion,
            coordinateSystem: "ARFaceAnchor local coordinates: x left/right, y up/down, z depth",
            units: "meters for vertices; millimeters for metric fields",
            vertexCount: vertexCount,
            triangleCount: triangles.count / 3,
            metrics: metrics,
            vertices: vectors,
            triangleIndices: triangles,
            notice: "Экспериментальный анализ наружной поверхности лица TrueDepth. Он не показывает внутренние кости, не является медицинским исследованием и не измеряет объективную привлекательность."
        )

        let summary = ScanSummary(
            quality: quality,
            reliability: analysis.reliability,
            pslScore: analysis.pslScore,
            scoreRangeLow: analysis.scoreRangeLow,
            scoreRangeHigh: analysis.scoreRangeHigh,
            category: analysis.category,
            symmetryErrorMM: symmetryErrorMM,
            stabilityErrorMM: stabilityErrorMM,
            widthMM: widthMM,
            heightMM: heightMM,
            depthMM: depthMM,
            yawCoverageDegrees: yawCoverageDegrees,
            acceptedFrames: samples.count,
            featureMetrics: analysis.features,
            warnings: analysis.warnings
        )

        return (document, summary)
    }

    private func analyzeSurface(
        mesh: [SIMD3<Float>],
        widthMM: Float,
        heightMM: Float,
        depthMM: Float,
        symmetryErrorMM: Float,
        stabilityErrorMM: Float,
        quality: Int,
        yawCoverageDegrees: Float,
        acceptedFrames: Int,
        rejectedFrames: Int
    ) -> SurfaceAnalysis {
        guard
            let minX = mesh.map(\.x).min(),
            let maxX = mesh.map(\.x).max(),
            let minY = mesh.map(\.y).min(),
            let maxY = mesh.map(\.y).max()
        else {
            return SurfaceAnalysis.empty
        }

        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        let halfWidth = max((maxX - minX) / 2, 0.0001)
        let halfHeight = max((maxY - minY) / 2, 0.0001)
        let centerZ = median(mesh.map(\.z))

        var points = mesh.map {
            SurfacePoint(
                x: ($0.x - centerX) / halfWidth,
                y: ($0.y - centerY) / halfHeight,
                z: ($0.z - centerZ) / (halfWidth * 2)
            )
        }

        let rawNose = zoneDepth(points) {
            abs($0.x) < 0.14 && $0.y > 0.02 && $0.y < 0.52
        }
        let rawLateral = zoneDepth(points) {
            abs($0.x) > 0.36 && abs($0.x) < 0.68 && $0.y > -0.02 && $0.y < 0.42
        }
        let forwardSign: Float = rawNose >= rawLateral ? 1 : -1
        points = points.map { SurfacePoint(x: $0.x, y: $0.y, z: $0.z * forwardSign) }

        let cheekDepth = zoneDepth(points) {
            abs($0.x) > 0.36 && abs($0.x) < 0.72 && $0.y > -0.08 && $0.y < 0.38
        }
        let templeDepth = zoneDepth(points) {
            abs($0.x) > 0.66 && abs($0.x) < 0.94 && $0.y > 0.28 && $0.y < 0.72
        }
        let jawDepth = zoneDepth(points) {
            abs($0.x) > 0.36 && abs($0.x) < 0.76 && $0.y > -0.68 && $0.y < -0.22
        }
        let chinDepth = zoneDepth(points) {
            abs($0.x) < 0.24 && $0.y > -0.96 && $0.y < -0.56
        }
        let mouthDepth = zoneDepth(points) {
            abs($0.x) < 0.34 && $0.y > -0.46 && $0.y < -0.10
        }
        let midCenterDepth = zoneDepth(points) {
            abs($0.x) < 0.28 && $0.y > -0.04 && $0.y < 0.38
        }
        let midSideDepth = zoneDepth(points) {
            abs($0.x) > 0.30 && abs($0.x) < 0.58 && $0.y > -0.04 && $0.y < 0.38
        }
        let noseDepth = zoneDepth(points) {
            abs($0.x) < 0.13 && $0.y > 0.02 && $0.y < 0.52
        }
        let noseSideDepth = zoneDepth(points) {
            abs($0.x) > 0.17 && abs($0.x) < 0.34 && $0.y > 0.02 && $0.y < 0.52
        }

        let cheekWidth = bandHalfWidth(points, yRange: -0.08...0.34)
        let jawWidth = bandHalfWidth(points, yRange: -0.70...(-0.24))
        let jawWidthRatio = jawWidth / max(cheekWidth, 0.001)

        let widthHeightRatio = widthMM / max(heightMM, 0.001)
        let depthWidthRatio = depthMM / max(widthMM, 0.001)
        let zygomaticProjection = cheekDepth - templeDepth
        let chinProjection = chinDepth - mouthDepth
        let midfaceProjection = midCenterDepth - midSideDepth
        let nasalProjection = noseDepth - noseSideDepth
        let angularityValue = (
            abs(cheekDepth - jawDepth) +
            abs(cheekDepth - templeDepth) +
            abs(chinDepth - mouthDepth)
        ) / 3

        let symmetryScore = clamp(100 - symmetryErrorMM * 10.5, lower: 15, upper: 100)
        let harmonyScore =
            bellScore(widthHeightRatio, target: 0.78, tolerance: 0.18) * 0.62 +
            bellScore(depthWidthRatio, target: 0.50, tolerance: 0.22) * 0.38
        let angularityScore = bellScore(angularityValue, target: 0.035, tolerance: 0.035)
        let zygomaticScore = bellScore(zygomaticProjection, target: 0.025, tolerance: 0.040)
        let mandibleScore =
            bellScore(jawWidthRatio, target: 0.80, tolerance: 0.20) * 0.72 +
            bellScore(abs(cheekDepth - jawDepth), target: 0.030, tolerance: 0.040) * 0.28
        let chinScore = bellScore(chinProjection, target: 0.015, tolerance: 0.050)
        let midfaceScore = bellScore(midfaceProjection, target: 0.025, tolerance: 0.050)
        let nasalScore = bellScore(nasalProjection, target: 0.055, tolerance: 0.060)

        let features = [
            FeatureMetric(
                id: "symmetry3d",
                title: "3D-симметрия",
                score: symmetryScore,
                rawValue: symmetryErrorMM,
                rawUnit: "мм ошибки",
                explanation: "Средняя дистанция между одной стороной поверхности и зеркальной второй стороной."
            ),
            FeatureMetric(
                id: "harmony3d",
                title: "3D-гармония",
                score: harmonyScore,
                rawValue: widthHeightRatio,
                rawUnit: "W/H",
                explanation: "Баланс ширины, высоты и общей глубины наружной сетки."
            ),
            FeatureMetric(
                id: "angularity",
                title: "Feature angularity",
                score: angularityScore,
                rawValue: angularityValue * 100,
                rawUnit: "% ширины",
                explanation: "Изменение глубины между височной, скуловой, нижнечелюстной и подбородочной зонами."
            ),
            FeatureMetric(
                id: "zygomatic",
                title: "Zygomatic proxy",
                score: zygomaticScore,
                rawValue: zygomaticProjection * 100,
                rawUnit: "% ширины",
                explanation: "Наружная 3D-проекция поверхности скуловой зоны относительно височной зоны."
            ),
            FeatureMetric(
                id: "mandible",
                title: "Mandibular proxy",
                score: mandibleScore,
                rawValue: jawWidthRatio,
                rawUnit: "jaw/cheek",
                explanation: "Соотношение ширины нижней зоны и скул, дополненное перепадом глубины."
            ),
            FeatureMetric(
                id: "chin",
                title: "Chin projection",
                score: chinScore,
                rawValue: chinProjection * 100,
                rawUnit: "% ширины",
                explanation: "Проекция наружной поверхности подбородка относительно околоротовой зоны."
            ),
            FeatureMetric(
                id: "midface",
                title: "Midface proxy",
                score: midfaceScore,
                rawValue: midfaceProjection * 100,
                rawUnit: "% ширины",
                explanation: "Глубина центральной средней зоны относительно латеральной поверхности."
            ),
            FeatureMetric(
                id: "nasal",
                title: "Nasal projection",
                score: nasalScore,
                rawValue: nasalProjection * 100,
                rawUnit: "% ширины",
                explanation: "Проекция поверхности носовой зоны относительно соседней средней зоны."
            )
        ]

        let weights: [Float] = [0.20, 0.18, 0.12, 0.14, 0.14, 0.08, 0.08, 0.06]
        let scores = features.map(\.score)
        let weightedMean = zip(scores, weights).reduce(Float.zero) { partial, pair in
            partial + pair.0 * pair.1
        }
        let weakestScore = scores.min() ?? weightedMean
        let composite = weightedMean * 0.88 + weakestScore * 0.12
        let normalized = clamp(composite / 100, lower: 0, upper: 1)
        let pslScore = clamp(
            1.2 + 7.8 * Float(pow(Double(normalized), 1.8)),
            lower: 1,
            upper: 9
        )

        let rejectionRatio = Float(rejectedFrames) / Float(max(acceptedFrames + rejectedFrames, 1))
        let uncertainty = clamp(
            0.22 +
            Float(100 - quality) * 0.010 +
            max(0, 24 - yawCoverageDegrees) * 0.012 +
            rejectionRatio * 0.30 +
            max(0, stabilityErrorMM - 0.7) * 0.08,
            lower: 0.22,
            upper: 1.30
        )

        let low = clamp(pslScore - uncertainty, lower: 1, upper: 10)
        let high = clamp(pslScore + uncertainty, lower: 1, upper: 10)
        let reliability: String
        if quality >= 86 && stabilityErrorMM <= 0.85 && yawCoverageDegrees >= 25 {
            reliability = "Высокая"
        } else if quality >= 70 && stabilityErrorMM <= 1.35 && yawCoverageDegrees >= 18 {
            reliability = "Средняя"
        } else {
            reliability = "Низкая"
        }

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
        warnings.append("Zygomatic, maxilla и mandible представлены только наружными 3D-прокси поверхности, а не измерением костей.")

        return SurfaceAnalysis(
            pslScore: pslScore,
            scoreRangeLow: low,
            scoreRangeHigh: high,
            category: category(for: pslScore),
            reliability: reliability,
            features: features,
            warnings: warnings
        )
    }

    private func mirroredNearestNeighborError(mesh: [SIMD3<Float>]) -> Float {
        let left = mesh.filter { $0.x < -0.0015 }
        let right = mesh.filter { $0.x > 0.0015 }

        guard !left.isEmpty, !right.isEmpty else { return 0 }

        var distances = [Float]()
        distances.reserveCapacity(left.count)

        for point in left {
            let mirrored = SIMD3<Float>(-point.x, point.y, point.z)
            var bestSquared = Float.greatestFiniteMagnitude

            for candidate in right {
                let delta = mirrored - candidate
                let squared = simd_length_squared(delta)
                if squared < bestSquared {
                    bestSquared = squared
                }
            }

            distances.append(sqrt(bestSquared))
        }

        distances.sort()
        let keepCount = max(1, Int(Float(distances.count) * 0.90))
        let trimmed = distances.prefix(keepCount)
        return trimmed.reduce(0, +) / Float(trimmed.count)
    }

    private func meshStabilityError(
        samples: [[SIMD3<Float>]],
        medianMesh: [SIMD3<Float>]
    ) -> Float {
        guard !samples.isEmpty, !medianMesh.isEmpty else { return 0 }

        var distances = [Float]()
        let strideSize = max(1, medianMesh.count / 220)

        for sample in samples {
            var index = 0
            while index < min(sample.count, medianMesh.count) {
                distances.append(simd_distance(sample[index], medianMesh[index]))
                index += strideSize
            }
        }

        return median(distances)
    }

    private func zoneDepth(
        _ points: [SurfacePoint],
        where predicate: (SurfacePoint) -> Bool
    ) -> Float {
        let values = points.filter(predicate).map(\.z)
        return values.isEmpty ? 0 : median(values)
    }

    private func bandHalfWidth(
        _ points: [SurfacePoint],
        yRange: ClosedRange<Float>
    ) -> Float {
        let values = points
            .filter { yRange.contains($0.y) }
            .map { abs($0.x) }
            .sorted()

        guard !values.isEmpty else { return 0 }
        let index = min(values.count - 1, Int(Float(values.count - 1) * 0.92))
        return values[index]
    }

    private func bellScore(
        _ value: Float,
        target: Float,
        tolerance: Float
    ) -> Float {
        let safeTolerance = max(tolerance, 0.0001)
        let z = Double((value - target) / safeTolerance)
        return clamp(Float(100 * exp(-0.5 * z * z)), lower: 8, upper: 100)
    }

    private func category(for score: Float) -> String {
        switch score {
        case ..<3.0: return "SUB 3"
        case ..<4.5: return "SUB 5"
        case ..<5.3: return "LTN"
        case ..<6.1: return "MTN"
        case ..<7.1: return "HTN"
        default: return "CHAD"
        }
    }

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2

        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }

        return sorted[middle]
    }

    private func clamp<T: Comparable>(
        _ value: T,
        lower: T,
        upper: T
    ) -> T {
        min(max(value, lower), upper)
    }

    private func poseAngles(from transform: simd_float4x4) -> SIMD3<Float> {
        let node = SCNNode()
        node.simdTransform = transform
        return SIMD3<Float>(
            Float(node.eulerAngles.x),
            Float(node.eulerAngles.y),
            Float(node.eulerAngles.z)
        )
    }

    private func blend(
        _ face: ARFaceAnchor,
        _ location: ARFaceAnchor.BlendShapeLocation
    ) -> Float {
        face.blendShapes[location]?.floatValue ?? 0
    }

    private func guidanceText(count: Int, yawMin: Float, yawMax: Float) -> String {
        if count < 20 {
            return "Смотри прямо и держи лицо расслабленным."
        }
        if yawMin > -0.17 {
            return "Медленно поверни голову в одну сторону."
        }
        if yawMax < 0.17 {
            return "Теперь медленно поверни голову в другую сторону."
        }
        if count < targetFrameCount {
            return "Вернись к центру и сохрани нейтральное выражение."
        }
        return "Данных достаточно. Завершаем сканирование…"
    }

    private func publishStatus(_ text: String) {
        publish {
            self.statusText = text
        }
    }

    private func publish(_ changes: @escaping () -> Void) {
        DispatchQueue.main.async(execute: changes)
    }

    private func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)

        let identifier = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }

        return identifier
    }
}

private struct SurfacePoint {
    let x: Float
    let y: Float
    let z: Float
}

private struct SurfaceAnalysis {
    let pslScore: Float
    let scoreRangeLow: Float
    let scoreRangeHigh: Float
    let category: String
    let reliability: String
    let features: [FeatureMetric]
    let warnings: [String]

    static let empty = SurfaceAnalysis(
        pslScore: 1,
        scoreRangeLow: 1,
        scoreRangeHigh: 1,
        category: "НЕТ ЗАМЕРА",
        reliability: "Низкая",
        features: [],
        warnings: ["Не удалось выделить поверхность лица для расчёта."]
    )
}

private enum ScannerError: LocalizedError {
    case notEnoughData
    case inconsistentMesh

    var errorDescription: String? {
        switch self {
        case .notEnoughData:
            return "Недостаточно данных для построения сетки."
        case .inconsistentMesh:
            return "ARKit вернул несовместимые версии сетки."
        }
    }
}
