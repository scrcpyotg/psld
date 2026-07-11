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

    private let targetFrameCount = 90
    private let maximumFrameCount = 150
    private let minimumSampleInterval: TimeInterval = 0.085

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
            abs(pitch) < 0.42 &&
            abs(roll) < 0.30

        let expressionIsUsable =
            jawOpen < 0.22 &&
            smile < 0.38 &&
            blink < 0.82

        guard poseIsUsable, expressionIsUsable else {
            rejectedFrames += 1
            publish {
                self.rejectedFrames = self.rejectedFrames
            }

            if abs(roll) >= 0.30 {
                publishStatus("Не наклоняй голову к плечу.")
            } else if abs(pitch) >= 0.42 {
                publishStatus("Не поднимай и не опускай подбородок слишком сильно.")
            } else {
                publishStatus("Расслабь губы и лицо.")
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
        let coveragePart = min(1.0, Double(coverage / 0.38))
        let progressValue = min(0.99, framePart * 0.78 + coveragePart * 0.22)

        publish {
            self.acceptedFrames = count
            self.progress = progressValue
            self.statusText = self.guidanceText(count: count, yawMin: self.yawMinimum, yawMax: self.yawMaximum)
        }

        let hasCoverage = yawMinimum < -0.15 && yawMaximum > 0.15
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
            self.statusText = "Усредняем 3D-сетку и считаем повторяемые метрики…"
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
                let fileName = "PSL-TrueDepth-\(formatter.string(from: Date())).json"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try data.write(to: url, options: .atomic)

                self.publish {
                    self.state = .complete
                    self.statusText = "3D-скан готов. Сохрани JSON для проверки повторяемости."
                    self.summary = result.summary
                    self.exportURL = url
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
        let yawCoverageDegrees = max(0, yawMax - yawMin) * 180 / .pi

        let frameScore = min(1, Float(samples.count) / Float(targetFrameCount))
        let coverageScore = min(1, yawCoverageDegrees / 26)
        let depthScore = min(1, Float(depthFrames) / Float(max(samples.count, 1)))
        let acceptanceScore = Float(samples.count) / Float(max(samples.count + rejectedFrames, 1))

        let qualityFloat =
            frameScore * 30 +
            coverageScore * 25 +
            depthScore * 25 +
            acceptanceScore * 20

        let quality = Int(max(0, min(100, qualityFloat.rounded())))

        let metrics = ScanMetrics(
            scanQuality: quality,
            symmetryErrorMM: symmetryErrorMM,
            widthMM: widthMM,
            heightMM: heightMM,
            depthMM: depthMM,
            widthHeightRatio: widthMM / max(heightMM, 0.001),
            depthWidthRatio: depthMM / max(widthMM, 0.001),
            yawCoverageDegrees: yawCoverageDegrees,
            acceptedFrames: samples.count,
            rejectedFrames: rejectedFrames,
            depthFrames: depthFrames
        )

        let vectors = medianMesh.map {
            ScanVector(x: $0.x, y: $0.y, z: $0.z)
        }

        let document = FaceScanDocument(
            format: "psl-truedepth-mesh",
            version: 1,
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
            notice: "Это усреднённая сетка поверхности лица TrueDepth. Она не показывает внутренние кости и не является медицинским исследованием."
        )

        let summary = ScanSummary(
            quality: quality,
            symmetryErrorMM: symmetryErrorMM,
            widthMM: widthMM,
            heightMM: heightMM,
            depthMM: depthMM,
            yawCoverageDegrees: yawCoverageDegrees,
            acceptedFrames: samples.count
        )

        return (document, summary)
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

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2

        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }

        return sorted[middle]
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
        if count < 18 {
            return "Смотри прямо и держи лицо расслабленным."
        }
        if yawMin > -0.15 {
            return "Медленно поверни голову в одну сторону."
        }
        if yawMax < 0.15 {
            return "Теперь медленно поверни голову в другую сторону."
        }
        if count < targetFrameCount {
            return "Вернись к центру и не меняй выражение лица."
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
