import Foundation
import Cocoa

/// Decides whether PriType's custom toggle/hanja keys are suppressed for the
/// frontmost application.
///
/// ## Why this exists
/// Remote-desktop and virtualization clients (Windows App, VNC/RDP viewers, VMs)
/// need the physical key PriType binds — the guest OS has its own IME and expects
/// e.g. Right Command to reach it. Swallowing the key makes the remote session
/// impossible to switch languages in. Users list those apps here and PriType
/// passes the key straight through while they are frontmost.
///
/// ## Why the frontmost app is cached
/// The single hard constraint is that `isTogglePaused` runs inside the CGEventTap
/// callback, on every relevant key event. Querying the frontmost app — let alone
/// the focused Accessibility element — from there costs milliseconds per event and
/// is exactly what pushes a tap into `kCGEventTapDisabledByTimeout`. So the
/// frontmost bundle ID is captured from `NSWorkspace` activation notifications on
/// the main thread, and the callback only reads a cached string under a lock.
///
/// The same policy is consulted by `IOKitManager` (the hardware fallback) and by
/// the async toggle callbacks, so a user's exclusion cannot be bypassed by
/// whichever monitor happens to own the keyboard.
public final class ToggleExclusionPolicy: @unchecked Sendable {

    public static let shared = ToggleExclusionPolicy()

    private let lock = NSLock()
    private var frontmostBundleID: String?
    private var excludedBundleIDs: Set<String> = []
    private var observer: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    /// Begin tracking the frontmost application and the user's exclusion list.
    ///
    /// Safe to call more than once; later calls only refresh the snapshot.
    public func start(configuration: ConfigurationProviding = ConfigurationManager.shared) {
        refreshExcludedBundleIDs(from: configuration)
        updateFrontmostBundleID(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.updateFrontmostBundleID(app?.bundleIdentifier)
        }
    }

    /// Stop tracking. Clears the cached frontmost app so a stale value can never
    /// keep suppressing the toggle after monitoring ends.
    public func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        lock.lock()
        frontmostBundleID = nil
        lock.unlock()
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Snapshot Updates

    /// Re-read the user's exclusion list. Call after the settings UI changes it.
    public func refreshExcludedBundleIDs(from configuration: ConfigurationProviding = ConfigurationManager.shared) {
        let normalized = Set(configuration.toggleExcludedBundleIDs.map(Self.normalize))
        lock.lock()
        excludedBundleIDs = normalized
        lock.unlock()
    }

    /// Record the frontmost app. Internal so tests can drive it without a workspace.
    func updateFrontmostBundleID(_ bundleID: String?) {
        let normalized = bundleID.map(Self.normalize)
        lock.lock()
        frontmostBundleID = normalized
        lock.unlock()
    }

    // MARK: - Hot Path

    /// Whether PriType's toggle/hanja keys must pass through untouched right now.
    ///
    /// Read from the CGEventTap callback: a lock-protected set lookup, no AX or
    /// workspace query.
    public var isTogglePaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let frontmostBundleID, !excludedBundleIDs.isEmpty else { return false }
        return excludedBundleIDs.contains(frontmostBundleID)
    }

    /// The bundle ID currently treated as frontmost (for diagnostics and tests).
    var currentFrontmostBundleID: String? {
        lock.lock()
        defer { lock.unlock() }
        return frontmostBundleID
    }

    // MARK: - Pure Policy

    /// Bundle IDs are case-insensitive in practice; compare them that way so a
    /// list entry copied from a different source still matches.
    static func normalize(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Pure form of the decision, so the rule can be tested without any global state.
    static func isPaused(frontmostBundleID: String?, excludedBundleIDs: [String]) -> Bool {
        guard let frontmostBundleID else { return false }
        let normalized = Set(excludedBundleIDs.map(normalize))
        return normalized.contains(normalize(frontmostBundleID))
    }

    /// Add a bundle ID to a list without introducing duplicates or blank entries.
    static func adding(_ bundleID: String, to list: [String]) -> [String] {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list }
        guard !list.contains(where: { normalize($0) == normalize(trimmed) }) else { return list }
        return list + [trimmed]
    }

    /// Remove a bundle ID regardless of the case it was stored in.
    static func removing(_ bundleID: String, from list: [String]) -> [String] {
        list.filter { normalize($0) != normalize(bundleID) }
    }
}
