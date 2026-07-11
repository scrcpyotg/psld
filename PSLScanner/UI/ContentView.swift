import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var scanner: FaceScanner
    @State private var showingShareSheet = false

    var body: some View {
        ZStack {
            ARFaceView(scanner: scanner)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    .black.opacity(0.72),
                    .clear,
                    .black.opacity(0.90)
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
        .sheet(isPresented: $showingShareSheet) {
            if let url = scanner.exportURL {
                ShareSheet(items: [url])
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("PSL SCANNER")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                Text("TrueDepth alpha · локальная обработка")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(scanner.trueDepthDetected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)

                Text(scanner.trueDepthDetected ? "DEPTH" : "AR")
                    .font(.caption2.bold())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.48), in: Capsule())
        }
    }

    private var faceGuide: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.70, 310)
            let height = width * 1.30

            RoundedRectangle(cornerRadius: width * 0.46)
                .stroke(
                    scanner.state == .scanning
                        ? Color.white.opacity(0.88)
                        : Color.white.opacity(0.38),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 8])
                )
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
                VStack(spacing: 7) {
                    ProgressView(value: scanner.progress)
                        .tint(.white)

                    HStack {
                        Text("Принято: \(scanner.acceptedFrames)")
                        Spacer()
                        Text("Отклонено: \(scanner.rejectedFrames)")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
                }
            }

            if let summary = scanner.summary {
                summaryGrid(summary)
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

    @ViewBuilder
    private func summaryGrid(_ summary: ScanSummary) -> some View {
        VStack(spacing: 10) {
            HStack {
                metric("Качество", "\(summary.quality)/100")
                metric("Кадры", "\(summary.acceptedFrames)")
                metric("Поворот", String(format: "%.0f°", summary.yawCoverageDegrees))
            }

            HStack {
                metric("Ширина", String(format: "%.1f мм", summary.widthMM))
                metric("Высота", String(format: "%.1f мм", summary.heightMM))
                metric("Глубина", String(format: "%.1f мм", summary.depthMM))
            }

            HStack {
                metric(
                    "3D-симметрия",
                    String(format: "%.2f мм", summary.symmetryErrorMM)
                )
                Spacer()
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.56))
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch scanner.state {
        case .checking:
            ProgressView()

        case .unsupported:
            Text("Нужен совместимый iPhone. На неподдерживаемом устройстве 3D-скан недоступен.")
                .font(.footnote)
                .foregroundStyle(.orange)

        case .ready, .failed:
            Button {
                scanner.startScan()
            } label: {
                Label("Начать 3D-скан", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())

        case .scanning:
            Button(role: .cancel) {
                scanner.cancelScan()
            } label: {
                Text("Отменить")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())

        case .processing:
            ProgressView("Обработка")
                .frame(maxWidth: .infinity)

        case .complete:
            HStack {
                Button {
                    scanner.startScan()
                } label: {
                    Label("Повторить", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    showingShareSheet = true
                } label: {
                    Label("JSON", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(scanner.exportURL == nil)
            }
        }
    }

    private var stateTitle: String {
        switch scanner.state {
        case .checking: return "Проверка устройства"
        case .unsupported: return "Нет поддержки"
        case .ready: return "Готов к сканированию"
        case .scanning: return "Идёт сканирование"
        case .processing: return "Строим 3D-модель"
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
        default: return .white
        }
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 13)
            .background(
                configuration.isPressed
                    ? Color.white.opacity(0.78)
                    : Color.white,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .foregroundStyle(.black)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
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
