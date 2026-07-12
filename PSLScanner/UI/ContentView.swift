import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var scanner: FaceScanner
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                scanner.handleAppBecameActive()
            case .inactive, .background:
                scanner.handleAppBecameInactive()
            @unknown default:
                break
            }
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
                Text("TrueDepth 3D · обработка на устройстве")
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
                        Text("Принято: \(scanner.acceptedFrames)")
                        Spacer()
                        Text("Отклонено: \(scanner.rejectedFrames)")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
                }
            }

            if scanner.state == .ready {
                HStack(spacing: 12) {
                    scanRule(icon: "iphone", text: "30–50 см")
                    scanRule(icon: "face.smiling.inverse", text: "Нейтрально")
                    scanRule(icon: "light.max", text: "Ровный свет")
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
                Label("Начать 3D-скан", systemImage: "faceid")
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
