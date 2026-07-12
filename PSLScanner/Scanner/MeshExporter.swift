import Foundation

enum MeshExporter {
    static func writeOBJ(document: FaceScanDocument) throws -> URL {
        var output = "# PSL Scanner TrueDepth mesh\n"
        output += "# Units: meters\n"
        output += "# Vertices: \(document.vertices.count)\n"
        output += "# Faces: \(document.triangleIndices.count / 3)\n"

        for vertex in document.vertices {
            output += String(format: "v %.7f %.7f %.7f\n", vertex.x, vertex.y, vertex.z)
        }

        var index = 0
        while index + 2 < document.triangleIndices.count {
            let a = document.triangleIndices[index] + 1
            let b = document.triangleIndices[index + 1] + 1
            let c = document.triangleIndices[index + 2] + 1
            output += "f \(a) \(b) \(c)\n"
            index += 3
        }

        let url = temporaryURL(document: document, extension: "obj")
        try output.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func writePLY(document: FaceScanDocument) throws -> URL {
        let deviations = document.metrics.repeatability.vertexDeviationMM
        let hasHeatmap = deviations.count == document.vertices.count && deviations.contains { $0 > 0 }

        var output = "ply\n"
        output += "format ascii 1.0\n"
        output += "comment PSL Scanner TrueDepth mesh\n"
        output += "comment units meters\n"
        output += "element vertex \(document.vertices.count)\n"
        output += "property float x\n"
        output += "property float y\n"
        output += "property float z\n"
        output += "property uchar red\n"
        output += "property uchar green\n"
        output += "property uchar blue\n"
        output += "element face \(document.triangleIndices.count / 3)\n"
        output += "property list uchar int vertex_indices\n"
        output += "end_header\n"

        for (index, vertex) in document.vertices.enumerated() {
            let deviation = hasHeatmap ? deviations[index] : 0
            let color = heatmapColor(deviationMM: deviation, enabled: hasHeatmap)
            output += String(
                format: "%.7f %.7f %.7f %d %d %d\n",
                vertex.x,
                vertex.y,
                vertex.z,
                color.red,
                color.green,
                color.blue
            )
        }

        var index = 0
        while index + 2 < document.triangleIndices.count {
            output += "3 \(document.triangleIndices[index]) \(document.triangleIndices[index + 1]) \(document.triangleIndices[index + 2])\n"
            index += 3
        }

        let url = temporaryURL(document: document, extension: "ply")
        try output.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func temporaryURL(
        document: FaceScanDocument,
        extension fileExtension: String
    ) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "PSL-TrueDepth-v5-\(formatter.string(from: document.createdAt)).\(fileExtension)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private static func heatmapColor(
        deviationMM: Float,
        enabled: Bool
    ) -> (red: Int, green: Int, blue: Int) {
        guard enabled else { return (132, 255, 64) }

        let t = max(0, min(deviationMM / 4.0, 1))
        if t <= 0.5 {
            let local = t / 0.5
            return (
                Int(255 * local),
                255,
                Int(64 * (1 - local))
            )
        }

        let local = (t - 0.5) / 0.5
        return (
            255,
            Int(255 * (1 - local)),
            0
        )
    }
}
