import SwiftUI

enum RootTab: Hashable {
    case scan
    case history
    case account
}

struct ContentView: View {
    @EnvironmentObject private var scanner: FaceScanner
    @EnvironmentObject private var accountStore: LocalAccountStore
    @EnvironmentObject private var historyStore: ScanHistoryStore
    @EnvironmentObject private var biometricLock: BiometricLockController
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: RootTab = .scan

    var body: some View {
        Group {
            if accountStore.profile == nil {
                ProfileSetupView()
            } else if biometricLock.isEnabled && !biometricLock.isUnlocked {
                LockedAccountView()
            } else {
                mainTabs
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            historyStore.configure(profileID: accountStore.profile?.id)
        }
        .onChange(of: accountStore.profile?.id) { profileID in
            historyStore.configure(profileID: profileID)
        }
        .onChange(of: selectedTab) { tab in
            if tab == .scan {
                scanner.handleAppBecameActive()
            } else if scanner.state != .scanning && scanner.state != .processing {
                scanner.pauseSession()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                if selectedTab == .scan {
                    scanner.handleAppBecameActive()
                }
            case .inactive, .background:
                scanner.handleAppBecameInactive()
                biometricLock.lock()
            @unknown default:
                break
            }
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            ScanFlowView()
                .tabItem {
                    Label("Скан", systemImage: "viewfinder")
                }
                .tag(RootTab.scan)

            HistoryView(selectedTab: $selectedTab)
                .tabItem {
                    Label("История", systemImage: "clock.arrow.circlepath")
                }
                .tag(RootTab.history)

            AccountView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Кабинет", systemImage: "person.crop.circle")
                }
                .tag(RootTab.account)
        }
        .tint(Color(red: 0.56, green: 1.0, blue: 0.25))
    }
}

private struct ScanFlowView: View {
    @EnvironmentObject private var scanner: FaceScanner

    var body: some View {
        Group {
            if scanner.state == .complete,
               let summary = scanner.summary,
               let document = scanner.resultDocument {
                ResultsView(summary: summary, document: document)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                ScannerCaptureView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: scanner.state)
        .toolbar(
            scanner.state == .scanning || scanner.state == .processing
                ? .hidden
                : .visible,
            for: .tabBar
        )
    }
}

private struct ProfileSetupView: View {
    @EnvironmentObject private var accountStore: LocalAccountStore
    @State private var name = ""
    private let accent = Color(red: 0.56, green: 1.0, blue: 0.25)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [accent.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 520
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                Spacer()

                Image(systemName: "faceid")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(accent)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Личный кабинет")
                        .font(.system(size: 36, weight: .black, design: .rounded))
                    Text("Имя и последние 20 анализов сохраняются только на этом iPhone. Аккаунт не отправляется на сервер.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("Как тебя называть", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .padding(15)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }

                Button {
                    accountStore.createProfile(displayName: name)
                } label: {
                    Text("Создать локальный профиль")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accent, in: RoundedRectangle(cornerRadius: 15))
                        .foregroundStyle(.black)
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                .opacity(name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 ? 0.45 : 1)

                Text("TrueDepth-сканы содержат биометрическую геометрию поверхности лица. Не публикуй JSON/OBJ/PLY без необходимости.")
                    .font(.caption)
                    .foregroundStyle(.orange.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
            .padding(24)
        }
    }
}

private struct LockedAccountView: View {
    @EnvironmentObject private var biometricLock: BiometricLockController
    private let accent = Color(red: 0.56, green: 1.0, blue: 0.25)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 58))
                    .foregroundStyle(accent)

                Text("Кабинет заблокирован")
                    .font(.title2.bold())

                Text("Разблокируй приложение через Face ID или код-пароль устройства.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.58))
                    .multilineTextAlignment(.center)

                Button {
                    biometricLock.unlock()
                } label: {
                    Label("Разблокировать", systemImage: "faceid")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accent, in: RoundedRectangle(cornerRadius: 15))
                        .foregroundStyle(.black)
                }

                if let error = biometricLock.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
        }
        .onAppear {
            biometricLock.unlock()
        }
    }
}

private struct ScannerCaptureView: View {
    @EnvironmentObject private var scanner: FaceScanner
    private let accent = Color(red: 0.56, green: 1.0, blue: 0.25)

    var body: some View {
        ZStack {
            ARFaceView(scanner: scanner)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            LinearGradient(
                colors: [
                    .black.opacity(0.76),
                    .clear,
                    .black.opacity(0.92)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            faceGuide

            VStack(spacing: 16) {
                header
                Spacer()
                statusCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("PSL SCANNER")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                Text("TrueDepth · v0.5 · серия \(scanner.completedReliabilityScans + 1)/\(scanner.requiredReliabilityScans)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(scanner.trueDepthDetected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)

                Text(scanner.trueDepthDetected ? "DEPTH OK" : "AR READY")
                    .font(.caption2.bold())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.52), in: Capsule())
        }
    }

    private var faceGuide: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.70, 310)
            let height = width * 1.30

            ZStack {
                RoundedRectangle(cornerRadius: width * 0.46)
                    .stroke(
                        scanner.state == .scanning
                            ? accent.opacity(0.90)
                            : Color.white.opacity(0.40),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 8])
                    )

                Rectangle()
                    .fill(accent.opacity(scanner.state == .scanning ? 0.70 : 0))
                    .frame(width: width * 0.58, height: 1)

                Rectangle()
                    .fill(accent.opacity(scanner.state == .scanning ? 0.45 : 0))
                    .frame(width: 1, height: height * 0.66)
            }
            .frame(width: width, height: height)
            .position(
                x: geometry.size.width / 2,
                y: geometry.size.height * 0.43
            )
        }
        .allowsHitTesting(false)
    }

    private var statusCard: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: stateIcon)
                    .font(.title2)
                    .foregroundStyle(stateColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 5) {
                    Text(stateTitle)
                        .font(.headline)

                    Text(scanner.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.74))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            if scanner.state == .scanning || scanner.state == .processing {
                VStack(spacing: 8) {
                    ProgressView(value: scanner.progress)
                        .tint(accent)

                    HStack {
                        Text("Mesh: \(scanner.acceptedFrames)")
                        Spacer()
                        Text("Depth: \(scanner.capturedDepthFrames)")
                        Spacer()
                        Text("Reject: \(scanner.rejectedFrames)")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
                }
            }

            if scanner.state == .ready {
                HStack(spacing: 12) {
                    scanRule(icon: "iphone", text: "30–50 см")
                    scanRule(icon: "arrow.left.and.right", text: "5 позиций")
                    scanRule(icon: "repeat", text: "3 скана")
                }
            }

            actionButtons
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func scanRule(icon: String, text: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(accent)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch scanner.state {
        case .checking:
            ProgressView()

        case .unsupported:
            Text("Нужен iPhone с фронтальной TrueDepth-камерой.")
                .font(.footnote)
                .foregroundStyle(.orange)

        case .ready, .failed:
            Button {
                scanner.startScan()
            } label: {
                Label("Начать скан \(scanner.completedReliabilityScans + 1) из \(scanner.requiredReliabilityScans)", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ScannerPrimaryButtonStyle(accent: accent))

        case .scanning:
            Button(role: .cancel) {
                scanner.cancelScan()
            } label: {
                Text("Отменить")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ScannerSecondaryButtonStyle())

        case .processing:
            HStack(spacing: 10) {
                ProgressView()
                Text("Обработка 3D-сетки")
            }
            .frame(maxWidth: .infinity)

        case .complete:
            EmptyView()
        }
    }

    private var stateTitle: String {
        switch scanner.state {
        case .checking: return "Проверка устройства"
        case .unsupported: return "Нет поддержки"
        case .ready: return "Готов к сканированию"
        case .scanning: return "Идёт сканирование"
        case .processing: return "Строим 3D-профиль"
        case .complete: return "Скан готов"
        case .failed: return "Нужна повторная попытка"
        }
    }

    private var stateIcon: String {
        switch scanner.state {
        case .checking: return "sensor"
        case .unsupported: return "xmark.octagon"
        case .ready: return "faceid"
        case .scanning: return "viewfinder"
        case .processing: return "cube.transparent"
        case .complete: return "checkmark.seal"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var stateColor: Color {
        switch scanner.state {
        case .unsupported, .failed: return .orange
        case .complete: return .green
        default: return accent
        }
    }
}

private struct ScannerPrimaryButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 13)
            .background(
                accent.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .foregroundStyle(.black)
    }
}

private struct ScannerSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 13)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.08 : 0.14),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .foregroundStyle(.white)
    }
}
