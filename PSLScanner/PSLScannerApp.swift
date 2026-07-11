import SwiftUI

@main
struct PSLScannerApp: App {
    @StateObject private var scanner = FaceScanner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scanner)
        }
    }
}
