import SwiftUI
import SceneKit
import UIKit

struct ComparisonMeshView: UIViewRepresentable {
    let document: FaceScanDocument
    let result: ScanComparisonResult

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
        uiView.scene = makeScene()
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        let count = min(result.alignedTargetVertices.count, result.signedVertexChangeMM.count)
        guard count > 0, document.triangleIndices.count >= 3 else { return scene }

        let rawVertices = Array(result.alignedTargetVertices.prefix(count)).map {
            SCNVector3($0.x, $0.y, $0.z)
        }
        let center = centroid(rawVertices)
        let vertices = rawVertices.map {
            SCNVector3($0.x - center.x, $0.y - center.y, $0.z - center.z)
        }

        let validIndices = document.triangleIndices.filter { $0 >= 0 && $0 < count }
        guard validIndices.count >= 3 else { return scene }
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let indexValues = validIndices.map(UInt32.init)
        let indexData = indexValues.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indexValues.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let colorSource = makeColorSource(count: count)
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        material.emission.contents = UIColor.white
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]

        let meshNode = SCNNode(geometry: geometry)
        meshNode.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 16)))
        scene.rootNode.addChildNode(meshNode)

        let wireGeometry = SCNGeometry(sources: [vertexSource], elements: [element])
        let wire = SCNMaterial()
        wire.diffuse.contents = UIColor.black.withAlphaComponent(0.32)
        wire.emission.contents = UIColor.black.withAlphaComponent(0.24)
        wire.fillMode = .lines
        wire.lightingModel = .constant
        wire.isDoubleSided = true
        wireGeometry.materials = [wire]
        meshNode.addChildNode(SCNNode(geometry: wireGeometry))

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 40
        camera.camera?.zNear = 0.001
        camera.camera?.zFar = 10
        camera.position = SCNVector3(0, 0, 0.36)
        scene.rootNode.addChildNode(camera)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 900
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
        return scene
    }

    private func makeColorSource(count: Int) -> SCNGeometrySource {
        var components = [Float]()
        components.reserveCapacity(count * 4)

        for index in 0..<count {
            let isReliable = result.reliableVertices.indices.contains(index)
                ? result.reliableVertices[index]
                : false
            let value = result.signedVertexChangeMM[index]
            let color = comparisonColor(valueMM: value, reliable: isReliable)
            components.append(color.0)
            components.append(color.1)
            components.append(color.2)
            components.append(1)
        }

        let data = components.withUnsafeBytes { Data($0) }
        return SCNGeometrySource(
            data: data,
            semantic: .color,
            vectorCount: count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 4
        )
    }

    private func comparisonColor(valueMM: Float, reliable: Bool) -> (Float, Float, Float) {
        guard reliable else { return (0.32, 0.32, 0.34) }
        let t = max(-1, min(valueMM / 4, 1))
        if t < 0 {
            let amount = -t
            return (0.22 * (1 - amount), 0.85 * (1 - amount) + 0.18, 0.32 + 0.68 * amount)
        }
        let amount = t
        return (0.20 + 0.80 * amount, 0.88 * (1 - amount) + 0.12, 0.24 * (1 - amount))
    }

    private func centroid(_ vertices: [SCNVector3]) -> SCNVector3 {
        guard !vertices.isEmpty else { return SCNVector3Zero }
        let sum = vertices.reduce(SCNVector3Zero) {
            SCNVector3($0.x + $1.x, $0.y + $1.y, $0.z + $1.z)
        }
        let divisor = Float(vertices.count)
        return SCNVector3(sum.x / divisor, sum.y / divisor, sum.z / divisor)
    }
}
