import Foundation

/// Checks for updates by querying the GitHub Releases API
///
/// `UpdateChecker` is the core engine that fetches the latest release info
/// from GitHub and compares it against the currently running version.
///
/// ## Usage
/// ```swift
/// if let update = await UpdateChecker.shared.checkForUpdates() {
///     print("New version available: \(update.version)")
/// }
/// ```
///
/// ## Throttling
/// `checkForUpdatesIfNeeded()` automatically skips the check if it was
/// performed less than 24 hours ago, preventing unnecessary API calls.
///
/// ## Thread Safety
/// All methods are `async` and safe to call from any context.
public final class UpdateChecker: @unchecked Sendable {
    
    // MARK: - Singleton
    
    public static let shared = UpdateChecker()
    
    // MARK: - Types
    
    /// Information about an available update
    public struct UpdateInfo: Sendable {
        /// The new version string (e.g. "2.1")
        public let version: String
        /// URL to the GitHub Releases page
        public let releasePageURL: URL
        /// Release notes / changelog body
        public let releaseNotes: String?
        /// Direct download URL for the PKG asset (if available)
        public let downloadURL: URL?
    }
    
    /// Result of an update check
    public enum CheckResult: Sendable {
        /// A newer version is available
        case updateAvailable(UpdateInfo)
        /// Already running the latest version
        case upToDate
        /// Check was skipped (throttled)
        case skipped
        /// An error occurred during the check
        case error(String)
    }
    
    // MARK: - GitHub API Response Models
    
    struct GitHubRelease: Codable, Sendable {
        let tagName: String
        let htmlUrl: String
        let name: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [GitHubAsset]
        
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case name
            case body
            case draft
            case prerelease
            case assets
        }
    }
    
    struct GitHubAsset: Codable, Sendable {
        let name: String
        let browserDownloadUrl: String
        
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }
    
    // MARK: - Constants
    
    private let apiURL = "https://api.github.com/repos/Meapri/PriType-Swift/releases?per_page=100"
    
    /// Minimum interval between automatic checks (24 hours)
    private let checkInterval: TimeInterval = 24 * 60 * 60
    
    // MARK: - Private Properties
    
    private let session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Public Methods
    
    /// Check for updates, respecting the throttle interval
    ///
    /// This method skips the API call if the last successful check was
    /// less than 24 hours ago. Use `checkForUpdates()` to force a check.
    ///
    /// - Returns: The result of the update check
    public func checkForUpdatesIfNeeded() async -> CheckResult {
        // Check if enough time has passed since last SUCCESSFUL check.
        // lastUpdateCheck is only set on success, so failed checks will always be retried
        // on the next app launch (no throttle applied to failures).
        if let lastCheck = ConfigurationManager.shared.lastUpdateCheck {
            let elapsed = Date().timeIntervalSince(lastCheck)
            if elapsed < checkInterval {
                DebugLogger.log("UpdateChecker: Skipping (last check \(Int(elapsed))s ago)")
                return .skipped
            }
        }
        
        return await checkForUpdates()
    }
    
    /// Force an immediate update check against GitHub Releases
    ///
    /// - Returns: The result of the update check
    public func checkForUpdates() async -> CheckResult {
        DebugLogger.log("UpdateChecker: Checking for updates...")
        
        guard let url = URL(string: apiURL) else {
            return .error("Invalid API URL")
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PriType/\(AboutInfo.version)", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("Invalid response")
            }
            
            guard httpResponse.statusCode == 200 else {
                DebugLogger.log("UpdateChecker: HTTP \(httpResponse.statusCode)")
                return .error("HTTP \(httpResponse.statusCode)")
            }
            
            let decoder = JSONDecoder()
            let releases = try decoder.decode([GitHubRelease].self, from: data)
            guard let release = Self.latestStableRelease(in: releases) else {
                DebugLogger.log("UpdateChecker: No stable release found")
                ConfigurationManager.shared.lastUpdateCheck = Date()
                return .upToDate
            }
            
            // Compare versions
            let latestVersion = Self.normalizeVersion(release.tagName)
            let currentVersion = Self.normalizeVersion(AboutInfo.version)
            
            DebugLogger.log("UpdateChecker: channel=stable current=\(currentVersion) latest=\(latestVersion)")
            
            // Record successful check time
            ConfigurationManager.shared.lastUpdateCheck = Date()
            
            if Self.isNewer(latestVersion, than: currentVersion) {
                // Find PKG asset download URL
                let pkgAsset = release.assets.first { $0.name.hasSuffix(".pkg") }
                
                let updateInfo = UpdateInfo(
                    version: latestVersion,
                    releasePageURL: URL(string: release.htmlUrl) ?? url,
                    releaseNotes: release.body,
                    downloadURL: pkgAsset.flatMap { URL(string: $0.browserDownloadUrl) }
                )
                
                DebugLogger.log("UpdateChecker: Update available! \(latestVersion)")
                return .updateAvailable(updateInfo)
            } else {
                DebugLogger.log("UpdateChecker: Up to date")
                return .upToDate
            }
        } catch {
            DebugLogger.log("UpdateChecker: Error - \(error.localizedDescription)")
            return .error(error.localizedDescription)
        }
    }
    
    // MARK: - Version Comparison
    
    /// Normalize a version string by stripping leading "v" or "V"
    static func normalizeVersion(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") {
            v = String(v.dropFirst())
        }
        // Trim again: dropping the prefix can expose leading whitespace ("v 2.5"),
        // and callers normalize before `isNewer` normalizes a second time. Trimming
        // here makes the function idempotent, so the double pass cannot disagree.
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prereleaseStart = v.firstIndex(of: "-") {
            v = String(v[..<prereleaseStart])
        }
        if let metadataStart = v.firstIndex(of: "+") {
            v = String(v[..<metadataStart])
        }
        return v
    }
    
    /// Selects the highest stable release by numeric version, ignoring beta/pre-release tags.
    ///
    /// Versions that differ only in trailing zero components ("2.7" and "2.7.0")
    /// compare as equal, so a tie is possible. `max(by:)` keeps the FIRST element
    /// of an equal-max run and the GitHub releases endpoint returns newest-first,
    /// so the most recently published of the tie wins. That is the intent — it is
    /// pinned by a test rather than left to depend on the caller's ordering.
    static func latestStableRelease(in releases: [GitHubRelease]) -> GitHubRelease? {
        releases
            .filter { release in
                !release.draft &&
                ReleaseChannel.detect(
                    tagName: release.tagName,
                    name: release.name,
                    prerelease: release.prerelease
                ) == .stable
            }
            .max { lhs, rhs in
                isNewer(normalizeVersion(rhs.tagName), than: normalizeVersion(lhs.tagName))
            }
    }

    /// Check if `latest` is strictly newer than `current`.
    ///
    /// Compares dotted versions component by component, treating missing trailing
    /// components as zero. A plain `.numeric` string compare cannot do this: it
    /// ranks "2.1.0" above "2.1" because the shorter string is a prefix, which made
    /// a `2.1.0` tag advertise an update to a machine already running `2.1`.
    /// Component-wise comparison also makes "2.01" == "2.1" and "2.10" > "2.9".
    ///
    /// - Important: This treats "2.7" and "2.7.0" as the SAME version. If the
    ///   project ever publishes both as distinct releases, a machine running "2.7"
    ///   would never be offered "2.7.0". The release workflow pins
    ///   `CFBundleShortVersionString` to the tag string exactly, so the only way to
    ///   reach that state is to tag both forms — which would be two tags for one
    ///   semantic version. Keep tags to a single canonical form.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let lhs = versionComponents(latest)
        let rhs = versionComponents(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Split a normalized version into numeric components.
    ///
    /// Each segment contributes its leading ASCII digits; a segment with none
    /// contributes 0. Degradation is per SEGMENT, not per version — "2.5.x" still
    /// ranks above "2.4.9", because only the malformed segment is affected.
    ///
    /// `Character.isNumber` would accept non-ASCII numerics that `Int` then
    /// rejects, collapsing an otherwise-valid segment to 0, so the scan is
    /// restricted to ASCII. A segment too large for `Int` saturates to `Int.max`
    /// rather than wrapping to 0, which would invert the ordering.
    static func versionComponents(_ version: String) -> [Int] {
        normalizeVersion(version)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { segment in
                let digits = segment.prefix { $0.isASCII && $0.isNumber }
                if digits.isEmpty { return 0 }
                return Int(digits) ?? Int.max
            }
    }
}
