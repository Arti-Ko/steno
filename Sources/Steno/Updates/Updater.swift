import AppKit
import Observation
import os

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
        /// Скачано и установится при выходе из приложения.
        case readyToInstall(ReleaseInfo)
        case installing(ReleaseInfo)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastCheck: Date?
    private(set) var checksAutomatically: Bool
    private(set) var installsAutomatically: Bool
    let currentVersion = AppVersion.current

    /// Найдена версия, о которой нужно спросить пользователя.
    @ObservationIgnored var onUpdateFound: ((ReleaseInfo) -> Void)?
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var stagedApp: URL?
    @ObservationIgnored private let logger = Logger(subsystem: "org.sleepycoffee.steno", category: "updates")

    private static let checkKey = "checkForUpdatesAutomatically"
    private static let installKey = "installUpdatesAutomatically"
    private static let skippedKey = "skippedUpdateVersion"
    private static let launchDelay: Duration = .seconds(8)
    private static let checkInterval: Duration = .seconds(6 * 3600)

    init() {
        let defaults = UserDefaults.standard
        checksAutomatically = defaults.object(forKey: Self.checkKey) as? Bool ?? true
        installsAutomatically = defaults.object(forKey: Self.installKey) as? Bool ?? true
        reschedule()
    }

    /// Обновлять можно только собранное приложение, а не бинарник из .build.
    var canUpdate: Bool {
        currentVersion != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    var availableRelease: ReleaseInfo? {
        switch phase {
        case .available(let release), .downloading(let release, _), .readyToInstall(let release), .installing(let release):
            release
        default:
            nil
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
        UserDefaults.standard.set(enabled, forKey: Self.checkKey)
        reschedule()
    }

    func setInstallsAutomatically(_ enabled: Bool) {
        installsAutomatically = enabled
        UserDefaults.standard.set(enabled, forKey: Self.installKey)
    }

    func check(userInitiated: Bool) async {
        if case .readyToInstall(let release) = phase {
            if userInitiated {
                onUpdateFound?(release)
            }
            return
        }
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

            let isSkipped = UserDefaults.standard.string(forKey: Self.skippedKey) == release.version.description
            if !userInitiated, isSkipped {
                phase = .available(release)
                return
            }
            if !userInitiated, installsAutomatically, UpdateInstaller.canReplaceRunningApp {
                download(release, relaunchWhenReady: false)
                return
            }
            phase = .available(release)
            onUpdateFound?(release)
        } catch {
            phase = .failed(error.localizedDescription)
            logger.error("Проверка обновлений: \(error.localizedDescription)")
            if userInitiated {
                showAlert(title: "Не удалось проверить обновления", message: error.localizedDescription)
            }
        }
    }

    /// Скачать, если ещё не скачано, и сразу перезапуститься в новую версию.
    func install(_ release: ReleaseInfo) {
        if case .readyToInstall(let ready) = phase, ready == release, let stagedApp {
            relaunch(into: stagedApp, release: release)
            return
        }
        download(release, relaunchWhenReady: true)
    }

    /// Вызывается при выходе: заранее скачанное обновление ставится без повторного запуска.
    func installPendingUpdateOnQuit() {
        guard case .readyToInstall = phase, let stagedApp else { return }
        do {
            try UpdateInstaller.install(stagedApp, relaunch: false)
        } catch {
            logger.error("Установка при выходе: \(error.localizedDescription)")
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    func skip(_ release: ReleaseInfo) {
        UserDefaults.standard.set(release.version.description, forKey: Self.skippedKey)
    }

    // MARK: Внутреннее

    private func download(_ release: ReleaseInfo, relaunchWhenReady: Bool) {
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
                self?.stagedApp = app
                if relaunchWhenReady {
                    self?.relaunch(into: app, release: release)
                } else {
                    self?.phase = .readyToInstall(release)
                }
            } catch {
                self?.phase = Task.isCancelled ? .available(release) : .failed(error.localizedDescription)
                self?.logger.error("Загрузка обновления: \(error.localizedDescription)")
            }
            self?.downloadTask = nil
        }
    }

    private func relaunch(into app: URL, release: ReleaseInfo) {
        phase = .installing(release)
        do {
            try UpdateInstaller.install(app, relaunch: true)
        } catch {
            phase = .failed(error.localizedDescription)
        }
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
