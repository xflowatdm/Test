import SwiftUI

/// Экран активации: показывается, пока нет действующего ключа
struct ActivationView: View {
    @ObservedObject var license: LicenseManager
    @State private var keyText = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(license.deviceCode)
                        .font(.system(size: 30, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .padding(.vertical, 4)
                    ActionRow(title: copied ? "Скопировано" : "Скопировать код", icon: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = license.deviceCode
                        withAnimation(Theme.spring) { copied = true }
                    }
                } header: {
                    SectionLabel("Требуется активация. Код устройства")
                }
                .surfaceRow()
                .rise(1)

                Section {
                    TextEditor(text: $keyText)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(height: 120)
                    ActionRow(title: "Вставить из буфера", icon: "doc.on.clipboard") {
                        if let text = UIPasteboard.general.string { keyText = text }
                    }
                } header: {
                    SectionLabel("Ключ активации")
                } footer: {
                    if let message = license.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text2)
                    }
                }
                .surfaceRow()
                .rise(2)

                Section {
                    Button {
                        if license.activate(keyText) { keyText = "" }
                    } label: {
                        Label("Активировать", systemImage: "key.fill")
                            .font(.system(size: 16.5, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Note(LicenseConfig.contact)
                        .padding(.top, 8)
                }
                .rise(3)
            }
            .themedList()
            .navigationTitle("Smooth Frames")
        }
    }
}
