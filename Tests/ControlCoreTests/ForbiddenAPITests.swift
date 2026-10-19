import Foundation
import Testing

/// Hard constraint from the design: no unapproved synthetic input or TCC
/// surface. Screen Recording is allowed only in the two audited files for the
/// user's 2026-09-24 in-memory media-direction decision.
@Suite("Forbidden API guard")
struct ForbiddenAPITests {
    static let forbidden = [
        "CGEvent", "CGWarpMouseCursor", "CGPostKeyboardEvent", "IOHIDPostEvent",
        "CGPreflightListenEventAccess", "CGRequestListenEventAccess",
    ]
    static let screenCaptureTokens = [
        "CGRequestScreenCaptureAccess", "CGPreflightScreenCaptureAccess",
        "ScreenCaptureKit", "SCScreenshotManager", "CGWindowListCreateImage", "CGDisplayCreateImage",
    ]
    static let screenCaptureAllowed: Set<String> = [
        "WeComAdapter/Handler/WeComCommandHandler+Permissions.swift",
        "WeComAdapter/WeComScreenCapture.swift",
    ]
    /// The window list also returns every app's window titles once Screen Recording is granted.
    /// B49/B50 read only the client's own window numbers, layers and bounds, in these two files.
    static let windowListToken = "CGWindowListCopyWindowInfo"
    static let windowListAllowed: Set<String> = [
        "WeComAdapter/WeComWindowIdentity.swift",
        "imctl/Commands/ProbeAddCustomerCommand.swift",
    ]

    /// The one sanctioned exception (user decision 2026-09-12): a Return key posted to a single pid.
    static let exceptionFile = "KeystrokeInjector.swift"
    /// ⌘1…⌘8 and no other digit: the digit → key-code table in that same file is what decides which digits
    /// exist at all, so it is pinned here character for character.
    static let approvedDigitTable = "[1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28][d]"
    static let exceptionMustContain = ["postToPid(", approvedDigitTable]
    static let exceptionMustNotContain = ["cghidEventTap", "post(tap", "CGEventPost(", "CGEventTapCreate", "CGEventTapEnable",
                                          "mouseEventSource", "CGWarpMouseCursor", "postToPSN"]

    static var sourcesRoot: URL {
        // .../Tests/ControlCoreTests/ForbiddenAPITests.swift -> package root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    @Test func sourcesNeverMentionSyntheticInputOrExtraTCC() throws {
        let fm = FileManager.default
        let enumerator = try #require(fm.enumerator(at: Self.sourcesRoot, includingPropertiesForKeys: nil))
        var hits: [String] = []
        var scanned = 0
        var exceptionSeen = false
        let root = Self.sourcesRoot.standardizedFileURL.path
        var captureFilesSeen: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let relative = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
            if text.contains(Self.windowListToken), !Self.windowListAllowed.contains(relative) {
                hits.append("\(relative): unapproved window list API")
            }
            if Self.screenCaptureTokens.contains(where: text.contains) {
                captureFilesSeen.insert(relative)
                if !Self.screenCaptureAllowed.contains(relative) { hits.append("\(relative): unapproved screen capture API") }
            }
            if url.lastPathComponent == Self.exceptionFile {
                exceptionSeen = true
                for must in Self.exceptionMustContain where !text.contains(must) { hits.append("\(url.lastPathComponent): missing \(must)") }
                for bad in Self.exceptionMustNotContain where text.contains(bad) { hits.append("\(url.lastPathComponent): \(bad)") }
                for token in Self.forbidden where token != "CGEvent" && text.contains(token) { hits.append("\(url.lastPathComponent): \(token)") }
                continue
            }
            for token in Self.forbidden where text.contains(token) {
                hits.append("\(url.lastPathComponent): \(token)")
            }
        }
        #expect(scanned > 0, "guard scanned no files; sourcesRoot wrong?")
        #expect(exceptionSeen, "expected \(Self.exceptionFile) to exist (the only file allowed to mention CGEvent)")
        #expect(captureFilesSeen == Self.screenCaptureAllowed, "screen-capture surface changed: \(captureFilesSeen.sorted())")
        #expect(hits.isEmpty, "Forbidden API usage: \(hits)")
    }

    // MARK: The approved shortcut set

    /// Every synthetic key the user approved, by name: ⌘1–⌘8 (one parameterised case), ⌃Tab, ⇧⌃Tab and ⌘N
    /// for the B7 navigation rail (2026-09-15, ⌘N at 16:3x), and ⌘V for B13 `message.sendFile` (2026-09-22
    /// 17:43). The submit Return (2026-09-12) is not a `Shortcut` — it is `postReturn` in the same file.
    /// Another key is a user decision recorded in the wiki, never a code change alone.
    static let approvedShortcutCases: Set<String> = ["commandDigit", "controlTab", "shiftControlTab", "commandN", "commandV"]

    /// The `case` names declared directly inside `KeystrokeInjector.Shortcut`, read out of the source.
    /// `commandDigit(Int)` carries an associated value, so the enum cannot be `CaseIterable` and there is no
    /// `allCases` to compare against — this scan is the guard, in the same textual style as the rest of this
    /// suite. Pattern-match lines (`case .commandV:` …) start with a dot and are skipped.
    static func declaredShortcutCases(in text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let open = lines.firstIndex(where: { $0.contains("enum Shortcut") }) else { return [] }
        let indent = String(repeating: " ", count: lines[open].prefix { $0 == " " }.count)
        var names: [String] = []
        for line in lines[(open + 1)...] {
            if line == indent + "}" { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { continue }
            let name = String(trimmed.dropFirst(5).prefix { $0.isLetter || $0.isNumber })
            if !name.isEmpty { names.append(name) }
        }
        return names
    }

    @Test func theShortcutEnumDeclaresExactlyTheApprovedKeys() throws {
        let file = Self.sourcesRoot.appendingPathComponent("WeComAdapter/Actions/KeystrokeInjector.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let declared = Self.declaredShortcutCases(in: text)
        #expect(declared.count == Self.approvedShortcutCases.count)
        #expect(Set(declared) == Self.approvedShortcutCases, "approved shortcuts changed: \(declared.sorted())")
        // The scan itself must be able to see an unapproved key; otherwise this guard would pass vacuously.
        let smuggled = text.replacingOccurrences(of: "        case commandV\n", with: "        case commandV\n        case commandQ\n")
        #expect(smuggled != text, "the enum no longer spells `case commandV` the way this guard splices on")
        #expect(Set(Self.declaredShortcutCases(in: smuggled)) != Self.approvedShortcutCases)
    }

    // MARK: The pasteboard

    /// The daemon's only clipboard access is the audited snapshot / restore around `message.sendFile`'s one
    /// ⌘V (`Pasteboard.swift`); the two console views are the user's own 复制 buttons in the foreground app,
    /// which write the string the person just asked for. Anywhere else, reading or writing the person's
    /// clipboard is a new side effect on their machine and needs a decision, not a commit.
    static let pasteboardAllowed: Set<String> = [
        "WeComAdapter/Actions/Pasteboard.swift",
        "imctl-console/Views/ResultPane.swift",
        "imctl-console/Views/ConversationsView.swift",
    ]

    @Test func onlyTheAuditedFilesTouchNSPasteboard() throws {
        let fm = FileManager.default
        let root = Self.sourcesRoot.standardizedFileURL.path
        let enumerator = try #require(fm.enumerator(at: Self.sourcesRoot, includingPropertiesForKeys: nil))
        var hits: [String] = []
        var seen: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
            guard try String(contentsOf: url, encoding: .utf8).contains("NSPasteboard") else { continue }
            seen.insert(relative)
            if !Self.pasteboardAllowed.contains(relative) { hits.append(relative) }
        }
        #expect(hits.isEmpty, "NSPasteboard outside the audited files: \(hits)")
        #expect(seen.contains("WeComAdapter/Actions/Pasteboard.swift"), "the sendFile clipboard abstraction is gone; this guard would pass vacuously")
    }
}
