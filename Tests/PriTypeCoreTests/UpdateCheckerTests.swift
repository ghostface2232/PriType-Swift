import Testing
import Foundation
@testable import PriTypeCore

// MARK: - UpdateChecker Tests

@Suite("UpdateChecker")
struct UpdateCheckerTests {
    
    @Test("Version comparison: newer version detected")
    func newerVersionDetected() {
        #expect(UpdateChecker.isNewer("2.5.0", than: "2.4.2"))
        #expect(UpdateChecker.isNewer("3.0.0", than: "2.9.9"))
        #expect(UpdateChecker.isNewer("2.4.3", than: "2.4.2"))
    }
    
    @Test("Version comparison: same version not newer")
    func sameVersionNotNewer() {
        #expect(!UpdateChecker.isNewer("2.4.2", than: "2.4.2"))
    }
    
    @Test("Version comparison: older version not newer")
    func olderVersionNotNewer() {
        #expect(!UpdateChecker.isNewer("2.4.1", than: "2.4.2"))
        #expect(!UpdateChecker.isNewer("1.0.0", than: "2.4.2"))
    }
    
    @Test("Version comparison: major version bump")
    func majorVersionBump() {
        #expect(UpdateChecker.isNewer("3.0.0", than: "2.99.99"))
    }
    
    @Test("Version comparison: minor version bump")
    func minorVersionBump() {
        #expect(UpdateChecker.isNewer("2.5.0", than: "2.4.99"))
    }
    
    @Test("Version comparison: patch-only bump")
    func patchOnlyBump() {
        #expect(UpdateChecker.isNewer("2.4.3", than: "2.4.2"))
        #expect(!UpdateChecker.isNewer("2.4.2", than: "2.4.3"))
    }
    
    @Test("Version comparison: handles two-part versions")
    func twoPartVersions() {
        #expect(UpdateChecker.isNewer("2.5", than: "2.4"))
        #expect(!UpdateChecker.isNewer("2.4", than: "2.5"))
    }

    @Test("Version comparison: differing component counts compare as equal-padded")
    func componentCountBoundaries() {
        // A "2.1.0" tag must NOT advertise an update to a machine running "2.1";
        // trailing components are zero-padded rather than making the longer
        // string win by prefix ordering.
        #expect(!UpdateChecker.isNewer("2.1.0", than: "2.1"))
        #expect(!UpdateChecker.isNewer("2.1", than: "2.1.0"))
        #expect(!UpdateChecker.isNewer("2.1.0.0", than: "2.1"))
        #expect(!UpdateChecker.isNewer("2", than: "2.0.0"))
        // A real trailing bump is still newer in both directions.
        #expect(UpdateChecker.isNewer("2.1.1", than: "2.1"))
        #expect(!UpdateChecker.isNewer("2.1", than: "2.1.1"))
    }

    @Test("Version comparison: numeric segments beat lexicographic order")
    func numericSegmentOrdering() {
        #expect(UpdateChecker.isNewer("2.10", than: "2.9"))
        #expect(!UpdateChecker.isNewer("2.9", than: "2.10"))
        #expect(UpdateChecker.isNewer("10.0", than: "9.9"))
        // Zero-padded segments are numerically equal, not distinct versions.
        #expect(!UpdateChecker.isNewer("2.01", than: "2.1"))
        #expect(!UpdateChecker.isNewer("2.1", than: "2.01"))
    }

    @Test("Version comparison: malformed tags never outrank a running version")
    func malformedTagsAreNotNewer() {
        #expect(!UpdateChecker.isNewer("", than: "2.4.2"))
        #expect(!UpdateChecker.isNewer("abc", than: "2.4.2"))
        #expect(!UpdateChecker.isNewer("..", than: "2.4.2"))
        #expect(!UpdateChecker.isNewer("2.4.2-beta.9", than: "2.4.2"))
        #expect(!UpdateChecker.isNewer("v2.4.2+build7", than: "2.4.2"))
        // A malformed segment degrades to 0 instead of discarding the comparison.
        #expect(UpdateChecker.isNewer("2.5.x", than: "2.4.9"))
    }

    @Test("Version components parse normalized numeric segments")
    func versionComponentsParsing() {
        #expect(UpdateChecker.versionComponents("v2.4.2-beta.1") == [2, 4, 2])
        #expect(UpdateChecker.versionComponents("2.10") == [2, 10])
        #expect(UpdateChecker.versionComponents("2.4.2+meta") == [2, 4, 2])
        #expect(UpdateChecker.versionComponents("abc") == [0])
    }

    @Test("Version normalization removes tag prefix and prerelease suffix")
    func versionNormalization() {
        #expect(UpdateChecker.normalizeVersion("v3.0.0-beta.1") == "3.0.0")
        #expect(UpdateChecker.normalizeVersion("V2.7.0+42") == "2.7.0")
        #expect(UpdateChecker.normalizeVersion(" 2.6.4 ") == "2.6.4")
    }

    @Test("Release channel detects stable and beta releases")
    func releaseChannelDetection() {
        #expect(ReleaseChannel.detect(tagName: "v3.0.0", name: "PriType 3.0", prerelease: false) == .stable)
        #expect(ReleaseChannel.detect(tagName: "v3.0.0-beta.1", name: "PriType 3.0 Beta", prerelease: false) == .beta)
        #expect(ReleaseChannel.detect(tagName: "v3.0.0", name: "PriType 3.0", prerelease: true) == .beta)
        #expect(ReleaseChannel.detect(plistValue: "beta", version: "3.0.0") == .beta)
        #expect(ReleaseChannel.detect(plistValue: "stable", version: "3.0.0-beta.1") == .stable)
    }

    @Test("Stable update candidate ignores higher beta versions")
    func stableUpdateCandidateIgnoresHigherBetaVersions() {
        let releases = [
            release("v3.0.0-beta.1", prerelease: true),
            release("v2.7.0", prerelease: false),
            release("v2.6.4", prerelease: false)
        ]

        let candidate = UpdateChecker.latestStableRelease(in: releases)

        #expect(candidate?.tagName == "v2.7.0")
    }

    @Test("Stable update candidate ignores unflagged beta tags")
    func stableUpdateCandidateIgnoresUnflaggedBetaTags() {
        let releases = [
            release("v3.0.0-beta.2", name: "PriType 3.0 Beta 2", prerelease: false),
            release("v2.7.0", prerelease: false)
        ]

        let candidate = UpdateChecker.latestStableRelease(in: releases)

        #expect(candidate?.tagName == "v2.7.0")
    }

    @Test("Stable update candidate ignores drafts")
    func stableUpdateCandidateIgnoresDrafts() {
        let releases = [
            release("v2.8.0", draft: true, prerelease: false),
            release("v2.7.0", prerelease: false)
        ]

        let candidate = UpdateChecker.latestStableRelease(in: releases)

        #expect(candidate?.tagName == "v2.7.0")
    }

    private func release(
        _ tagName: String,
        name: String? = nil,
        draft: Bool = false,
        prerelease: Bool
    ) -> UpdateChecker.GitHubRelease {
        UpdateChecker.GitHubRelease(
            tagName: tagName,
            htmlUrl: "https://github.com/Meapri/PriType-Swift/releases/tag/\(tagName)",
            name: name,
            body: nil,
            draft: draft,
            prerelease: prerelease,
            assets: []
        )
    }
}
