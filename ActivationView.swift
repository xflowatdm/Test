import SwiftUI

/// Экран активации: показывается, пока нет действующего ключа
struct ActivationView: View {
    @ObservedObject var license: LicenseManager
    @State private var keyText = ""
    @State private var copied = false

    var body: some View {
        ZStack {
            Theme.backdrop.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    deviceCard
                    keyCard

                    if let message = license.message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }

                    Text(LicenseConfig.contact)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(20)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            OnGradient {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .frame(width: 52, height: 52)
            }
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.gradientEdge, lineWidth: 1)
            )
            .gradientGlow(cornerRadius: 16, radius: 12, intensity: 0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text("SMOOTH FRAMES")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(.white)
                Text("Требуется активация")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.top, 20)
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SmallCaption(text: "Код устройства")
            Text(license.deviceCode)
                .font(.system(size: 30, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
            PrimaryButton(title: copied ? "Скопировано" : "Скопировать код", icon: "doc.on.doc", dark: true) {
                UIPasteboard.general.string = license.deviceCode
                copied = true
            }
        }
        .themedCard()
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SmallCaption(text: "Ключ активации")
            TextEditor(text: $keyText)
                .scrollContentBackground(.hidden)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(8)
                .frame(height: 120)
                .background(Theme.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            PrimaryButton(title: "Вставить из буфера", icon: "doc.on.clipboard", dark: true) {
                if let text = UIPasteboard.general.string { keyText = text }
            }
            PrimaryButton(title: "Активировать", icon: "key.fill") {
                if license.activate(keyText) { keyText = "" }
            }
        }
        .themedCard()
    }
}
