import Carbon
import Foundation

// MARK: - LatinLayoutProbe

/// Reads what a Latin keyboard layout puts on the letter keys, before any of
/// them is typed.
///
/// `LatinLayoutObserver` learns that a layout moved punctuation onto the letter
/// keys from a letter key typing it. Until one does, the first punctuation of a
/// session comes from the layout's own positions, which 두벌식 has taken for jamo:
/// on AZERTY the first comma typed after the input method starts is a ";". The
/// layout itself says the same thing without waiting, so the observer starts
/// from it.
enum LatinLayoutProbe {
    /// The letter keys whose unshifted character in `layoutData` (a `uchr`
    /// resource) is not a letter. A dead key types nothing yet and is no evidence
    /// either way, as in `LatinLayoutObserver.observe`.
    static func lettersTypingOtherwise(in layoutData: Data) -> Set<UInt16> {
        layoutData.withUnsafeBytes { raw -> Set<UInt16> in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return [] }
            var keys: Set<UInt16> = []
            for keyCode in QwertyKeyMap.letterKeyCodes {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0,
                                            UInt32(LMGetKbdType()), 0, &deadKeyState,
                                            characters.count, &length, &characters)
                guard status == noErr, length > 0,
                      let typed = String(utf16CodeUnits: characters, count: length).first,
                      String(typed).utf16.count == length else { continue }
                if !typed.isLetter { keys.insert(keyCode) }
            }
            return keys
        }
    }

    /// The `uchr` data of an input source, if it is a keyboard layout that has one.
    static func layoutData(of source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    static func sourceID(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

// MARK: - LatinLayoutWatcher

/// Keeps the composer's layout verdict on the Latin layout macOS translates keys
/// with. That layout is the current keyboard layout, which for an input method is
/// the last ASCII-capable layout the user selected; it changes only with a
/// selection, so it is read at launch and again when macOS announces one.
public enum LatinLayoutWatcher {
    @MainActor private static var observer: DistributedNotificationObserver?
    @MainActor private static var lastLayoutID: String?

    /// Seed the composer from the current layout, and again whenever the
    /// selection changes. Main thread; safe to call again.
    @MainActor
    public static func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationObserver(
            name: kTISNotifySelectedKeyboardInputSourceChanged as String
        ) {
            MainActor.assumeIsolated { refresh() }
        }
        refresh()
    }

    /// Read the current layout. Selecting PriType's own modes posts the same
    /// notification, so an unchanged layout is left alone: the observer may have
    /// learned something since, such as a client overridden to ABC.
    @MainActor
    private static func refresh() {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let id = LatinLayoutProbe.sourceID(of: source),
              id != lastLayoutID else { return }
        lastLayoutID = id
        let keys = LatinLayoutProbe.layoutData(of: source).map(LatinLayoutProbe.lettersTypingOtherwise(in:)) ?? []
        PriTypeInputController.sharedComposer.assumeLatinLayout(lettersTypingOtherwise: keys)
        DebugLogger.log("LatinLayoutWatcher: \(id) puts non-letters on \(keys.count) letter key(s)")
    }
}
