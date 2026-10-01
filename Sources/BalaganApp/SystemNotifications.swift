import AppKit
import BalaganCore
import UserNotifications

/// Delivers macOS notifications for terminal activity (an agent finishing / asking for input).
///
/// When running as a packaged `.app` it uses the UserNotifications framework, so the banner shows
/// Balagan's own icon and clicking it activates Balagan and jumps to the waiting terminal. The
/// dev/`.build` binary has no bundle identifier — UNUserNotificationCenter would crash there — so it
/// falls back to `osascript`, which is why that path historically showed the generic script icon and
/// opened Script Editor on click.
// `onActivateSurface` is written once at launch and only read back on the main queue (inside the
// delegate callbacks below), so the shared instance is safe to share across threads.
final class SystemNotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = SystemNotificationPresenter()

    /// Called on the main actor when the user clicks a notification, with its task + surface.
    var onActivateSurface: ((TaskItem.ID, Surface.ID) -> Void)?

    /// What macOS said when we asked to post notifications. `denied`/`failed` is what an **ad-hoc
    /// signed** bundle gets — and also a correctly signed one whose bundle id has **duplicate
    /// LaunchServices registrations** (a `.previous` copy, the dist/ build): usernoted refuses the request
    /// outright (no Notifications entry is ever created in System Settings) and then silently drops every
    /// request we add. Fix: a stable signing identity (`scripts/make-signing-cert.sh`) and a clean
    /// install (`scripts/install-app.sh`), then click Allow on the prompt. While denied, `post` drops the
    /// banner and shows a one-time alert pointing at the fix — deliberately *not* the osascript
    /// fallback, which shows Script Editor's icon and opens Script Editor on click. Surfaced by
    /// `balagan status`.
    enum AuthorizationState: Equatable {
        case notRequested, requested, authorized, denied, failed(String)

        var description: String {
            switch self {
            case .notRequested: return "not requested (dev binary — osascript fallback)"
            case .requested: return "pending"
            case .authorized: return "authorized"
            case .denied: return "denied by macOS — sign the bundle (scripts/make-signing-cert.sh), reinstall with scripts/install-app.sh, relaunch, click Allow"
            case .failed(let reason): return "failed: \(reason) — sign the bundle (scripts/make-signing-cert.sh), reinstall with scripts/install-app.sh, relaunch"
            }
        }
    }

    private let stateLock = NSLock()
    private var _authorizationState: AuthorizationState = .notRequested
    private(set) var authorizationState: AuthorizationState {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _authorizationState }
        set { stateLock.lock(); _authorizationState = newValue; stateLock.unlock() }
    }

    /// Only a real `.app` bundle can use UNUserNotificationCenter (it needs a bundle identifier).
    private var usesUserNotifications: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Requests authorization and installs the delegate. No-op for the dev binary.
    func configure() {
        guard usesUserNotifications else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        authorizationState = .requested
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard let self else { return }
            if let error {
                self.authorizationState = .failed(error.localizedDescription)
                NSLog("Balagan notifications: authorization failed — %@", error.localizedDescription)
                return
            }
            // `granted` alone is not the whole story (a denied app reports false with no error), so
            // read the settled status back.
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: self.authorizationState = .authorized
                case .denied: self.authorizationState = .denied
                case .notDetermined: self.authorizationState = granted ? .authorized : .denied
                @unknown default: self.authorizationState = granted ? .authorized : .denied
                }
                if self.authorizationState != .authorized {
                    NSLog("Balagan notifications: %@", self.authorizationState.description)
                }
            }
        }
    }

    /// True when UNUserNotificationCenter would silently drop what we post.
    private var userNotificationsUnavailable: Bool {
        switch authorizationState {
        case .denied, .failed: return true
        case .notRequested, .requested, .authorized: return false
        }
    }

    private var deniedNoticeShown = false

    func post(title: String, body: String, taskID: TaskItem.ID?, surfaceID: Surface.ID?) {
        guard usesUserNotifications else {
            // Dev/.build binary: no bundle id, so UNUserNotificationCenter can't be used at all.
            Self.postViaOsascript(title: title, body: body)
            return
        }
        if userNotificationsUnavailable {
            // The launch-time answer may be stale: macOS can grant the permission later (the user
            // clicks Allow on the system prompt, or flips the switch in System Settings) without the app
            // being relaunched. Re-read the settled status before giving up on this banner.
            UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
                guard let self else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    self.authorizationState = .authorized
                    self.addUserNotification(title: title, body: body, taskID: taskID, surfaceID: surfaceID)
                default:
                    self.presentDeniedNoticeOnce()
                }
            }
            return
        }
        addUserNotification(title: title, body: body, taskID: taskID, surfaceID: surfaceID)
    }

    private func addUserNotification(title: String, body: String, taskID: TaskItem.ID?, surfaceID: Surface.ID?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var info: [String: String] = [:]
        if let taskID { info["taskID"] = taskID }
        if let surfaceID { info["surfaceID"] = surfaceID }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Once per launch: tell the user their banners are being dropped and why, instead of failing
    /// silently (or degrading to a Script Editor banner nobody wants).
    private func presentDeniedNoticeOnce() {
        stateLock.lock()
        let alreadyShown = deniedNoticeShown
        deniedNoticeShown = true
        stateLock.unlock()
        guard alreadyShown == false else { return }
        let state = authorizationState.description
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Balagan can't post notifications"
            alert.informativeText = """
            macOS is refusing notifications for this copy of Balagan (\(state)).

            macOS refuses notifications to ad-hoc signed bundles, and to bundles whose id has duplicate \
            LaunchServices registrations. Sign it (scripts/make-signing-cert.sh), rebuild with `make app`, \
            reinstall with scripts/install-app.sh, relaunch, and click Allow when macOS asks. Agent \
            "waiting" and "finished" banners are dropped until then; the in-app amber/attention badges still work.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Notification Settings")
            if alert.runModal() == .alertSecondButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // We only post when the target terminal isn't the focused one, so always show the banner —
        // even when Balagan is frontmost on a different task or the board.
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let taskID = info["taskID"] as? TaskItem.ID
        let surfaceID = info["surfaceID"] as? Surface.ID
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            if let taskID, let surfaceID {
                self?.onActivateSurface?(taskID, surfaceID)
            }
        }
        completionHandler()
    }

    /// Fallback for the dev binary: a banner via osascript. Attributed to Script Editor (script icon,
    /// click opens Script Editor). Passing text as argv — not interpolated — keeps it injection-safe.
    private static func postViaOsascript(title: String, body: String) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e", "on run argv",
                "-e", "display notification (item 1 of argv) with title (item 2 of argv)",
                "-e", "end run",
                body,
                title,
            ]
            try? process.run()
        }
    }
}
