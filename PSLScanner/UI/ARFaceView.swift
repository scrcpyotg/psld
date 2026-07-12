import SwiftUI
import ARKit
import SceneKit

struct ARFaceView: UIViewRepresentable {
    @ObservedObject var scanner: FaceScanner

    final class Coordinator {
        weak var scanner: FaceScanner?

        init(scanner: FaceScanner) {
            self.scanner = scanner
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scanner: scanner)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.backgroundColor = .black
        view.contentMode = .scaleAspectFill
        scanner.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(
        _ uiView: ARSCNView,
        coordinator: Coordinator
    ) {
        coordinator.scanner?.detach(from: uiView)
    }
}
