import AppKit
import Observation

/// Проверка выпусков на GitHub и установка обновлений.
@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, Double)
        case installing(ReleaseInfo)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastCheck: Date?
    private(set) var checksAutomatically: Bool
    let currentVersion = AppVersion.current

    /// Автоматическая проверка нашла версию, которую пользователь ещё не пропускал.
    @ObservationIgnored var onUpdateFound: ((ReleaseInfo) -> Void)?
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    private static let automaticKey = "checkForUpdatesAutomatically"
    private static let skippedKey = "skippedUpdateVersion"
    private static let launchDelay: Duration = .seconds(8)
    private static let checkInterval: Duration = .seconds(6 * 3600)

    init() {
        checksAutomatically = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
        reschedule()
    }

    /// Обновлять можно только собранное приложение, а не бинарник из .build.
    var canUpdate: Bool {
        currentVersion != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    var availableRelease: ReleaseInfo? {
        switch phase {
        case .available(let release), .downloading(let release, _), .installing(let release): release
        default: nil
        }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    func setChecksAutomatically(_ enabled: Bool) {
        checksAutomatically = enabled
        UserDefaults.standard.set(enabled, forKey: Self.automaticKey)
        reschedule()
    }

    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        phase = .checking
        do {
            let release = try await ReleaseFeed.latest()
            lastCheck = .now
            guard let release, let currentVersion, release.version > currentVersion else {
                phase = .upToDate
                if userInitiated {
                    showAlert(
                        title: "Установлена последняя версия",
                        message: "Steno \(currentVersion?.description ?? "") — самая свежая версия."
                    )
                }
                return
            }
            phase = .available(release)
            let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
            if userInitiated || skipped != release.version.description {
                onUpdateFound?(release)
            }
        } catch {
            phase = .failed(error.localizedDescription)
            if userInitiated {
                showAlert(title: "Не удалось проверить обновления", message: error.localizedDescription)
            }
        }
    }

    func install(_ release: ReleaseInfo) {
        guard downloadTask == nil else { return }
        phase = .downloading(release, 0)
        downloadTask = Task { [weak self] in
            do {
                let app = try await UpdateInstaller.download(release) { fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.phase else { return }
                        self.phase = .downloading(release, fraction)
                    }
                }
                try Task.checkCancellation()
                self?.phase = .installing(release)
                try UpdateInstaller.installAndRelaunch(app)
            } catch {
                self?.phase = Task.isCancelled ? .available(release) : .failed(error.localizedDescription)
            }
            self?.downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    func skip(_ release: ReleaseInfo) {
        UserDefaults.standard.set(release.version.description, forKey: Self.skippedKey)
    }

    private func reschedule() {
        scheduleTask?.cancel()
        guard checksAutomatically, canUpdate else { return }
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
