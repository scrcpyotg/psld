import SwiftUI
import SceneKit
import UIKit

struct MeshPreviewView: UIViewRepresentable {
    let document: FaceScanDocument
    let useBaseMesh: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(useBaseMesh: useBaseMesh)
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
        guard context.coordinator.useBaseMesh != useBaseMesh else { return }
        context.coordinator.useBaseMesh = useBaseMesh
        uiView.scene = makeScene()
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        let selectedVertices = useBaseMesh && !document.arkitVertices.isEmpty
            ? document.arkitVertices
            : document.vertices
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
        let source = SCNGeometrySource(vertices: centeredVertices)
        let indexValues = document.triangleIndices.map(UInt32.init)
        let indexData = indexValues.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indexValues.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [source], elements: [element])
        let wireMaterial = SCNMaterial()
        let fusionActive = document.metrics.depthFusion.applied && !useBaseMesh
        wireMaterial.diffuse.contents = fusionActive
            ? UIColor(red: 0.52, green: 1.0, blue: 0.25, alpha: 0.94)
            : UIColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 0.90)
        wireMaterial.emission.contents = fusionActive
            ? UIColor(red: 0.20, green: 0.70, blue: 0.08, alpha: 0.45)
            : UIColor(red: 0.10, green: 0.32, blue: 0.75, alpha: 0.40)
        wireMaterial.fillMode = .lines
        wireMaterial.isDoubleSided = true
        wireMaterial.lightingModel = .constant
        geometry.materials = [wireMaterial]

        let meshNode = SCNNode(geometry: geometry)
        meshNode.runAction(
            .repeatForever(
                .rotateBy(x: 0, y: .pi * 2, z: 0, duration: 14)
            )
        )
        scene.rootNode.addChildNode(meshNode)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 40
        cameraNode.camera?.zNear = 0.001
        cameraNode.camera?.zFar = 10
        cameraNode.position = SCNVector3(0, 0, 0.36)
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 500
        ambient.color = UIColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .omni
        key.intensity = 700
        key.color = fusionActive
            ? UIColor(red: 0.55, green: 1.0, blue: 0.30, alpha: 1)
            : UIColor(red: 0.40, green: 0.65, blue: 1.0, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(0.16, 0.18, 0.24)
        scene.rootNode.addChildNode(keyNode)

        return scene
    }

    final class Coordinator {
        var useBaseMesh: Bool

        init(useBaseMesh: Bool) {
            self.useBaseMesh = useBaseMesh
        }
    }
}
