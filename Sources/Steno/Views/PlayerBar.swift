import SwiftUI

struct PlayerBar: View {
    @Environment(AppModel.self) private var app
    @State private var scrubPosition: Double?

    var body: some View {
        let player = app.player
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Button { player.skip(by: -5) } label: {
                    Image(systemName: "gobackward.5")
                }
                .help("Назад на 5 секунд")
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 30, height: 30)
                        .contentTransition(.symbolEffect(.replace))
                }
                .help(player.isPlaying ? "Пауза" : "Воспроизвести")
                Button { player.skip(by: 5) } label: {
                    Image(systemName: "goforward.5")
                }
                .help("Вперёд на 5 секунд")
            }
            .buttonStyle(.plain)
            .font(.title3)

            Text(TimeFormat.clock(scrubPosition ?? player.currentTime))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)

            Slider(
                value: Binding(get: { scrubPosition ?? player.currentTime }, set: { scrubPosition = $0 }),
                in: 0...max(player.duration, 1)
            ) { isEditing in
                guard !isEditing, let position = scrubPosition else { return }
                player.seek(to: position)
                scrubPosition = nil
            }
            .controlSize(.small)

            Text(TimeFormat.clock(player.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)

            Menu {
                ForEach(PlayerModel.rates, id: \.self) { rate in
                    Button {
                        player.setRate(rate)
                    } label: {
                        if rate == player.rate {
                            Label(rate.rateLabel, systemImage: "checkmark")
                        } else {
                            Text(rate.rateLabel)
                        }
                    }
                }
            } label: {
                Text(player.rate.rateLabel)
                    .monospacedDigit()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Скорость воспроизведения")
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: 680)
        .glassEffect(.regular, in: .capsule)
        .disabled(!player.hasMedia)
    }
}
