import SwiftUI

// MARK: - Общие всплывающие элементы

struct SheetOption {
    let title: String
    var detail: String? = nil
}

struct OptionSheetConfig: Identifiable {
    let id = UUID()
    let title: String
    let options: [SheetOption]
    let selected: Int?
    let onSelect: (Int) -> Void
}

struct ToastItem: Equatable {
    let id = UUID()
    let text: String
    let tick: Bool
}

/// Шит выбора и тосты, общие для всех экранов
@MainActor
final class AppUI: ObservableObject {
    @Published var sheet: OptionSheetConfig?
    @Published var toast: ToastItem?

    private var hideTask: Task<Void, Never>?

    func pick(_ title: String, options: [SheetOption], selected: Int?, onSelect: @escaping (Int) -> Void) {
        sheet = OptionSheetConfig(title: title, options: options, selected: selected, onSelect: onSelect)
    }

    func show(_ text: String, tick: Bool = true) {
        withAnimation(Theme.spring) { toast = ToastItem(text: text, tick: tick) }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(text.count > 60 ? 4 : 2.2))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.soft) { self?.toast = nil }
        }
    }
}

// MARK: - Шит выбора

struct OptionSheet: View {
    let config: OptionSheetConfig
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Int?
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            Text(config.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .padding(.top, 24)
                .padding(.bottom, 10)

            ForEach(Array(config.options.enumerated()), id: \.offset) { index, option in
                Button {
                    select(index)
                } label: {
                    HStack(spacing: 8) {
                        Text(option.title)
                            .font(.system(size: 16, weight: chosen == index ? .semibold : .regular))
                        if let detail = option.detail {
                            Text(detail)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.text2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        TickMark(drawn: chosen == index)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .frame(height: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(OptionRowStyle())
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 14)
                .animation(Theme.soft.delay(0.09 + Double(index) * 0.035), value: shown)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .presentationDetents([.height(CGFloat(config.options.count) * 50 + 110)])
        .presentationDragIndicator(.visible)
        .onAppear {
            chosen = config.selected
            shown = true
        }
    }

    private func select(_ index: Int) {
        chosen = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            config.onSelect(index)
            dismiss()
        }
    }
}

private struct OptionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Theme.surface2 : Color.clear,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }
}

// MARK: - Тост

private struct ToastTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .offset(y: phase.isIdentity ? 0 : -30)
            .scaleEffect(phase.isIdentity ? 1 : 0.8)
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity ? 0 : 6)
    }
}

struct ToastHost: View {
    @EnvironmentObject private var ui: AppUI

    var body: some View {
        ZStack {
            if let toast = ui.toast {
                HStack(spacing: 8) {
                    if toast.tick {
                        AppearingTick()
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(toast.text)
                        .font(.system(size: 14, weight: .medium))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.text)
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .padding(.vertical, 10)
                .frame(minHeight: 40)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 24)
                .id(toast.id)
                .transition(ToastTransition())
            }
        }
        .padding(.top, 8)
        .allowsHitTesting(false)
    }
}
