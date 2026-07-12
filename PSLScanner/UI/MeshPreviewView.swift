import SwiftUI
import SceneKit
import UIKit

enum MeshDisplayMode: String, CaseIterable, Identifiable {
    case fused
    case base
    case uncertainty
    case asymmetry
    case curvature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fused: return "Depth Fusion"
        case .base: return "ARKit base"
        case .uncertainty: return "Погрешность"
        case .asymmetry: return "Асимметрия"
        case .curvature: return "Кривизна"
        }
    }
}

struct MeshPreviewView: UIViewRepresentable {
    let document: FaceScanDocument
    let mode: MeshDisplayMode

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.scene = makeScene()
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        guard context.coordinator.mode != mode else { return }
        context.coordinator.mode = mode
        uiView.scene = makeScene()
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        let selectedVertices: [ScanVector]

        switch mode {
        case .base:
            selectedVertices = document.arkitVertices.isEmpty
                ? document.vertices
                : document.arkitVertices
        case .fused, .uncertainty, .asymmetry, .curvature:
            selectedVertices = document.vertices
        }

        let vertices = selectedVertices.map {
            SCNVector3($0.x, $0.y, $0.z)
        }

        guard !vertices.isEmpty, document.triangleIndices.count >= 3 else {
            return scene
        }

        let minX = vertices.map(\.x).min() ?? 0
        let maxX = vertices.map(\.x).max() ?? 0
        let minY = vertices.map(\.y).min() ?? 0
        let maxY = vertices.map(\.y).max() ?? 0
        let minZ = vertices.map(\.z).min() ?? 0
        let maxZ = vertices.map(\.z).max() ?? 0
        let center = SCNVector3(
            (minX + maxX) / 2,
            (minY + maxY) / 2,
            (minZ + maxZ) / 2
        )

        let centeredVertices = vertices.map {
            SCNVector3($0.x - center.x, $0.y - center.y, $0.z - center.z)
        }
        let vertexSource = SCNGeometrySource(vertices: centeredVertices)
        let indexValues = document.triangleIndices.map(UInt32.init)
        let indexData = indexValues.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indexValues.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let heatValues = valuesForHeatMode(vertexCount: centeredVertices.count)
        let geometry: SCNGeometry
        if let heatValues {
            let colorSource = makeColorSource(values: heatValues)
            geometry = SCNGeometry(
                sources: [vertexSource, colorSource],
                elements: [element]
            )

            let material = SCNMaterial()
            material.diffuse.contents = UIColor.white
            material.emission.contents = UIColor.white
            material.lightingModel = .constant
            material.isDoubleSided = true
            geometry.materials = [material]
        } else {
            geometry = SCNGeometry(sources: [vertexSource], elements: [element])
            geometry.materials = [wireMaterial]
        }

        let meshNode = SCNNode(geometry: geometry)
        meshNode.runAction(
            .repeatForever(
                .rotateBy(x: 0, y: .pi * 2, z: 0, duration: 15)
            )
        )
        scene.rootNode.addChildNode(meshNode)

        if heatValues != nil {
            let wireGeometry = SCNGeometry(sources: [vertexSource], elements: [element])
            let overlay = SCNMaterial()
            overlay.diffuse.contents = UIColor.black.withAlphaComponent(0.34)
            overlay.emission.contents = UIColor.black.withAlphaComponent(0.28)
            overlay.fillMode = .lines
            overlay.isDoubleSided = true
            overlay.lightingModel = .constant
            wireGeometry.materials = [overlay]

            let wireNode = SCNNode(geometry: wireGeometry)
            meshNode.addChildNode(wireNode)
        }

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 40
        cameraNode.camera?.zNear = 0.001
        cameraNode.camera?.zFar = 10
        cameraNode.position = SCNVector3(0, 0, 0.36)
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = heatValues == nil ? 500 : 850
        ambient.color = UIColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        if heatValues == nil {
            let key = SCNLight()
            key.type = .omni
            key.intensity = 700
            key.color = mode == .fused
                ? UIColor(red: 0.55, green: 1.0, blue: 0.30, alpha: 1)
                : UIColor(red: 0.40, green: 0.65, blue: 1.0, alpha: 1)
            let keyNode = SCNNode()
            keyNode.light = key
            keyNode.position = SCNVector3(0.16, 0.18, 0.24)
            scene.rootNode.addChildNode(keyNode)
        }

        return scene
    }

    private func valuesForHeatMode(vertexCount: Int) -> [Float]? {
        switch mode {
        case .uncertainty:
            let values = document.metrics.repeatability.vertexDeviationMM
            guard values.count == vertexCount,
                  document.metrics.repeatability.scanCount >= 2 else { return nil }
            return values.map { max(0, min($0 / 4.0, 1)) }

        case .asymmetry:
            let values = document.metrics.surfaceMaps.vertexAsymmetryMM
            guard values.count == vertexCount else { return nil }
            return values.map { max(0, min($0 / 4.0, 1)) }

        case .curvature:
            let values = document.metrics.surfaceMaps.vertexCurvatureIndex
            guard values.count == vertexCount else { return nil }
            return values.map { max(0, min($0 / 100, 1)) }

        case .fused, .base:
            return nil
        }
    }

    private var wireMaterial: SCNMaterial {
        let material = SCNMaterial()
        let fusionActive = document.metrics.depthFusion.applied && mode == .fused
        material.diffuse.contents = fusionActive
            ? UIColor(red: 0.52, green: 1.0, blue: 0.25, alpha: 0.94)
            : UIColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 0.90)
        material.emission.contents = fusionActive
            ? UIColor(red: 0.20, green: 0.70, blue: 0.08, alpha: 0.45)
            : UIColor(red: 0.10, green: 0.32, blue: 0.75, alpha: 0.40)
        material.fillMode = .lines
        material.isDoubleSided = true
        material.lightingModel = .constant
        return material
    }

    private func makeColorSource(values: [Float]) -> SCNGeometrySource {
        var components = [Float]()
        components.reserveCapacity(values.count * 4)

        for value in values {
            let color = heatmap(value: value)
            components.append(color.red)
            components.append(color.green)
            components.append(color.blue)
            components.append(1)
        }

        let data = components.withUnsafeBytes { Data($0) }
        return SCNGeometrySource(
            data: data,
            semantic: .color,
            vectorCount: values.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 4
        )
    }

    private func heatmap(value: Float) -> (red: Float, green: Float, blue: Float) {
        let t = max(0, min(value, 1))
        if t <= 0.5 {
            let local = t / 0.5
            return (local, 1, 0.20 * (1 - local))
        }

        let local = (t - 0.5) / 0.5
        return (1, 1 - local, 0)
    }

    final class Coordinator {
        var mode: MeshDisplayMode

        init(mode: MeshDisplayMode) {
            self.mode = mode
        }
    }
}
