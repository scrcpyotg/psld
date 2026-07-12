import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var accountStore: LocalAccountStore
    @EnvironmentObject private var historyStore: ScanHistoryStore
    @EnvironmentObject private var biometricLock: BiometricLockController
    @Binding var selectedTab: RootTab

    @State private var editedName = ""
    @State private var showingRename = false
    @State private var showingDeleteHistory = false
    @State private var showingDeleteProfile = false

    private let accent = Color(red: 0.56, green: 1.0, blue: 0.25)

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    profileCard
                    statisticsCard
                    latestCard
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
            "Удалить локальный профиль и все анализы?",
            isPresented: $showingDeleteProfile,
            titleVisibility: .visible
        ) {
            Button("Удалить профиль", role: .destructive) {
                historyStore.deleteAll()
                biometricLock.isEnabled = false
                accountStore.deleteProfile()
                selectedTab = .scan
            }
        }
    }

    private var profileCard: some View {
        HStack(spacing: 15) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.16))
                    .frame(width: 66, height: 66)
                Text(initials)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(accountStore.profile?.displayName ?? "Профиль")
                    .font(.title3.bold())
                Text("Локальный профиль · данные на устройстве")
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
                    Text("Открыть историю")
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

            Text("Скан-история хранится в Application Support приложения. При удалении приложения iOS удалит локальные данные вместе с ним.")
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
