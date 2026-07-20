// MARK: - SecureInputPolicy

/// Pure policy for deciding whether a secure-input-looking client should bypass IMK composition.
///
/// `IsSecureEventInputEnabled()` is process-global, not scoped to the focused field.
/// Treat it as a warning signal: fail closed when the current client is incapable or
/// has no selection, but allow a normal marked-text-capable field to recover from a
/// stale flag left behind by another app. Avoid Accessibility probing on the hot path.
struct SecureInputSignals: Sendable {
    let bundleId: String
    let hasTextInputCapability: Bool
    let hasInvalidSelection: Bool
    let hasGlobalSecureInput: Bool
}

struct SecureInputPolicy: Sendable {
    static func isSystemSecureClient(_ bundleId: String) -> Bool {
        bundleId == "com.apple.SecurityAgent" ||
            bundleId == "com.apple.loginwindow" ||
            bundleId == "com.apple.screencaptureui"
    }

    static func shouldPassThrough(_ signals: SecureInputSignals) -> Bool {
        if isSystemSecureClient(signals.bundleId) {
            return true
        }

        // These are field-local signals. Never attempt marked text or document edits
        // when the current client cannot prove both capabilities.
        if signals.hasInvalidSelection || !signals.hasTextInputCapability {
            return true
        }

        if signals.hasGlobalSecureInput {
            // At this point the current client is a capable field with a valid
            // selection. The process-global flag can be stale after another app leaves
            // secure input enabled, so it must not disable Korean input system-wide.
            return false
        }

        return false
    }
}
