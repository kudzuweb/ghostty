import Sparkle
import Cocoa
import Combine

/// Standard controller for managing Sparkle updates in Ghostty.
///
/// This controller wraps SPUStandardUpdaterController to provide a simpler interface
/// for managing updates with Ghostty's custom driver and delegate. It handles
/// initialization, starting the updater, and provides the check for updates action.
class UpdateController {
    private var updater: SPUUpdater
    private let userDriver: UpdateDriver
    private var installCancellable: AnyCancellable?

    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }

    /// True if we're installing an update.
    var isInstalling: Bool {
        installCancellable != nil
    }

    /// Initialize a new update controller.
    init() {
        let hostBundle = Bundle.main
        self.userDriver = UpdateDriver(
            viewModel: .init(),
            hostBundle: hostBundle)
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: userDriver
        )
    }

    deinit {
        installCancellable?.cancel()
    }

    /// Start the updater.
    ///
    /// This must be called before the updater can check for updates. If starting fails,
    /// the error will be shown to the user.
    func startUpdater() {
        // Fork builds must never start Sparkle: upstream binaries replace this fork.
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
    }

    /// Force install the current update. As long as we're in some "update available" state this will
    /// trigger all the steps necessary to complete the update.
    func installUpdate() {
        // Informational release checks are the only update path in this fork.
        return
    }

    /// Check for updates.
    ///
    /// This is typically connected to a menu item action.
    @objc func checkForUpdates() {
        Task { @MainActor in ReleaseCheck.shared.checkNow() }
    }

    /// Validate the check for updates menu item.
    ///
    /// - Parameter item: The menu item to validate
    /// - Returns: Whether the menu item should be enabled
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) {
            return true
        }
        return true
    }
}
