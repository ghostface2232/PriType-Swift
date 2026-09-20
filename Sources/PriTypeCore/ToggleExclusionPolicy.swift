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
public final class ToggleExclusionPolicy: Sendable {

    public static let shared = ToggleExclusionPolicy()

    /// Everything mutable here, including the workspace observer.
    ///
    /// The observer used to sit outside the lock, on a class that promised to be
    /// `Sendable` anyway, with a comment saying the promise did not extend to it.
    /// That is the shape of hole this file is here to not have: `stop()` cleared
    /// it from main while nothing stopped another thread from reading it. It is
    /// cheap to put it under the same lock as the snapshot, so it is under it.
    private final class State {
        var frontmostBundleID: String?
        var excludedBundleIDs: Set<String> = []
        var observer: NSObjectProtocol?
    }

    private let state = Guarded(State())

    private init() {}

    // MARK: - Lifecycle

    /// Begin tracking the frontmost application and the user's exclusion list.
    ///
    /// Safe to call more than once; later calls only refresh the snapshot.
    ///
    /// - Important: Main thread only — `NSWorkspace` requires it. Thread safety
    ///   no longer rests on that: every field this touches is lock-protected.
    public func start(configuration: ConfigurationProviding = ConfigurationManager.shared) {
        dispatchPrecondition(condition: .onQueue(.main))
        refreshExcludedBundleIDs(from: configuration)
        updateFrontmostBundleID(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

        state.withLock { state in
            guard state.observer == nil else { return }
            state.observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.updateFrontmostBundleID(app?.bundleIdentifier)
            }
        }
    }

    /// Stop tracking. Clears both halves of the snapshot so no stale value can keep
    /// suppressing the toggle after monitoring ends.
    ///
    /// - Important: Main thread only, for the same reason as `start()`.
    public func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        state.withLock { state in
            if let observer = state.observer {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            state.observer = nil
            state.frontmostBundleID = nil
            state.excludedBundleIDs = []
        }
    }

    deinit {
        state.withLock { state in
            if let observer = state.observer {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
        }
    }

    // MARK: - Snapshot Updates

    /// Re-read the user's exclusion list. Call after the settings UI changes it.
    public func refreshExcludedBundleIDs(from configuration: ConfigurationProviding = ConfigurationManager.shared) {
        // Read the configuration outside the lock: it can go to the preferences
        // system, and the tap thread may be waiting on this lock for a keystroke.
        let normalized = Set(configuration.toggleExcludedBundleIDs.map(Self.normalize))
        state.withLock { $0.excludedBundleIDs = normalized }
    }

    /// Record the frontmost app. Internal so tests can drive it without a workspace.
    func updateFrontmostBundleID(_ bundleID: String?) {
        let normalized = bundleID.map(Self.normalize)
        state.withLock { $0.frontmostBundleID = normalized }
    }

    // MARK: - Hot Path

    /// Whether PriType's toggle/hanja keys must pass through untouched right now.
    ///
    /// Read from the CGEventTap callback: a lock-protected set lookup, no AX or
    /// workspace query.
    public var isTogglePaused: Bool {
        state.withLock { state in
            guard let frontmost = state.frontmostBundleID, !state.excludedBundleIDs.isEmpty else {
                return false
            }
            return state.excludedBundleIDs.contains(frontmost)
        }
    }

    /// The bundle ID currently treated as frontmost (for diagnostics and tests).
    var currentFrontmostBundleID: String? {
        state.withLock { $0.frontmostBundleID }
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
