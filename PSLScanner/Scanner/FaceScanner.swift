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
    @Published private(set) var capturedDepthFrames = 0
    @Published private(set) var trueDepthDetected = false
    @Published private(set) var summary: ScanSummary?
    @Published private(set) var resultDocument: FaceScanDocument?
    @Published private(set) var exportURL: URL?
    @Published private(set) var objExportURL: URL?
    @Published private(set) var plyExportURL: URL?
    @Published private(set) var completedReliabilityScans = 0
    let requiredReliabilityScans = ReliabilityAnalyzer.requiredScanCount

    private weak var sceneView: ARSCNView?
    private let sessionQueue = DispatchQueue(label: "com.psllens.scanner.session", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "com.psllens.scanner.analysis", qos: .userInitiated)

    private var collecting = false
    private var samples: [[SIMD3<Float>]] = []
    private var depthSamples: [DepthRefinedFrame] = []
    private var triangleIndices: [Int] = []
    private var lastAcceptedTimestamp: TimeInterval = 0
    private var yawMinimum: Float = .greatestFiniteMagnitude
    private var yawMaximum: Float = -.greatestFiniteMagnitude
    private var depthFrames = 0
    private var rawDepthFrames = 0
    private var totalObservedFrames = 0
    private var guidedPoseTracker = GuidedPoseTracker()
    private var reliabilityDocuments = [FaceScanDocument]()

    // UI/lifecycle watchdog. These values are read and changed on the main queue.
    private var scanAttemptID: UUID?
    private var watchdogAcceptedFrames = 0
    private var watchdogMisses = 0

    private var targetFrameCount: Int { guidedPoseTracker.totalTarget }
    private let minimumSampleInterval: TimeInterval = 0.075

    func attach(to view: ARSCNView) {
        if let currentView = sceneView, currentView !== view {
            currentView.session.pause()
        }

        sceneView = view
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = true
        view.session.delegate = self
        view.session.delegateQueue = sessionQueue

        UIApplication.shared.isIdleTimerDisabled = true

        guard ARFaceTrackingConfiguration.isSupported else {
            state = .unsupported
            statusText = "ARKit Face Tracking не поддерживается на этом устройстве."
            return
        }

        runSession(reset: true, updateState: true)
    }

    func detach(from view: ARSCNView) {
        view.session.pause()

        if sceneView === view {
            sceneView = nil
        }

        UIApplication.shared.isIdleTimerDisabled = false
    }

    func pauseSession() {
        DispatchQueue.main.async { [weak self] in
            self?.sceneView?.session.pause()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func handleAppBecameActive() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { return }
            UIApplication.shared.isIdleTimerDisabled = true

            let shouldUpdateState: Bool
            switch self.state {
            case .scanning, .processing, .complete:
                shouldUpdateState = false
            default:
                shouldUpdateState = true
            }

            self.runSession(reset: true, updateState: shouldUpdateState)
        }
    }

    func handleAppBecameInactive() {
        sessionQueue.async { [weak self] in
            self?.collecting = false
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scanAttemptID = nil

            if self.state == .scanning {
                self.state = .failed("Сканирование было прервано системой.")
                self.statusText = "Вернись в приложение и запусти скан повторно."
                self.progress = 0
            }
        }

        pauseSession()
    }

    func startScan() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            guard ARFaceTrackingConfiguration.isSupported else {
                self.state = .unsupported
                self.statusText = "На устройстве нет поддержки ARKit Face Tracking."
                return
            }

            guard self.sceneView != nil else {
                self.state = .failed("Камера ещё не готова.")
                self.statusText = "Подожди секунду и нажми кнопку ещё раз."
                return
            }

            let attemptID = UUID()
            self.scanAttemptID = attemptID
            self.watchdogAcceptedFrames = 0
            self.watchdogMisses = 0

            // UI reacts immediately instead of waiting for the AR delegate queue.
            self.state = .scanning
            self.statusText = "Смотри прямо, затем медленно поверни голову в обе стороны."
            self.progress = 0
            self.acceptedFrames = 0
            self.rejectedFrames = 0
            self.capturedDepthFrames = 0
            self.trueDepthDetected = false
            self.summary = nil
            self.resultDocument = nil
            self.exportURL = nil
            self.objExportURL = nil
            self.plyExportURL = nil

            self.sessionQueue.async {
                self.samples.removeAll(keepingCapacity: true)
                self.depthSamples.removeAll(keepingCapacity: true)
                self.triangleIndices.removeAll(keepingCapacity: true)
                self.lastAcceptedTimestamp = 0
                self.yawMinimum = .greatestFiniteMagnitude
                self.yawMaximum = -.greatestFiniteMagnitude
                self.depthFrames = 0
                self.rawDepthFrames = 0
                self.totalObservedFrames = 0
                self.guidedPoseTracker.reset()
                self.collecting = true
            }

            // A paused/interrupted ARSession is explicitly resumed on every tap.
            self.runSession(reset: false, updateState: false)
            self.armProgressWatchdog(for: attemptID)
        }
    }

    func cancelScan() {
        sessionQueue.async { [weak self] in
            self?.collecting = false
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scanAttemptID = nil
            self.state = .ready
            self.statusText = "Сканирование отменено."
            self.progress = 0
        }
    }

    func resetForNewScan() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.collecting = false
            self.guidedPoseTracker.reset()
        }

        analysisQueue.async { [weak self] in
            self?.reliabilityDocuments.removeAll()
        }

        // Do not pause here: the capture view is recreated right after this state change.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scanAttemptID = nil
            self.state = .ready
            self.statusText = "Готово. Начни новую серию из трёх сканов."
            self.progress = 0
            self.acceptedFrames = 0
            self.rejectedFrames = 0
            self.capturedDepthFrames = 0
            self.trueDepthDetected = false
            self.completedReliabilityScans = 0
            self.summary = nil
            self.resultDocument = nil
            self.exportURL = nil
            self.objExportURL = nil
            self.plyExportURL = nil
        }
    }

    func continueReliabilitySeries() {
        guard completedReliabilityScans < requiredReliabilityScans else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = .ready
            self.statusText = "Контрольный скан \(self.completedReliabilityScans + 1) из \(self.requiredReliabilityScans)."
            self.progress = 0
            self.acceptedFrames = 0
            self.rejectedFrames = 0
            self.capturedDepthFrames = 0
            self.trueDepthDetected = false
            self.summary = nil
            self.resultDocument = nil
            self.exportURL = nil
            self.objExportURL = nil
            self.plyExportURL = nil

            self.startScanWhenCameraReady(remainingAttempts: 8)
        }
    }

    private func startScanWhenCameraReady(remainingAttempts: Int) {
        guard remainingAttempts > 0 else {
            state = .failed("Камера не успела подготовиться.")
            statusText = "Нажми кнопку начала скана ещё раз."
            return
        }

        if sceneView != nil {
            runSession(reset: true, updateState: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.startScan()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            self?.startScanWhenCameraReady(remainingAttempts: remainingAttempts - 1)
        }
    }

    var exportURLs: [URL] {
        [exportURL, objExportURL, plyExportURL].compactMap { $0 }
    }

    private func runSession(reset: Bool, updateState: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let sceneView = self.sceneView else { return }

            guard ARFaceTrackingConfiguration.isSupported else {
                self.state = .unsupported
                self.statusText = "ARKit Face Tracking не поддерживается на этом устройстве."
                return
            }

            let configuration = ARFaceTrackingConfiguration()
            configuration.isLightEstimationEnabled = true
            configuration.maximumNumberOfTrackedFaces = 1

            let options: ARSession.RunOptions = reset
                ? [.resetTracking, .removeExistingAnchors]
                : []

            sceneView.session.run(configuration, options: options)
            UIApplication.shared.isIdleTimerDisabled = true

            guard updateState else { return }

            switch self.state {
            case .scanning, .processing, .complete:
                break
            default:
                self.state = .ready
                self.statusText = "Готово. Держи iPhone вертикально на расстоянии 30–50 см."
            }
        }
    }

    private func armProgressWatchdog(for attemptID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self else { return }
            guard self.scanAttemptID == attemptID, self.state == .scanning else { return }

            if self.acceptedFrames == self.watchdogAcceptedFrames {
                self.watchdogMisses += 1

                if self.watchdogMisses == 1 {
                    self.statusText = "TrueDepth не присылает новые кадры. Перезапускаем камеру…"
                    self.runSession(reset: true, updateState: false)
                } else {
                    self.scanAttemptID = nil
                    self.sessionQueue.async {
                        self.collecting = false
                    }
                    self.state = .failed("Камера перестала присылать кадры.")
                    self.statusText = "Нажми «Начать 3D-скан» ещё раз."
                    self.progress = 0
                    return
                }
            } else {
                self.watchdogAcceptedFrames = self.acceptedFrames
                self.watchdogMisses = 0
            }

            self.armProgressWatchdog(for: attemptID)
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
            rawDepthFrames += 1
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

        let poseDecision = guidedPoseTracker.evaluate(yaw: yaw)
        guard poseDecision.acceptFrame else {
            publish {
                self.statusText = poseDecision.status
                self.progress = poseDecision.progress
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

        // Dense depth refinement is intentionally sampled on every second
        // accepted geometry frame to keep the live TrueDepth session responsive.
        if samples.count.isMultiple(of: 2),
           let depthSample = DepthFusionEngine.capture(
                frame: frame,
                face: face,
                arkitVertices: vertices
           ) {
            depthSamples.append(depthSample)
            depthFrames = depthSamples.count
            let currentDepthFrames = depthFrames
            publish {
                self.capturedDepthFrames = currentDepthFrames
            }
        }

        samples.append(vertices)
        lastAcceptedTimestamp = frame.timestamp
        yawMinimum = min(yawMinimum, yaw)
        yawMaximum = max(yawMaximum, yaw)

        let count = samples.count
        let progressValue = poseDecision.completed ? 1 : poseDecision.progress

        publish {
            self.acceptedFrames = count
            self.progress = progressValue
            self.statusText = poseDecision.status
        }

        if poseDecision.completed {
            finishScan(session: session)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        collecting = false
        publish {
            self.scanAttemptID = nil
            self.state = .failed(error.localizedDescription)
            self.statusText = "AR-сессия завершилась с ошибкой. Нажми кнопку для повтора."
            self.progress = 0
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        collecting = false
        publish {
            self.scanAttemptID = nil

            if self.state == .scanning {
                self.state = .failed("Сканирование было прервано системой.")
                self.statusText = "Камера была приостановлена. Нажми кнопку для нового скана."
                self.progress = 0
            } else {
                self.statusText = "Камера временно приостановлена системой."
            }
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        runSession(reset: true, updateState: true)
    }

    private func finishScan(session: ARSession) {
        guard collecting else { return }
        collecting = false

        let capturedSamples = samples
        let capturedDepthSamples = depthSamples
        let capturedTriangles = triangleIndices
        let capturedDepthFrames = depthFrames
        let capturedRawDepthFrames = rawDepthFrames
        let capturedRejected = rejectedFrames
        let capturedYawMin = yawMinimum
        let capturedYawMax = yawMaximum
        let observed = max(totalObservedFrames, 1)

        publish {
            self.scanAttemptID = nil
            self.state = .processing
            self.statusText = "Объединяем ARKit mesh с несколькими картами глубины…"
            self.progress = 1
        }

        analysisQueue.async {
            guard capturedRawDepthFrames > 0 else {
                self.publish {
                    self.state = .failed("ARKit не выдал карту глубины. Нужен iPhone с активной фронтальной TrueDepth-камерой.")
                    self.statusText = "TrueDepth не обнаружен."
                }
                return
            }

            do {
                let result = try self.makeDocument(
                    samples: capturedSamples,
                    depthSamples: capturedDepthSamples,
                    triangles: capturedTriangles,
                    depthFrames: capturedDepthFrames,
                    rejectedFrames: capturedRejected,
                    yawMin: capturedYawMin,
                    yawMax: capturedYawMax,
                    observedFrames: observed
                )

                self.reliabilityDocuments.append(result.document)
                if self.reliabilityDocuments.count > self.requiredReliabilityScans {
                    self.reliabilityDocuments = Array(
                        self.reliabilityDocuments.suffix(self.requiredReliabilityScans)
                    )
                }

                let consolidated = ReliabilityAnalyzer.consolidate(
                    documents: self.reliabilityDocuments,
                    requiredScanCount: self.requiredReliabilityScans
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(consolidated.document)

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let fileName = "PSL-TrueDepth-v4-\(formatter.string(from: Date())).json"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try data.write(to: url, options: .atomic)
                let objURL = try MeshExporter.writeOBJ(document: consolidated.document)
                let plyURL = try MeshExporter.writePLY(document: consolidated.document)

                self.publish {
                    self.statusText = consolidated.document.metrics.repeatability.status
                    self.completedReliabilityScans = consolidated.document.metrics.repeatability.scanCount
                    self.summary = consolidated.summary
                    self.resultDocument = consolidated.document
                    self.exportURL = url
                    self.objExportURL = objURL
                    self.plyExportURL = plyURL
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
        depthSamples: [DepthRefinedFrame],
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

        let fusion = DepthFusionEngine.fuse(
            baseMesh: medianMesh,
            frames: depthSamples,
            triangleIndices: triangles
        )
        let analysisMesh = fusion.metrics.applied ? fusion.mesh : medianMesh

        guard
            let minX = analysisMesh.map(\.x).min(),
            let maxX = analysisMesh.map(\.x).max(),
            let minY = analysisMesh.map(\.y).min(),
            let maxY = analysisMesh.map(\.y).max(),
            let minZ = analysisMesh.map(\.z).min(),
            let maxZ = analysisMesh.map(\.z).max()
        else {
            throw ScannerError.notEnoughData
        }

        let widthMM = (maxX - minX) * 1000
        let heightMM = (maxY - minY) * 1000
        let depthMM = (maxZ - minZ) * 1000
        let symmetryErrorMM = mirroredNearestNeighborError(mesh: analysisMesh) * 1000
        let stabilityErrorMM = meshStabilityError(samples: samples, medianMesh: medianMesh) * 1000
        let yawCoverageDegrees = max(0, yawMax - yawMin) * 180 / .pi

        let frameScore = min(1, Float(samples.count) / Float(targetFrameCount))
        let coverageScore = min(1, yawCoverageDegrees / 28)
        let depthScore = min(1, Float(depthFrames) / Float(max(samples.count / 2, 1)))
        let acceptanceScore = Float(samples.count) / Float(max(samples.count + rejectedFrames, 1))
        let stabilityScore = clamp(1 - stabilityErrorMM / 2.2, lower: 0, upper: 1)
        let fusionScore: Float

        if fusion.metrics.applied {
            let coverage = clamp(fusion.metrics.coveragePercent / 55, lower: 0, upper: 1)
            let residual = clamp(1 - fusion.metrics.medianResidualMM / 25, lower: 0, upper: 1)
            let temporal = clamp(1 - fusion.metrics.temporalNoiseMM / 8, lower: 0, upper: 1)
            fusionScore = coverage * 0.45 + residual * 0.30 + temporal * 0.25
        } else {
            fusionScore = 0.18
        }

        let qualityFloat =
            frameScore * 18 +
            coverageScore * 17 +
            depthScore * 15 +
            acceptanceScore * 15 +
            stabilityScore * 20 +
            fusionScore * 15

        let quality = Int(clamp(qualityFloat.rounded(), lower: 0, upper: 100))
        let analysis = analyzeSurface(
            mesh: analysisMesh,
            widthMM: widthMM,
            heightMM: heightMM,
            depthMM: depthMM,
            symmetryErrorMM: symmetryErrorMM,
            stabilityErrorMM: stabilityErrorMM,
            quality: quality,
            yawCoverageDegrees: yawCoverageDegrees,
            acceptedFrames: samples.count,
            rejectedFrames: rejectedFrames,
            depthFusion: fusion.metrics
        )

        let metrics = ScanMetrics(
            scanQuality: quality,
            reliability: analysis.reliability,
            overallPSLScore: analysis.pslScore,
            scoreRangeLow: analysis.scoreRangeLow,
            scoreRangeHigh: analysis.scoreRangeHigh,
            category: analysis.category,
            categoryIsFinal: false,
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
            depthFusion: fusion.metrics,
            repeatability: RepeatabilityMetrics.pending(
                scanCount: 1,
                requiredScanCount: requiredReliabilityScans,
                vertexCount: vertexCount
            ),
            featureMetrics: analysis.features,
            warnings: analysis.warnings
        )

        let vectors = analysisMesh.map {
            ScanVector(x: $0.x, y: $0.y, z: $0.z)
        }
        let arkitVectors = medianMesh.map {
            ScanVector(x: $0.x, y: $0.y, z: $0.z)
        }

        let document = FaceScanDocument(
            format: "psl-truedepth-guided-scan",
            version: 4,
            createdAt: Date(),
            deviceModel: deviceModel(),
            operatingSystem: UIDevice.current.systemVersion,
            coordinateSystem: "ARFaceAnchor local coordinates: x left/right, y up/down, z depth",
            units: "meters for vertices; millimeters for metric fields",
            vertexCount: vertexCount,
            triangleCount: triangles.count / 3,
            metrics: metrics,
            vertices: vectors,
            arkitVertices: arkitVectors,
            triangleIndices: triangles,
            notice: "Экспериментальный анализ наружной поверхности лица. В режиме Depth Fusion ARKit-сетка корректируется несколькими синхронными картами TrueDepth с ограничением выбросов и временной медианой. Это не показывает внутренние кости, не является медицинским исследованием и не измеряет объективную привлекательность."
        )

        let summary = ScanSummary(
            quality: quality,
            reliability: analysis.reliability,
            pslScore: analysis.pslScore,
            scoreRangeLow: analysis.scoreRangeLow,
            scoreRangeHigh: analysis.scoreRangeHigh,
            category: analysis.category,
            categoryIsFinal: false,
            symmetryErrorMM: symmetryErrorMM,
            stabilityErrorMM: stabilityErrorMM,
            widthMM: widthMM,
            heightMM: heightMM,
            depthMM: depthMM,
            yawCoverageDegrees: yawCoverageDegrees,
            acceptedFrames: samples.count,
            depthFusion: fusion.metrics,
            repeatability: metrics.repeatability,
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
        rejectedFrames: Int,
        depthFusion: DepthFusionMetrics
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
            0.20 +
            Float(100 - quality) * 0.009 +
            max(0, 24 - yawCoverageDegrees) * 0.012 +
            rejectionRatio * 0.30 +
            max(0, stabilityErrorMM - 0.7) * 0.08 +
            depthUncertainty,
            lower: 0.20,
            upper: 1.45
        )

        let low = clamp(pslScore - uncertainty, lower: 1, upper: 10)
        let high = clamp(pslScore + uncertainty, lower: 1, upper: 10)
        let reliability: String
        if quality >= 86 &&
            stabilityErrorMM <= 0.85 &&
            yawCoverageDegrees >= 25 &&
            depthFusion.applied &&
            depthFusion.coveragePercent >= 35 &&
            depthFusion.medianResidualMM <= 16 {
            reliability = "Высокая"
        } else if quality >= 68 &&
                    stabilityErrorMM <= 1.45 &&
                    yawCoverageDegrees >= 18 {
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
        if !depthFusion.applied {
            warnings.append("Depth Fusion не прошёл контроль покрытия или согласованности. Балл рассчитан по медианной ARKit-сетке, а диапазон расширен.")
        } else {
            if depthFusion.coveragePercent < 35 {
                warnings.append("Карта глубины уточнила только часть вершин. Попробуй более ровный свет и медленнее поверни голову.")
            }
            if depthFusion.medianResidualMM > 16 {
                warnings.append("ARKit mesh и плотная карта глубины расходились сильнее желаемого; влияние Depth Fusion автоматически ограничено.")
            }
            if depthFusion.temporalNoiseMM > 5 {
                warnings.append("Глубина менялась между кадрами. Держи расстояние и выражение лица стабильнее.")
            }
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
