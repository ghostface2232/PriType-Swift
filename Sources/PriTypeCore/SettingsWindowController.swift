import Cocoa
import SwiftUI
import Carbon

/// Manages the settings window for the input method
@MainActor
public class SettingsWindowController: NSObject {

    public static let shared = SettingsWindowController()

    private var window: NSWindow?

    /// Pane a freshly created settings view should open on.
    ///
    /// The view reads this while its state is being set up, which is the only
    /// moment its selection can be chosen from outside. An already-open window
    /// is moved by `showUpdatePane` instead.
    static var pendingPane: SettingsPane?

    private override init() {
        super.init()
    }

    @MainActor
    public func showSettings() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create SwiftUI settings view
        let settingsView = SettingsView()

        // Create hosting controller
        let hostingController = NSHostingController(rootView: settingsView)

        // Laid out like System Settings: a full-height sidebar under the traffic
        // lights and a unified toolbar that shows the selected pane's title.
        // SwiftUI supplies the materials; the window only has to allow them.
        hostingController.sceneBridgingOptions = [.toolbars]
        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // This controller owns the window (`window`, cleared in windowWillClose).
        // NSWindow's default of releasing itself on close would be a second,
        // unbalanced release of the same object under ARC.
        newWindow.isReleasedWhenClosed = false
        // An empty toolbar is what lets the sidebar run up under the traffic
        // lights; the selected pane's navigationTitle fills in the title.
        let toolbar = NSToolbar(identifier: "PriTypeSettings")
        // The default display mode reserves a label row, which makes the
        // toolbar 66pt tall instead of System Settings' 52pt.
        toolbar.displayMode = .iconOnly
        newWindow.toolbar = toolbar
        newWindow.toolbarStyle = .unified
        // Reopen where the user left it; the first time, at the designed size in
        // the middle of the screen. Sizing unconditionally would overwrite the
        // restored frame on every open. The view's minimum size (the designed
        // one) still clamps a frame saved by an older, smaller layout.
        newWindow.setFrameAutosaveName("PriTypeSettings")
        if !newWindow.setFrameUsingName("PriTypeSettings") {
            newWindow.setContentSize(NSSize(width: PriTypeConfig.settingsWindowWidth, height: PriTypeConfig.settingsWindowHeight))
            newWindow.center()
        }
        newWindow.delegate = self

        self.window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the settings window on the update pane and checks for an update.
    ///
    /// Reached from the update notification: the user asked about an update, so
    /// landing them on a pane that still says nothing would waste the trip.
    @MainActor
    public func showUpdateSettings() {
        Self.pendingPane = .update
        showSettings()
        // A window that was already open has its selection set from the outside,
        // and a new one has already consumed `pendingPane` by now.
        Self.pendingPane = nil
        NotificationCenter.default.post(name: .priTypeShowUpdatePane, object: nil)
    }
}

extension Notification.Name {
    /// Asks an open settings view to show the update pane and check for updates.
    static let priTypeShowUpdatePane = Notification.Name("com.pritype.showUpdatePane")
}

extension SettingsWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - SwiftUI Settings View

struct SettingsView: View {
    @State private var toggleKeyBinding = ConfigurationManager.shared.toggleKeyBinding
    @State private var hanjaKeyBinding = ConfigurationManager.shared.hanjaKeyBinding
    @State private var hanjaEnabled = ConfigurationManager.shared.hanjaEnabled
    @State private var toggleTrigger = ConfigurationManager.shared.toggleTrigger
    @State private var autoUpdateCheckEnabled = ConfigurationManager.shared.autoUpdateCheckEnabled
    @State private var isAccessibilityGranted = false
    @State private var inputMonitoringAccess = IOKitManager.InputMonitoringAccess.notDetermined
    @State private var hasKeyConflict = false
    @State private var showKeyConflictRestored = false
    @State private var conflictReset: DispatchWorkItem?
    @State private var isRestoringKeyBinding = false
    @State private var showCapsLockBlockedAlert = false
    @State private var capsLockSwitchEnabled = false

    // Update check state
    @State private var updateStatus: UpdateStatus = .idle
    @State private var updateStatusReset: DispatchWorkItem?
    /// The download-verify-authorize sequence, kept so it can be called off.
    @State private var installTask: Task<Void, Never>?

    // Polls for the accessibility grant while the window is open. Stored so it can
    // be replaced on repeated taps and invalidated when the view disappears.
    @State private var accessibilityPollTimer: Timer?

    // Disable-default-English (ABC) action state (restored 2.6.5 feature)
    @State private var removeABCStatus: RemoveABCStatus = .idle
    @State private var removeABCReset: DispatchWorkItem?
    @State private var removeABCTask: Task<Void, Never>?

    // Experimental Windows-style direct insertion (Phase 3). Default OFF.
    @State private var experimentalDirectInsertion = false

    // Apps that must keep the toggle/hanja keys for themselves (remote desktop, VMs).
    @State private var excludedApps: [ExcludedApp] = []

    /// Where the update pane is in the check → download → install sequence.
    private enum UpdateStatus: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateChecker.UpdateInfo)
        /// Fraction is `nil` until the server states a length.
        case downloading(UpdateChecker.UpdateInfo, fraction: Double?)
        case verifying(UpdateChecker.UpdateInfo)
        case authorizing(UpdateChecker.UpdateInfo)
        /// Handed to the installer; PriType is about to be killed and relaunched.
        case installing
        /// The check itself failed.
        case error
        /// The download, its verification, or the install did.
        case installError(String)

        /// Whether a spinner belongs next to the status.
        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .verifying, .authorizing, .installing: true
            case .idle, .upToDate, .available, .error, .installError: false
            }
        }

        /// Whether the work can still be called off. Once the installer has the
        /// package, it runs as its own root process and answers to no one here.
        var isCancellable: Bool {
            switch self {
            case .downloading, .verifying: true
            default: false
            }
        }
    }

    private enum RemoveABCStatus: Equatable {
        case idle
        /// Removal issued; waiting for TIS to agree. Blocks re-entry.
        case working
        case success
        case error
    }

    @State private var selection: SettingsPane? = SettingsWindowController.pendingPane ?? .switching

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                SettingsSidebarAppRow()
                    .selectionDisabled()

                ForEach(SettingsPane.groups, id: \.self) { group in
                    Section {
                        ForEach(group) { pane in
                            Label {
                                Text(pane.title)
                            } icon: {
                                SettingsPaneIcon(pane: pane, size: 20)
                            }
                            .help(pane.description)
                            .tag(pane)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: PriTypeConfig.settingsSidebarWidth)
            .navigationSplitViewColumnWidth(min: PriTypeConfig.settingsSidebarWidth, ideal: PriTypeConfig.settingsSidebarWidth, max: 280)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let pane = selection ?? .switching
            Form {
                paneContent(pane)
            }
            .formStyle(.grouped)
            // The grouped form leaves 20pt under the toolbar; System Settings
            // leaves 12pt, so pull the content up by the difference.
            .contentMargins(.top, -8, for: .scrollContent)
            .navigationTitle(pane.title)
            // NSHostingController does not bridge navigationTitle into the
            // window, so the toolbar would read "Untitled" without this.
            .background(WindowTitleSetter(title: pane.title))
        }
        .frame(minWidth: PriTypeConfig.settingsWindowWidth, minHeight: PriTypeConfig.settingsWindowHeight)
        .onAppear {
            toggleKeyBinding = ConfigurationManager.shared.toggleKeyBinding
            hanjaKeyBinding = ConfigurationManager.shared.hanjaKeyBinding
            hanjaEnabled = ConfigurationManager.shared.hanjaEnabled
            toggleTrigger = ConfigurationManager.shared.toggleTrigger
            autoUpdateCheckEnabled = ConfigurationManager.shared.autoUpdateCheckEnabled
            experimentalDirectInsertion = ConfigurationManager.shared.experimentalDirectInsertion
            reloadExcludedApps()
            refreshCapsLockSwitchState()
            checkAccessibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshCapsLockSwitchState()
            checkAccessibility()
        }
        // Sent when the update notification is clicked. The user asked about an
        // update, so the pane checks rather than waiting to be asked again.
        .onReceive(NotificationCenter.default.publisher(for: .priTypeShowUpdatePane)) { _ in
            selection = .update
            if !updateStatus.isBusy {
                checkForUpdates()
            }
        }
        .alert(L10n.keyBinding.capsLockBlockedTitle, isPresented: $showCapsLockBlockedAlert) {
            Button(L10n.keyBinding.capsLockOpenSettings) {
                openInputSourceSettings()
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(L10n.keyBinding.capsLockBlockedMessage)
        }
        // Attached at the root so a change is saved whichever pane made it.
        .onChange(of: toggleKeyBinding) { _, newValue in
            if isRestoringKeyBinding {
                isRestoringKeyBinding = false
                return
            }
            if newValue == hanjaKeyBinding {
                showRestoredConflict()
                isRestoringKeyBinding = true
                toggleKeyBinding = ConfigurationManager.shared.toggleKeyBinding
                return
            }
            ConfigurationManager.shared.toggleKeyBinding = newValue
            clearKeyConflict()
        }
        .onChange(of: toggleTrigger) { _, newValue in
            ConfigurationManager.shared.toggleTrigger = newValue
            RightCommandSuppressor.shared.restartForTriggerChange()
        }
        .onChange(of: hanjaEnabled) { _, isOn in
            ConfigurationManager.shared.hanjaEnabled = isOn
            if isOn {
                HanjaManager.shared.preload()
            } else {
                PriTypeInputController.sharedComposer.dismissHanjaCandidates(reason: "Hanja turned off")
                HanjaManager.shared.unload()
            }
        }
        .onChange(of: hanjaKeyBinding) { _, newValue in
            if isRestoringKeyBinding {
                isRestoringKeyBinding = false
                return
            }
            if newValue == toggleKeyBinding {
                showRestoredConflict()
                isRestoringKeyBinding = true
                hanjaKeyBinding = ConfigurationManager.shared.hanjaKeyBinding
                return
            }
            ConfigurationManager.shared.hanjaKeyBinding = newValue
            clearKeyConflict()
        }
        .onChange(of: autoUpdateCheckEnabled) { _, newValue in
            ConfigurationManager.shared.autoUpdateCheckEnabled = newValue
        }
        .onChange(of: experimentalDirectInsertion) { _, newValue in
            ConfigurationManager.shared.experimentalDirectInsertion = newValue
        }
        .onDisappear {
            removeABCTask?.cancel()
            removeABCTask = nil
            // Closing the window calls off a download, but never an install that
            // has already been authorized: by then the installer is a root
            // process of its own and nothing here can or should stop it.
            if updateStatus.isCancellable {
                installTask?.cancel()
            }
            installTask = nil
            for reset in [removeABCReset, updateStatusReset, conflictReset] { reset?.cancel() }
            removeABCReset = nil
            updateStatusReset = nil
            conflictReset = nil
            removeABCStatus = .idle
            accessibilityPollTimer?.invalidate()
            accessibilityPollTimer = nil
        }
    }

    @ViewBuilder
    private func paneContent(_ pane: SettingsPane) -> some View {
        switch pane {
        case .switching: switchingPane
        case .hanja: hanjaPane
        case .exclusions: exclusionsPane
        case .system: systemPane
        case .update: updatePane
        case .experimental: experimentalPane
        }
    }

    @ViewBuilder
    private var switchingPane: some View {
        Section {
            LabeledContent {
                StatusLabel(
                    title: capsLockSwitchEnabled ? L10n.keyBinding.capsLockStatusOn : L10n.keyBinding.capsLockStatusOff,
                    systemImage: capsLockSwitchEnabled ? "checkmark.circle.fill" : "minus.circle.fill",
                    color: capsLockSwitchEnabled ? .green : .secondary
                )
            } label: {
                SettingsRowLabel(
                    title: L10n.keyBinding.capsLockStatusTitle,
                    subtitle: capsLockSwitchEnabled
                        ? L10n.keyBinding.capsLockOnDescription : L10n.keyBinding.capsLockOffDescription
                )
            }

            HStack {
                Spacer()
                Button(L10n.keyBinding.capsLockOpenSettings, action: openInputSourceSettings)
            }
        }

        Section {
            KeyRecorderRow(
                label: L10n.keyBinding.toggleKey,
                binding: $toggleKeyBinding,
                isDisabled: capsLockSwitchEnabled,
                disabledReason: L10n.keyBinding.disabledByCapsLock,
                valueOverride: capsLockSwitchEnabled ? L10n.keyBinding.managedByMacOS : nil,
                onCapsLockBlocked: { showCapsLockBlockedAlert = true }
            )

            ToggleTriggerRow(
                trigger: $toggleTrigger,
                isDisabled: capsLockSwitchEnabled || !toggleKeyBinding.isModifierKey
                    || !toggleKeyBinding.isModifierOnly
            )
        } footer: {
            keyBindingNotes
        }
    }

    @ViewBuilder
    private var hanjaPane: some View {
        Section {
            Toggle(isOn: $hanjaEnabled) {
                SettingsRowLabel(
                    title: L10n.keyBinding.hanjaEnabled,
                    subtitle: L10n.keyBinding.hanjaEnabledDescription
                )
            }

            KeyRecorderRow(
                label: L10n.keyBinding.hanjaKey,
                binding: $hanjaKeyBinding,
                isDisabled: !hanjaEnabled,
                disabledReason: L10n.keyBinding.disabledByHanjaOff,
                valueOverride: nil,
                onCapsLockBlocked: { showCapsLockBlockedAlert = true }
            )
        } footer: {
            keyBindingNotes
        }
    }

    @ViewBuilder
    private var exclusionsPane: some View {
        Section {
            if excludedApps.isEmpty {
                Text(L10n.exclusions.empty)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(excludedApps) { app in
                    LabeledContent {
                        Button(L10n.exclusions.removeButton) { removeExcludedApp(app) }
                    } label: {
                        SettingsRowLabel(title: app.displayName, subtitle: app.bundleID)
                    }
                }
            }

            HStack {
                Spacer()
                Button(L10n.exclusions.addButton) { addExcludedApp() }
            }
        } footer: {
            SettingsFootnote(L10n.exclusions.subtitle)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var systemPane: some View {
        Section {
            LabeledContent {
                if isAccessibilityGranted {
                    StatusLabel(
                        title: L10n.system.accessibilityGranted,
                        systemImage: "checkmark.circle.fill",
                        color: .green
                    )
                } else {
                    Button(L10n.system.accessibilityRequest) { requestAccessibility() }
                }
            } label: {
                SettingsRowLabel(
                    title: L10n.system.accessibility,
                    subtitle: L10n.system.accessibilitySubtitle
                )
            }

            LabeledContent {
                if inputMonitoringAccess == .granted {
                    StatusLabel(
                        title: L10n.system.accessibilityGranted,
                        systemImage: "checkmark.circle.fill",
                        color: .green
                    )
                } else {
                    Button(inputMonitoringAccess == .denied
                           ? L10n.system.openSystemSettings : L10n.system.accessibilityRequest) {
                        requestInputMonitoring()
                    }
                }
            } label: {
                SettingsRowLabel(
                    title: L10n.system.inputMonitoring,
                    subtitle: L10n.system.inputMonitoringSubtitle
                )
            }
        }

        // Disable default English (ABC) input source — restored 2.6.5 feature.
        Section {
            LabeledContent {
                switch removeABCStatus {
                case .working:
                    ProgressView()
                        .controlSize(.small)
                case .success:
                    StatusLabel(
                        title: L10n.system.removeABCSuccess,
                        systemImage: "checkmark.circle.fill",
                        color: .green
                    )
                case .error:
                    StatusLabel(
                        title: L10n.system.removeABCFailed,
                        systemImage: "exclamationmark.triangle.fill",
                        color: .orange
                    )
                case .idle:
                    Button(L10n.system.removeABCButton) { removeABCKeyboard() }
                        // Overlapping attempts would spawn competing killalls
                        // and competing status resets.
                        .disabled(removeABCStatus == .working)
                }
            } label: {
                SettingsRowLabel(
                    title: L10n.system.removeABC,
                    subtitle: L10n.system.removeABCSubtitle
                )
            }
        }
    }

    @ViewBuilder
    private var updatePane: some View {
        Section {
            Toggle(L10n.update.autoCheck, isOn: $autoUpdateCheckEnabled)

            LabeledContent(L10n.about.version) {
                Text("v\(AboutInfo.displayVersion)")
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    updateStatusView
                    Spacer()
                    if updateStatus.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    updateActions
                }

                // Only once the server has stated a length; a bar that cannot
                // move says less than the spinner already does.
                if case .downloading(_, let fraction) = updateStatus, let fraction {
                    ProgressView(value: fraction)
                        .transition(.opacity)
                }
            }
        }
    }

    /// The buttons beside the update status, which depend on where it is.
    @ViewBuilder
    private var updateActions: some View {
        switch updateStatus {
        case .available(let info):
            if info.assets == nil {
                // A release published before signed manifests, or one built
                // without the signing secret: nothing here can verify it, so
                // the user installs it themselves.
                Button(L10n.update.openReleasePage) { openReleasePage(info) }
            } else {
                Button(L10n.update.installButton) { install(info) }
                    .buttonStyle(.borderedProminent)
            }
        case .downloading, .verifying:
            Button(L10n.update.cancel) { cancelInstall() }
        case .authorizing, .installing:
            EmptyView()
        case .installError:
            Button(L10n.update.openReleasePage) { openLatestRelease() }
        case .idle, .checking, .upToDate, .error:
            Button(L10n.update.checkButton) { checkForUpdates() }
                .disabled(updateStatus == .checking)
        }
    }

    @ViewBuilder
    private var experimentalPane: some View {
        Section {
            Toggle(isOn: $experimentalDirectInsertion) {
                SettingsRowLabel(
                    title: L10n.experimental.directInsertion,
                    subtitle: L10n.experimental.directInsertionDescription
                )
            }
        } footer: {
            SettingsFootnote(L10n.pane.experimentalDescription)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Conflict and shadowed-shortcut notes shown under the key rows.
    @ViewBuilder
    private var keyBindingNotes: some View {
        let warnings = systemShortcutWarnings
        if hasKeyConflict || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if hasKeyConflict {
                    Label(
                        showKeyConflictRestored ? L10n.keyBinding.conflictRestored : L10n.keyBinding.conflict,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .transition(.opacity)
                }

                // A binding that shadows a macOS shortcut is allowed, but the
                // user should know why that shortcut stopped responding.
                ForEach(warnings, id: \.self) { warning in
                    Label {
                        Text(warning)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .font(.subheadline)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Update Status View

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateStatus {
        case .idle:
            EmptyView()
        case .checking:
            Text(L10n.update.checking)
                .foregroundStyle(.secondary)
        case .upToDate:
            StatusLabel(title: L10n.update.upToDate, systemImage: "checkmark.circle.fill", color: .green)
                .transition(.opacity)
        case .available(let info):
            // Still a link to the notes, even when the button beside it can do
            // the install: what changed is worth reading first.
            Button(action: { openReleasePage(info) }) {
                Label(String(format: L10n.update.available, info.version), systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.link)
            .transition(.opacity)
        case .downloading:
            Text(L10n.update.downloading)
                .foregroundStyle(.secondary)
        case .verifying:
            Text(L10n.update.verifying)
                .foregroundStyle(.secondary)
        case .authorizing:
            Text(L10n.update.authorizing)
                .foregroundStyle(.secondary)
        case .installing:
            Text(L10n.update.installing)
                .foregroundStyle(.secondary)
        case .error:
            StatusLabel(title: L10n.update.error, systemImage: "exclamationmark.triangle.fill", color: .orange)
                .transition(.opacity)
        case .installError(let message):
            StatusLabel(title: message, systemImage: "exclamationmark.triangle.fill", color: .orange)
                .transition(.opacity)
        }
    }

    // MARK: - Actions

    private func checkForUpdates() {
        // A result shown by the previous check must not be cleared mid-request.
        updateStatusReset?.cancel()
        withAnimation { updateStatus = .checking }

        Task {
            let result = await UpdateChecker.shared.checkForUpdates()
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    switch result {
                    case .updateAvailable(let info):
                        updateStatus = .available(info)
                    case .upToDate:
                        updateStatus = .upToDate
                    case .skipped:
                        updateStatus = .upToDate
                    case .error:
                        updateStatus = .error
                    }
                }

                // Auto-dismiss success/error after 8 seconds
                if updateStatus == .upToDate || updateStatus == .error {
                    replaceReset($updateStatusReset, after: 8) {
                        withAnimation { updateStatus = .idle }
                    }
                }
            }
        }
    }

    /// Downloads, verifies and installs `info`.
    ///
    /// The last step hands the package to a root installer that terminates
    /// PriType, so this view is not around for the end of it: what happened is
    /// reported on the next launch instead.
    private func install(_ info: UpdateChecker.UpdateInfo) {
        updateStatusReset?.cancel()
        installTask?.cancel()
        withAnimation { updateStatus = .downloading(info, fraction: nil) }

        installTask = Task {
            do {
                try await UpdateInstaller.shared.install(info) { phase in
                    Task { @MainActor in
                        // A cancelled run can still deliver one last phase; it
                        // must not overwrite the state cancelling restored.
                        guard !Task.isCancelled else { return }
                        applyInstallPhase(phase, for: info)
                    }
                }
            } catch {
                await MainActor.run { finishInstall(with: error, for: info) }
            }
        }
    }

    @MainActor
    private func applyInstallPhase(_ phase: UpdateInstaller.Phase, for info: UpdateChecker.UpdateInfo) {
        withAnimation(.easeInOut(duration: 0.2)) {
            switch phase {
            case .downloading(let fraction):
                updateStatus = .downloading(info, fraction: fraction)
            case .verifying:
                updateStatus = .verifying(info)
            case .awaitingAuthorization:
                updateStatus = .authorizing(info)
            case .installing:
                updateStatus = .installing
            }
        }
    }

    @MainActor
    private func finishInstall(with error: any Error, for info: UpdateChecker.UpdateInfo) {
        installTask = nil

        // Cancelling and dismissing the authorization dialog are both decisions,
        // not failures: the update is still there to install.
        if error is CancellationError {
            withAnimation { updateStatus = .available(info) }
            return
        }

        let message: String
        switch error as? UpdateInstaller.Failure {
        case .authorizationCancelled:
            withAnimation { updateStatus = .available(info) }
            return
        case .download, .implausibleSize:
            message = L10n.update.downloadFailed
        case .verification:
            message = L10n.update.verificationFailed
        case .noInstallableAssets, .authorizationFailed, .none:
            message = L10n.update.installFailed
        }

        DebugLogger.log("SettingsView: Install failed - \(error)")
        withAnimation { updateStatus = .installError(message) }
    }

    private func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        if case .downloading(let info, _) = updateStatus {
            withAnimation { updateStatus = .available(info) }
        } else if case .verifying(let info) = updateStatus {
            withAnimation { updateStatus = .available(info) }
        }
    }

    private func openReleasePage(_ info: UpdateChecker.UpdateInfo) {
        NSWorkspace.shared.open(info.releasePageURL)
    }

    private func openLatestRelease() {
        NSWorkspace.shared.open(AboutInfo.latestReleaseURL)
    }

    private func openInputSourceSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?InputSources") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func refreshCapsLockSwitchState() {
        capsLockSwitchEnabled = ConfigurationManager.shared.capsLockInputSourceSwitchEnabled
    }

    private func showRestoredConflict() {
        withAnimation(.easeInOut(duration: 0.2)) {
            hasKeyConflict = true
            showKeyConflictRestored = true
        }

        replaceReset($conflictReset, after: 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                hasKeyConflict = false
                showKeyConflictRestored = false
            }
        }
    }

    /// Run `reset` after `seconds` unless a newer reset takes the slot first, so
    /// an older timer can never clear the status that replaced it.
    private func replaceReset(_ slot: Binding<DispatchWorkItem?>, after seconds: Double, _ reset: @escaping () -> Void) {
        slot.wrappedValue?.cancel()
        let item = DispatchWorkItem(block: reset)
        slot.wrappedValue = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Warnings for bindings that shadow a well-known macOS shortcut.
    ///
    /// Deduplicated so binding both keys to the same shortcut family does not
    /// print the same sentence twice.
    private var systemShortcutWarnings: [String] {
        // Only warn about bindings PriType actually intercepts. When Caps Lock owns
        // switching, the toggle key is not consumed at all (the row is disabled and
        // reads "managed by macOS"), so warning about it would tell the user to
        // reassign a system shortcut for no reason.
        var active = capsLockSwitchEnabled ? [] : [toggleKeyBinding]
        if hanjaEnabled { active.append(hanjaKeyBinding) }
        var seen = Set<String>()
        return active
            .compactMap { $0.systemShortcutConflict }
            .compactMap { conflict in
                guard seen.insert(conflict.nameKey).inserted else { return nil }
                return L10n.shortcut.conflictWarning(L10n.shortcut.name(conflict.nameKey))
            }
    }

    private func clearKeyConflict() {
        guard hasKeyConflict || showKeyConflictRestored else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            hasKeyConflict = false
            showKeyConflictRestored = false
        }
    }

    // MARK: - System Settings Logic

    private func checkAccessibility() {
        isAccessibilityGranted = AXIsProcessTrusted()
        inputMonitoringAccess = IOKitManager.inputMonitoringAccess()
    }

    /// Prompt once; after a denial only System Settings can change it.
    private func requestInputMonitoring() {
        if inputMonitoringAccess == .notDetermined {
            IOKitManager.requestInputMonitoringPermission()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        inputMonitoringAccess = IOKitManager.inputMonitoringAccess()
    }

    /// Disable the default English (ABC) keyboard input source so PriType alone
    /// handles 한/영. Restored from v2.6.5 (removed in the 2.7 line). Reversible:
    /// the user can re-add ABC in System Settings (needed for the login screen).
    ///
    /// The previous version reported success unconditionally — even when the
    /// preference write never landed — which is indistinguishable from the
    /// reported "ABC comes back on its own" symptom. The write is now checked in
    /// preferences and then confirmed against live TIS state before the UI claims
    /// success. That confirmation runs in a fresh process: this process's own TIS
    /// view never sees the write, and checking it here reported a failure after
    /// every successful removal (see `ABCLayoutStatusProbe`).
    ///
    /// Success does not mean every running process sees the change: each one
    /// keeps its own TIS view until it restarts, and only TextInputMenuAgent is
    /// relaunched here. No other input method or community guide gets live
    /// propagation from a preference write either, so the UI tells the user to
    /// log out instead of promising an immediate effect.
    private func removeABCKeyboard() {
        guard removeABCStatus != .working else { return }
        removeABCReset?.cancel()
        removeABCReset = nil
        withAnimation { removeABCStatus = .working }

        let manager = InputSourceManager.shared
        let result = manager.disableABCKeyboardLayout()
        removeABCTask = Task { @MainActor in
            do {
                let confirmed = try await ABCRemovalVerification.confirm(
                    result: result,
                    // The probe blocks its thread for the child's lifetime: not
                    // main (the window must keep responding), and not the Swift
                    // concurrency pool, whose few threads must never block.
                    isDisabled: {
                        await withCheckedContinuation { continuation in
                            DispatchQueue.global(qos: .userInitiated).async {
                                continuation.resume(returning: ABCLayoutStatusProbe.isABCDisabledInFreshProcess())
                            }
                        }
                    }
                )
                try Task.checkCancellation()
                if !confirmed {
                    DebugLogger.log("SettingsView: ABC removal not confirmed, preferences=\(result)")
                }
                finishRemoveABC(confirmed ? .success : .error)
            } catch is CancellationError {
                // Closing settings cancels the old attempt; it must not update
                // a reopened view or finish a newer attempt.
            } catch {
                finishRemoveABC(.error)
            }
        }
    }

    private func finishRemoveABC(_ status: RemoveABCStatus) {
        withAnimation { removeABCStatus = status }
        replaceReset($removeABCReset, after: 3) {
            withAnimation { removeABCStatus = .idle }
        }
    }

    // MARK: - Toggle Exclusion Logic

    private func reloadExcludedApps() {
        excludedApps = ConfigurationManager.shared.toggleExcludedBundleIDs.map(ExcludedApp.init(bundleID:))
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.exclusions.addButton

        guard panel.runModal() == .OK else { return }

        // Resolve each pick to a bundle ID; a chosen file without one cannot be
        // matched against the frontmost app, so it is skipped rather than stored.
        var updated = ConfigurationManager.shared.toggleExcludedBundleIDs
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            updated = ToggleExclusionPolicy.adding(bundleID, to: updated)
        }
        ConfigurationManager.shared.toggleExcludedBundleIDs = updated
        reloadExcludedApps()
    }

    private func removeExcludedApp(_ app: ExcludedApp) {
        ConfigurationManager.shared.toggleExcludedBundleIDs = ToggleExclusionPolicy.removing(
            app.bundleID,
            from: ConfigurationManager.shared.toggleExcludedBundleIDs
        )
        reloadExcludedApps()
    }

    private func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let _ = AXIsProcessTrustedWithOptions(options)

        // Poll for the grant while the window is open. Replace any in-flight poll
        // so repeated taps don't stack timers, and stop after a bounded window so
        // a never-granted permission can't leave a timer running forever.
        accessibilityPollTimer?.invalidate()
        let pollDeadline = Date().addingTimeInterval(120)
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            let granted = AXIsProcessTrusted()
            if granted || Date() >= pollDeadline {
                timer.invalidate()
            }
            guard granted else { return }
            DispatchQueue.main.async {
                self.isAccessibilityGranted = true

                // Start key monitoring that was waiting for this grant.
                if !RightCommandSuppressor.shared.isRunning {
                    KeyMonitors.start()
                }
            }
        }
    }
}

// MARK: - Settings Components

/// One page of the settings window, listed in the sidebar.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case switching
    case hanja
    case exclusions
    case system
    case update
    case experimental

    var id: String { rawValue }

    /// Sidebar groups: how typing behaves, then the app itself.
    static let groups: [[SettingsPane]] = [
        [.switching, .hanja, .exclusions],
        [.system, .update, .experimental],
    ]

    var title: String {
        switch self {
        case .switching: L10n.pane.switchingTitle
        case .hanja: L10n.pane.hanjaTitle
        case .exclusions: L10n.pane.exclusionsTitle
        case .system: L10n.pane.systemTitle
        case .update: L10n.update.title
        case .experimental: L10n.pane.experimentalTitle
        }
    }

    var description: String {
        switch self {
        case .switching: L10n.pane.switchingDescription
        case .hanja: L10n.pane.hanjaDescription
        case .exclusions: L10n.exclusions.subtitle
        case .system: L10n.pane.systemDescription
        case .update: L10n.pane.updateDescription
        case .experimental: L10n.pane.experimentalDescription
        }
    }

    var systemImage: String {
        switch self {
        case .switching: "globe"
        case .hanja: "character.book.closed.fill"
        case .exclusions: "nosign"
        case .system: "hand.raised.fill"
        case .update: "arrow.triangle.2.circlepath"
        case .experimental: "flask.fill"
        }
    }

    var tint: Color {
        switch self {
        case .switching: .blue
        case .hanja: .orange
        case .exclusions: .red
        case .system: .blue
        case .update: .gray
        case .experimental: .purple
        }
    }
}

/// The colored rounded-square icon System Settings puts beside each pane.
struct SettingsPaneIcon: View {
    let pane: SettingsPane
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        shape
            .fill(pane.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: pane.systemImage)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            // A light rim and a soft shadow keep a blue tile distinct from the
            // blue selection behind it, as System Settings' icons are.
            .overlay {
                shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.2), radius: 0.75, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// App icon, name and version at the top of the sidebar, in the spot System
/// Settings gives the Apple Account.
struct SettingsSidebarAppRow: View {
    var body: some View {
        HStack(spacing: 10) {
            // The icon is compiled into Assets.car under the bundle's icon name,
            // so ask the app rather than NSImage(named:).
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("PriType")
                    .font(.body.weight(.semibold))
                Text("v\(AboutInfo.displayVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Sets the hosting window's title, which the unified toolbar shows.
struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let title = title
        // The view has no window until it is inserted into the hierarchy.
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}

/// A row title with an optional secondary description, as in System Settings.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle {
                SettingsFootnote(subtitle)
            }
        }
        // Keep wrapped descriptions clear of the control on the right.
        .padding(.trailing, 16)
    }
}

struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A read-only state shown where a control would otherwise sit.
struct StatusLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
        }
        .fixedSize()
    }
}

/// Picks when a lone-modifier toggle key switches (`ToggleTrigger`).
struct ToggleTriggerRow: View {
    @Binding var trigger: ToggleTrigger
    /// Caps Lock switching owns the toggle, or the toggle key is not a lone modifier.
    let isDisabled: Bool

    var body: some View {
        Picker(selection: $trigger) {
            Text(L10n.keyBinding.toggleTriggerPress).tag(ToggleTrigger.press)
            Text(L10n.keyBinding.toggleTriggerTap).tag(ToggleTrigger.tapAlone)
        } label: {
            SettingsRowLabel(
                title: L10n.keyBinding.toggleTrigger,
                subtitle: isDisabled ? L10n.keyBinding.toggleTriggerOnlyModifiers
                    : trigger == .press ? L10n.keyBinding.toggleTriggerPressDescription
                    : L10n.keyBinding.toggleTriggerTapDescription
            )
        }
        .pickerStyle(.menu)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(isDisabled)
    }
}

/// A key recorder row — press to record a new key binding
///
/// Shows the current key binding and enters recording mode on click.
/// In recording mode, the next key press is captured and saved.
struct KeyRecorderRow: View {
    let label: String
    @Binding var binding: KeyBinding
    let isDisabled: Bool
    let disabledReason: String?
    let valueOverride: String?
    let onCapsLockBlocked: () -> Void

    @State private var isRecording = false
    @State private var recordingOwner = UUID()
    @State private var monitor: Any?
    @State private var pulseAnimation = false

    var body: some View {
        LabeledContent {
            Button(action: {
                guard !isDisabled else { return }
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }) {
                HStack(spacing: 6) {
                    if isRecording {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .scaleEffect(pulseAnimation ? 1.3 : 0.8)
                            .opacity(pulseAnimation ? 0.6 : 1.0)
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseAnimation)

                        Text(L10n.keyBinding.recording)
                    } else {
                        Text(valueOverride ?? binding.displayName)
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 96)
            }
            .tint(isRecording ? Color.accentColor : nil)
            .buttonStyle(.bordered)
        } label: {
            SettingsRowLabel(title: label, subtitle: isDisabled ? disabledReason : nil)
        }
        .disabled(isDisabled)
        .onChange(of: isDisabled) { _, disabled in
            if disabled {
                stopRecording()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
        .onDisappear {
            stopRecording()
        }
    }

    @State private var recordingState = KeyRecordingState()

    private func startRecording() {
        let owner = UUID()
        KeyRecordingSessions.shared.begin(owner: owner) { stopRecording() }
        recordingOwner = owner
        isRecording = true
        pulseAnimation = true
        recordingState = KeyRecordingState()

        let suppressor = RightCommandSuppressor.shared
        suppressor.onKeyRecorded = { keyCode, modifiers in
            guard KeyRecordingSessions.shared.owns(owner) else { return }
            receiveBinding(keyCode: keyCode, modifiers: modifiers)
        }
        suppressor.isRecordingKey = true

        // Both producers use the same modifier-release/shortcut state machine.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard KeyRecordingSessions.shared.owns(owner) else { return event }
            if let recorded = recordingState.consume(keyCode: Int64(event.keyCode),
                flags: UInt64(event.modifierFlags.rawValue), isModifierChange: event.type == .flagsChanged) {
                receiveBinding(keyCode: recorded.keyCode, modifiers: recorded.modifiers)
            }
            return nil
        }
    }

    private func receiveBinding(keyCode: Int64, modifiers: UInt64) {
        guard isRecording else { return }
        if keyCode == 53 { stopRecording(); return }
        if keyCode == 57 { stopRecording(); onCapsLockBlocked(); return }
        // Narrow to the four bare masks. `KeyBinding.SystemShortcut.matches` compares
        // modifiers with `==`, so widening this would leave device-specific bits
        // (NX_DEVICEL/RCMDKEYMASK…), maskNonCoalesced or Caps Lock in the stored
        // value and silently stop every shortcut-conflict warning from matching.
        let relevant = modifiers & (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue)
        let candidate = KeyBinding(keyCode: keyCode, modifiers: relevant,
            displayName: KeyBinding.generateDisplayName(keyCode: keyCode, modifiers: relevant))
        guard candidate.isSafeGlobalBinding else { NSSound.beep(); return }
        binding = candidate
        stopRecording()
    }

    private func stopRecording() {
        if KeyRecordingSessions.shared.end(owner: recordingOwner) {
            RightCommandSuppressor.shared.isRecordingKey = false
            RightCommandSuppressor.shared.onKeyRecorded = nil
        }
        isRecording = false
        pulseAnimation = false
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

// MARK: - Excluded App Row Model

/// One entry of the toggle-key exclusion list.
///
/// The bundle ID is what the policy matches on; the display name is resolved for
/// the UI only, and falls back to the bundle ID when the app is not installed —
/// an entry for an uninstalled app must stay visible so the user can remove it.
struct ExcludedApp: Identifiable, Equatable {
    let bundleID: String
    let displayName: String

    var id: String { bundleID }

    init(bundleID: String) {
        self.bundleID = bundleID
        self.displayName = Self.resolveDisplayName(for: bundleID) ?? bundleID
    }

    private static func resolveDisplayName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
