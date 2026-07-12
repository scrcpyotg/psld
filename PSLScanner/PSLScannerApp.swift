import SwiftUI

@main
struct PSLScannerApp: App {
    @StateObject private var scanner = FaceScanner()
    @StateObject private var accountStore = LocalAccountStore()
    @StateObject private var historyStore = ScanHistoryStore()
    @StateObject private var biometricLock = BiometricLockController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scanner)
                .environmentObject(accountStore)
                .environmentObject(historyStore)
                .environmentObject(biometricLock)
        }
    }
}
