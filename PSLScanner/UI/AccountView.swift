import SwiftUI
import UniformTypeIdentifiers

struct AccountView: View {
    @EnvironmentObject private var accountStore: LocalAccountStore
    @EnvironmentObject private var historyStore: ScanHistoryStore
    @EnvironmentObject private var biometricLock: BiometricLockController
    @Binding var selectedTab: RootTab

    @State private var editedName = ""
    @State private var showingRename = false
    @State private var showingDeleteHistory = false
    @State private var showingDeleteProfile = false
    @State private var showingExportPassword = false
    @State private var showingImportPassword = false
    @State private var showingFileImporter = false
    @State private var showingShareSheet = false
    @State private var backupPassword = ""
    @State private var pendingImportURL: URL?
    @State private var shareItems = [Any]()
    @State private var alertMessage: String?

    private let accent = Color(red: 0.56, green: 1.0, blue: 0.25)

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    profileCard
                    statisticsCard
                    latestCard
                    backupCard
                    privacyCard
                    dangerZone
                }
                .padding(16)
                .padding(.bottom, 28)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Личный кабинет")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showingRename) {
            renameSheet
        }
        .sheet(isPresented: $showingExportPassword) {
            passwordSheet(
                title: "Пароль резервной копии",
                buttonTitle: "Создать копию"
            ) {
                if let url = historyStore.createEncryptedBackup(password: backupPassword) {
                    shareItems = [url]
                    showingExportPassword = false
                    showingShareSheet = true
                } else {
                    alertMessage = historyStore.lastError ?? "Не удалось создать копию."
                }
            }
        }
        .sheet(isPresented: $showingImportPassword) {
            passwordSheet(
                title: "Пароль для восстановления",
                buttonTitle: "Восстановить"
            ) {
                guard let pendingImportURL else { return }
                let success = historyStore.importEncryptedBackup(
                    from: pendingImportURL,
                    password: backupPassword
                )
                alertMessage = success
                    ? (historyStore.lastMessage ?? "История восстановлена.")
                    : (historyStore.lastError ?? "Не удалось восстановить историю.")
                if success {
                    showingImportPassword = false
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: shareItems)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let source = urls.first else { return }
                let accessed = source.startAccessingSecurityScopedResource()
                defer {
                    if accessed { source.stopAccessingSecurityScopedResource() }
                }
                do {
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Imported-\(UUID().uuidString).pslbackup")
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: source, to: destination)
                    pendingImportURL = destination
                    backupPassword = ""
                    showingImportPassword = true
                } catch {
                    alertMessage = "Не удалось прочитать выбранный файл."
                }
            case .failure:
                alertMessage = "Файл не выбран."
            }
        }
        .confirmationDialog(
            "Удалить всю историю анализов?",
            isPresented: $showingDeleteHistory,
            titleVisibility: .visible
        ) {
            Button("Удалить историю", role: .destructive) {
                historyStore.deleteAll()
            }
        }
        .confirmationDialog(
            "Удалить локальный профиль?",
            isPresented: $showingDeleteProfile,
            titleVisibility: .visible
        ) {
            Button("Удалить профиль и историю", role: .destructive) {
                historyStore.deleteAll()
                accountStore.deleteProfile()
            }
        }
        .alert(
            "PSL Scanner",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            Text(initials)
                .font(.system(size: 22, weight: .black, design: .rounded))
                .frame(width: 58, height: 58)
                .background(accent, in: Circle())
                .foregroundStyle(.black)

            VStack(alignment: .leading, spacing: 4) {
                Text(accountStore.profile?.displayName ?? "Профиль")
                    .font(.title3.bold())
                Text("Локальный кабинет · v0.6")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.48))
            }

            Spacer()

            Button {
                editedName = accountStore.profile?.displayName ?? ""
                showingRename = true
            } label: {
                Image(systemName: "pencil")
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .foregroundStyle(.white)
        }
        .padding(16)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
    }

    private var statisticsCard: some View {
        HStack(spacing: 10) {
            statistic("Анализы", "\(historyStore.statistics.count)")
            statistic(
                "Средний",
                historyStore.statistics.finalCount > 0
                    ? String(format: "%.2f", historyStore.statistics.averageScore)
                    : "—"
            )
            statistic(
                "Лучший",
                historyStore.statistics.finalCount > 0
                    ? String(format: "%.2f", historyStore.statistics.bestScore)
                    : "—"
            )
        }
    }

    @ViewBuilder
    private var latestCard: some View {
        if let record = historyStore.records.first {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Последний анализ", systemImage: "clock")
                        .font(.headline)
                    Spacer()
                    Text(record.savedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.44))
                }

                HStack(alignment: .lastTextBaseline) {
                    Text(String(format: "%.2f", record.score))
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundStyle(accent)
                    Text(record.category)
                        .font(.headline.bold())
                        .foregroundStyle(.white.opacity(0.62))
                    Spacer()
                    Text("R \(record.repeatabilityScore)%")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.white.opacity(0.48))
                }

                Button {
                    selectedTab = .history
                } label: {
                    Text("Открыть историю и прогресс")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                }
                .foregroundStyle(.white)
            }
            .padding(16)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var backupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Резервная копия", systemImage: "externaldrive.badge.icloud")
                .font(.headline)
                .foregroundStyle(accent)

            Text("Экспорт включает индекс истории, заметки и полные JSON meshes. Файл шифруется паролем и подходит для восстановления после переустановки.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.50))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                backupPassword = ""
                showingExportPassword = true
            } label: {
                Label("Создать зашифрованную копию", systemImage: "lock.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AccountPrimaryButtonStyle(accent: accent))
            .disabled(historyStore.records.isEmpty)
            .opacity(historyStore.records.isEmpty ? 0.45 : 1)

            Button {
                showingFileImporter = true
            } label: {
                Label("Восстановить из файла", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AccountSecondaryButtonStyle())
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Приватность", systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(accent)

            Toggle(
                "Защищать кабинет Face ID",
                isOn: Binding(
                    get: { biometricLock.isEnabled },
                    set: { biometricLock.isEnabled = $0 }
                )
            )
            .disabled(!biometricLock.isBiometricsAvailable)

            Text("До 50 последних анализов хранятся в Application Support приложения. Облачная синхронизация не используется.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.50))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
    }

    private var dangerZone: some View {
        VStack(spacing: 10) {
            Button(role: .destructive) {
                showingDeleteHistory = true
            } label: {
                Label("Удалить историю", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(.white.opacity(0.08))

            Button(role: .destructive) {
                showingDeleteProfile = true
            } label: {
                Label("Удалить локальный профиль", systemImage: "person.crop.circle.badge.minus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.subheadline.bold())
        .padding(16)
        .background(Color.red.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
    }

    private var renameSheet: some View {
        NavigationStack {
            VStack(spacing: 18) {
                TextField("Имя", text: $editedName)
                    .textInputAutocapitalization(.words)
                    .padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                Button {
                    accountStore.renameProfile(editedName)
                    showingRename = false
                } label: {
                    Text("Сохранить")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(accent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.black)
                        .font(.headline)
                }
                .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)

                Spacer()
            }
            .padding(20)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Изменить имя")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showingRename = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func passwordSheet(
        title: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        NavigationStack {
            VStack(spacing: 18) {
                SecureField("Минимум 6 символов", text: $backupPassword)
                    .textContentType(.newPassword)
                    .padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                Text("Без этого пароля восстановить файл невозможно. Пароль нигде не сохраняется.")
                    .font(.caption)
                    .foregroundStyle(.orange.opacity(0.78))

                Button(action: action) {
                    Text(buttonTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(accent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.black)
                }
                .disabled(backupPassword.count < 6)
                .opacity(backupPassword.count < 6 ? 0.45 : 1)

                Spacer()
            }
            .padding(20)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        showingExportPassword = false
                        showingImportPassword = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func statistic(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.44))
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private var initials: String {
        let parts = (accountStore.profile?.displayName ?? "PSL")
            .split(separator: " ")
            .prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

private struct AccountPrimaryButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .padding(.vertical, 12)
            .background(accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 13))
            .foregroundStyle(.black)
    }
}

private struct AccountSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .padding(.vertical, 12)
            .background(.white.opacity(configuration.isPressed ? 0.06 : 0.10), in: RoundedRectangle(cornerRadius: 13))
            .foregroundStyle(.white)
    }
}
