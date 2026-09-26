import Foundation
import Cocoa

/// Decides whether PriType's custom toggle/hanja keys are suppressed for the
/// application that has keyboard focus.
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
/// ## Why the focus owner comes first
/// The frontmost app is not always the one the keys go to. Spotlight opens as a
/// non-activating panel: the app under it stays frontmost, and no activation
/// notification is posted either way, while every key goes to Spotlight's field.
/// With a remote-desktop client under it, that left the toggle paused in a field
/// that has nothing to do with the remote session.
///
/// PriType learns who has keyboard focus without asking anyone: IMK activates
/// its input controller for the field that gained focus and deactivates it for
/// the one that lost it, and the controller reports both here with the bundle
/// ID it already has (`focusDidMove(to:owner:)`, `focusDidLeave(owner:)`). That
/// is the focus owner. When there is none — no field is active (a remote session
/// capturing raw keys), the client gave no bundle ID, or another input source is
/// selected so IMK is not talking to PriType at all — the frontmost app decides,
/// as it always did.
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
        /// The app whose field IMK last activated PriType for, and which
        /// controller reported it: only that controller's deactivation clears it.
        var focusOwner: (bundleID: String, owner: ObjectIdentifier)?
        var excludedBundleIDs: Set<String> = []
        var observer: NSObjectProtocol?
    }

    private let state = Guarded(State())

    /// The app uses `shared`. A policy of its own keeps a test's focus changes
    /// out of the process-wide one.
    public init() {}

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

        guard state.withLock({ $0.observer == nil }) else { return }
        // Registering goes to the workspace's notification centre, which is not
        // this class's to make promises about. The tap thread waits on this lock
        // for every keystroke on the system, so nothing that can block belongs
        // inside it — the same rule `refreshExcludedBundleIDs` follows. Main-only
        // by precondition, so no second `start()` can be racing this one.
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.updateFrontmostBundleID(app?.bundleIdentifier)
        }
        state.withLock { $0.observer = observer }
    }

    /// Stop tracking. Clears both halves of the snapshot so no stale value can keep
    /// suppressing the toggle after monitoring ends.
    ///
    /// - Important: Main thread only, for the same reason as `start()`.
    public func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        // Clear the snapshot under the lock, unregister outside it: the removal
        // can synchronize against notification delivery already in flight, and a
        // keystroke must never wait on that.
        let observer = state.withLock { state -> NSObjectProtocol? in
            defer {
                state.observer = nil
                state.frontmostBundleID = nil
                state.focusOwner = nil
                state.excludedBundleIDs = []
            }
            return state.observer
        }
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    deinit {
        let observer = state.withLock { state -> NSObjectProtocol? in
            defer { state.observer = nil }
            return state.observer
        }
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
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
    ///
    /// Also forgets the focus owner. An app that has just activated owns the keys
    /// unless one of its fields says so itself, and that activation may have come
    /// just before this notification or may come after it — either way the
    /// answer is the same app. What this prevents is a field whose deactivation
    /// never arrived deciding for the app now in front.
    func updateFrontmostBundleID(_ bundleID: String?) {
        let normalized = bundleID.map(Self.normalize)
        state.withLock { state in
            state.frontmostBundleID = normalized
            state.focusOwner = nil
        }
    }

    /// IMK activated `owner` (an input controller) for a field of `bundleID`.
    /// A nil or blank bundle ID leaves the decision to the frontmost app.
    /// Main thread, from the IMK lifecycle.
    public func focusDidMove(to bundleID: String?, owner: ObjectIdentifier) {
        let normalized = bundleID.map(Self.normalize).flatMap { $0.isEmpty ? nil : $0 }
        state.withLock { state in
            state.focusOwner = normalized.map { ($0, owner) }
        }
    }

    /// IMK deactivated `owner`. Only the controller that reported the focus owner
    /// can clear it: IMK may deactivate the field being left after it has
    /// activated the next one, and that late call must not undo the new owner.
    public func focusDidLeave(owner: ObjectIdentifier) {
        state.withLock { state in
            if state.focusOwner?.owner == owner { state.focusOwner = nil }
        }
    }

    // MARK: - Hot Path

    /// Whether PriType's toggle/hanja keys must pass through untouched right now.
    ///
    /// Read from the CGEventTap callback: a lock-protected set lookup, no AX or
    /// workspace query.
    public var isTogglePaused: Bool {
        state.withLock { state in
            guard let target = state.focusOwner?.bundleID ?? state.frontmostBundleID,
                  !state.excludedBundleIDs.isEmpty else {
                return false
            }
            return state.excludedBundleIDs.contains(target)
        }
    }

    /// The bundle ID currently treated as frontmost (for diagnostics and tests).
    var currentFrontmostBundleID: String? {
        state.withLock { $0.frontmostBundleID }
    }

    /// The bundle ID of the focused field's app, if IMK has reported one.
    var currentFocusOwnerBundleID: String? {
        state.withLock { $0.focusOwner?.bundleID }
    }

    // MARK: - Pure Policy

    /// Bundle IDs are case-insensitive in practice; compare them that way so a
    /// list entry copied from a different source still matches.
    static func normalize(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Pure form of the decision, so the rule can be tested without any global state.
    static func isPaused(frontmostBundleID: String?, focusOwnerBundleID: String? = nil,
                         excludedBundleIDs: [String]) -> Bool {
        let owner = focusOwnerBundleID.map(normalize).flatMap { $0.isEmpty ? nil : $0 }
        guard let target = owner ?? frontmostBundleID.map(normalize) else { return false }
        let normalized = Set(excludedBundleIDs.map(normalize))
        return normalized.contains(target)
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
