import SwiftUI
import AVFoundation

// MARK: - Слой плеера

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Видео без системных элементов управления (кнопки рисует `MediaView`)
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

// MARK: - Состояние воспроизведения

/// Следит за плеером: играет ли он и сколько уже проиграно
final class PlaybackState: ObservableObject {
    @Published var isPlaying = false
    @Published var progress: Double = 0

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    func attach(_ newPlayer: AVPlayer) {
        guard newPlayer !== player else { return }
        detach()
        player = newPlayer
        progress = 0

        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            guard let self, let duration = self.player?.currentItem?.duration.seconds,
                  duration.isFinite, duration > 0 else { return }
            self.progress = min(1, max(0, time.seconds / duration))
        }
        statusObserver = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            DispatchQueue.main.async { self?.isPlaying = playing }
        }
        // Как в макете: видео играет по кругу
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: newPlayer.currentItem, queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero)
            self?.player?.play()
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    private func detach() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObserver?.invalidate()
        timeObserver = nil
        endObserver = nil
        statusObserver = nil
    }

    deinit {
        detach()
    }
}

// MARK: - Видео со стеклянными кнопками

/// Видео в скруглённой карточке: кнопка в правом верхнем углу (`corner`),
/// Play/Pause справа снизу и полоса прогресса во время воспроизведения
struct MediaView<Corner: View>: View {
    let player: AVPlayer
    var cornerRadius: CGFloat = 26
    @ViewBuilder var corner: () -> Corner

    @StateObject private var playback = PlaybackState()

    var body: some View {
        ZStack {
            Color(white: 0.067)
            PlayerSurface(player: player)

            VStack {
                HStack {
                    Spacer()
                    corner()
                }
                Spacer()
            }
            .padding(12)

            VStack {
                Spacer()
                HStack(alignment: .bottom, spacing: 12) {
                    progressBar
                        .padding(.bottom, 22)
                    playButton
                }
            }
            .padding(.leading, 16)
            .padding([.trailing, .bottom], 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .foregroundStyle(Color.white)
        .environment(\.colorScheme, .dark)
        .onAppear { playback.attach(player) }
        .onChange(of: ObjectIdentifier(player)) { _, _ in playback.attach(player) }
        .onDisappear { player.pause() }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3))
                Capsule()
                    .fill(Color.white)
                    .frame(width: geo.size.width * playback.progress)
            }
        }
        .frame(height: 3)
        .opacity(playback.isPlaying ? 1 : 0)
        .scaleEffect(x: 1, y: playback.isPlaying ? 1 : 0)
        .animation(Theme.soft, value: playback.isPlaying)
    }

    private var playButton: some View {
        Button {
            playback.toggle()
        } label: {
            ZStack {
                Image(systemName: "play.fill")
                    .opacity(playback.isPlaying ? 0 : 1)
                    .scaleEffect(playback.isPlaying ? 0.4 : 1)
                    .rotationEffect(.degrees(playback.isPlaying ? 90 : 0))
                Image(systemName: "pause.fill")
                    .opacity(playback.isPlaying ? 1 : 0)
                    .scaleEffect(playback.isPlaying ? 1 : 0.4)
                    .rotationEffect(.degrees(playback.isPlaying ? 0 : -90))
            }
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 48, height: 48)
            .glassEffect(.regular.interactive(), in: .circle)
            .animation(Theme.spring, value: playback.isPlaying)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(playback.isPlaying ? "Пауза" : "Воспроизвести")
    }
}

/// Стеклянная кнопка-капсула для угла видео («Заменить», «Оригинал»)
struct MediaCornerLabel: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 32)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}
