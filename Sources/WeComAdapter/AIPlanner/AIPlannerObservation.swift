import AppKit
import AXKit
import CoreGraphics
import CryptoKit
import Foundation

/// An AX operation the fixed command may perform on a candidate. The model
/// selects a candidate only; the caller still decides which permitted operation
/// to use and authorizes it through the existing command action.
public enum AIPlannerCandidateKind: String, CaseIterable, Hashable {
    case press
    case selectRow
    case writeText
    case scroll
}

/// One actionable AX element in a single observation round. IDs are valid only
/// for that round and must never be persisted or used as a client coordinate.
public struct AIPlannerCandidate {
    public let id: String
    public let kind: AIPlannerCandidateKind
    public let element: AXElement
    public let role: String
    public let frame: CGRect
    let semanticDigest: Data

    fileprivate init(id: String, kind: AIPlannerCandidateKind, element: AXElement,
                     role: String, frame: CGRect, semanticDigest: Data) {
        self.id = id; self.kind = kind; self.element = element
        self.role = role; self.frame = frame; self.semanticDigest = semanticDigest
    }

    /// Test seam for action-level fakes. Real candidates always come from
    /// `AIPlannerObservation.capture` with a measured semantic digest.
    init(id: String, kind: AIPlannerCandidateKind, element: AXElement,
         role: String, frame: CGRect) {
        self.init(id: id, kind: kind, element: element, role: role, frame: frame,
                  semanticDigest: Data())
    }
}

/// A bounded, in-memory view of the verified WeCom window. The JPEG contains
/// only the AX main-window rectangle, not a display-sized transparent frame.
/// No image bytes, AX labels, or credential are written to disk or logs.
public struct AIPlannerObservation {
    public typealias Capture = (pid_t, CGRect) -> WeComWindowScreenshot?

    public let imageJPEG: Data
    public let windowPID: pid_t
    public let windowFrame: CGRect
    public let candidates: [AIPlannerCandidate]
    private let expectedTitle: String?
    private let allowedKinds: Set<AIPlannerCandidateKind>
    private let eligibleHandles: Set<AXElementHandle>?

    /// The caller passes the window obtained from `WeComWindowLocator` and its
    /// PID. Live calls also verify that PID against the running WeCom bundle.
    /// `expectedTitle` is required for a command that acts on a conversation;
    /// contacts pages may omit it because they expose no conversation header.
    public static func capture(
        window: AXElement,
        expectedPID: pid_t,
        expectedTitle: String? = nil,
        allowedKinds: Set<AIPlannerCandidateKind> = Set(AIPlannerCandidateKind.allCases),
        eligibleHandles: Set<AXElementHandle>? = nil,
        capture: Capture = { pid, frame in WeComScreenCapture.capture(windowPID: pid, expectedFrame: frame) }
    ) throws -> AIPlannerObservation {
        let frame = try validateWindow(window, expectedPID: expectedPID, expectedFrame: nil)
        try validateTitle(expectedTitle, window: window)
        guard !allowedKinds.isEmpty, eligibleHandles?.isEmpty != true else {
            throw AIPlannerVisionError.invalidCandidates
        }
        guard let candidates = discover(in: window, frame: frame, allowedKinds: allowedKinds,
                                        eligibleHandles: eligibleHandles),
              !candidates.isEmpty else { throw AIPlannerVisionError.invalidCandidates }
        guard let shot = capture(expectedPID, frame),
              let jpeg = AIPlannerWindowImage.prepare(shot: shot, expectedWindow: frame) else {
            throw AIPlannerVisionError.captureUnavailable
        }
        _ = try validateWindow(window, expectedPID: expectedPID, expectedFrame: frame)
        try validateTitle(expectedTitle, window: window)
        AIPlannerDiagnostics.recordCapture()
        return AIPlannerObservation(imageJPEG: jpeg, windowPID: expectedPID,
                                    windowFrame: frame, candidates: candidates,
                                    expectedTitle: expectedTitle, allowedKinds: allowedKinds,
                                    eligibleHandles: eligibleHandles)
    }

    /// Re-discover the element after the model returns. A changed PID, window,
    /// title, handle, role, ability, enabled state, or frame refuses the choice.
    /// The caller must do its usual post-action verification after acting.
    public func revalidate(candidateID: String, in window: AXElement) throws -> AIPlannerCandidate? {
        guard let prior = candidates.first(where: { $0.id == candidateID }) else { return nil }
        _ = try Self.validateWindow(window, expectedPID: windowPID, expectedFrame: windowFrame)
        try Self.validateTitle(expectedTitle, window: window)
        guard let fresh = Self.discover(in: window, frame: windowFrame, allowedKinds: allowedKinds,
                                        eligibleHandles: eligibleHandles) else { return nil }
        guard let now = fresh.first(where: { $0.element.handle == prior.element.handle }),
              now.role == prior.role, now.kind == prior.kind,
              now.semanticDigest == prior.semanticDigest,
              Self.nearlyEqual(now.frame, prior.frame) else { return nil }
        return now
    }

    private init(imageJPEG: Data, windowPID: pid_t, windowFrame: CGRect,
                 candidates: [AIPlannerCandidate], expectedTitle: String?,
                 allowedKinds: Set<AIPlannerCandidateKind>,
                 eligibleHandles: Set<AXElementHandle>?) {
        self.imageJPEG = imageJPEG; self.windowPID = windowPID; self.windowFrame = windowFrame
        self.candidates = candidates; self.expectedTitle = expectedTitle; self.allowedKinds = allowedKinds
        self.eligibleHandles = eligibleHandles
    }

    private static func validateWindow(_ window: AXElement, expectedPID: pid_t, expectedFrame: CGRect?) throws -> CGRect {
        do {
            guard expectedPID > 0, try window.role() == AXRole.window,
                  try window.pid() == expectedPID,
                  let frame = try window.frame(), frame.isFinitePositive,
                  frame.width <= 10_000, frame.height <= 10_000 else {
                throw AIPlannerVisionError.staleView
            }
            if window.backend.name == "live" {
                guard AXApp.runningApplication(bundleID: WeComClient.bundleID)?.processIdentifier == expectedPID else {
                    throw AIPlannerVisionError.staleView
                }
            }
            if let expectedFrame, !nearlyEqual(frame, expectedFrame) { throw AIPlannerVisionError.staleView }
            return frame
        } catch { throw AIPlannerVisionError.staleView }
    }

    private static func validateTitle(_ expectedTitle: String?, window: AXElement) throws {
        guard let expectedTitle else { return }
        guard !expectedTitle.isEmpty,
              (try? WeComReader(window: window).activeConversationTitle()) == expectedTitle else {
            throw AIPlannerVisionError.staleView
        }
    }

    private static func discover(in window: AXElement, frame: CGRect,
                                 allowedKinds: Set<AIPlannerCandidateKind>,
                                 eligibleHandles: Set<AXElementHandle>?) -> [AIPlannerCandidate]? {
        let maxNodes = 1_800, maxDepth = 12, maxCandidates = 64
        if let eligibleHandles {
            guard !eligibleHandles.isEmpty, eligibleHandles.count <= maxCandidates else { return nil }
            // Fixed commands have already identified their eligible AX objects.
            // Walking the entire contacts/messages tree to rediscover one row
            // can hit the unrelated-node limit before reaching that row. Prove
            // each handle is a descendant of this exact window instead, then
            // retain the same role, capability, frame and semantic checks.
            var scoped: [AIPlannerCandidate] = []
            for handle in eligibleHandles {
                let element = AXElement(handle: handle, backend: window.backend)
                guard belongsToWindow(element, window: window),
                      let role = try? element.role(),
                      let f = try? element.frame(), f.isFinitePositive,
                      frame.containsMostly(f) else { return nil }
                let kind: AIPlannerCandidateKind?
                if [AXRole.button, AXRole.menuItem].contains(role),
                   (try? element.actions().contains(AXAction.press)) == true {
                    kind = .press
                } else if role == AXRole.row,
                          let parent = try? element.parent(),
                          [AXRole.table, AXRole.outline, AXRole.list].contains((try? parent.role()) ?? ""),
                          (try? parent.isSettable(AXAttribute.selectedRows)) == true {
                    kind = .selectRow
                } else if [AXRole.textField, AXRole.textArea].contains(role),
                          (try? element.isSettable(AXAttribute.value)) == true {
                    kind = .writeText
                } else if role == AXRole.scrollBar,
                          (try? element.isSettable(AXAttribute.value)) == true {
                    kind = .scroll
                } else {
                    kind = nil
                }
                guard let kind, allowedKinds.contains(kind),
                      kind == .scroll || (try? element.isEnabled()) != false,
                      let semanticDigest = semanticDigest(of: element, kind: kind) else { return nil }
                scoped.append(AIPlannerCandidate(id: "C\(scoped.count)", kind: kind,
                                                 element: element, role: role, frame: f,
                                                 semanticDigest: semanticDigest))
            }
            return scoped
        }
        var queue: [(AXElement, Int)] = [(window, 0)]
        var head = 0
        var result: [AIPlannerCandidate] = []
        while head < queue.count, head < maxNodes {
            let (element, depth) = queue[head]
            head += 1
            guard let children = try? element.children() else { return nil }
            if depth >= maxDepth {
                if !children.isEmpty { return nil }
                continue
            }
            for child in children {
                if queue.count >= maxNodes { return nil }
                queue.append((child, depth + 1))
                guard let role = try? child.role(),
                      let f = try? child.frame(), f.isFinitePositive,
                      frame.containsMostly(f) else { continue }
                let kind: AIPlannerCandidateKind?
                if [AXRole.button, AXRole.menuItem].contains(role),
                   (try? child.actions().contains(AXAction.press)) == true {
                    kind = .press
                } else if role == AXRole.row,
                          let parent = try? child.parent(),
                          [AXRole.table, AXRole.outline, AXRole.list].contains((try? parent.role()) ?? ""),
                          (try? parent.isSettable(AXAttribute.selectedRows)) == true {
                    kind = .selectRow
                } else if [AXRole.textField, AXRole.textArea].contains(role),
                          (try? child.isSettable(AXAttribute.value)) == true {
                    kind = .writeText
                } else if role == AXRole.scrollBar,
                          (try? child.isSettable(AXAttribute.value)) == true {
                    kind = .scroll
                } else {
                    kind = nil
                }
                guard let kind, allowedKinds.contains(kind) else { continue }
                // WeCom's history scroll bar can report AXEnabled=false even
                // while AXValue remains writable. Other AX actions keep the
                // enabled guard; a disabled button or editor is never chosen.
                if kind != .scroll && (try? child.isEnabled()) == false { continue }
                guard let semanticDigest = semanticDigest(of: child, kind: kind) else { return nil }
                if result.count >= maxCandidates { return nil }
                result.append(AIPlannerCandidate(id: "C\(result.count)", kind: kind,
                                                 element: child, role: role, frame: f,
                                                 semanticDigest: semanticDigest))
            }
        }
        guard head == queue.count else { return nil }
        return result
    }

    /// The target must still belong to the verified window. AXParent is read
    /// at every hop and cycles, stale nodes or a second window fail closed.
    private static func belongsToWindow(_ element: AXElement, window: AXElement) -> Bool {
        var current = element
        var seen: Set<AXElementHandle> = [element.handle]
        for _ in 0..<24 {
            guard let parent = try? current.parent() else { return false }
            if parent.handle == window.handle { return true }
            guard seen.insert(parent.handle).inserted else { return false }
            current = parent
        }
        return false
    }

    /// A short irreversible digest of the candidate's own AX identity and its
    /// bounded visible labels. This detects row recycling or a button's meaning
    /// changing at the same AX handle/frame between inference and action. No
    /// chat/contact text is stored on a candidate or written to logs.
    private static func semanticDigest(of element: AXElement, kind: AIPlannerCandidateKind) -> Data? {
        var digest = SHA256()
        var bytesRead = 0
        func feed(_ value: String?) -> Bool {
            digest.update(data: Data([value == nil ? 0 : 1]))
            guard let value else { return true }
            let bytes = Data(value.utf8)
            bytesRead += bytes.count
            guard bytesRead <= 16_384 else { return false }
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
            digest.update(data: bytes)
            return true
        }
        let depthLimit = kind == .selectRow ? 3 : 1
        var queue: [(AXElement, Int)] = [(element, 0)]
        var head = 0
        while head < queue.count {
            if head >= 48 { return nil }
            let (node, depth) = queue[head]
            head += 1
            do {
                let role = try node.role()
                let title = try node.title()
                let value = try node.value()
                let description: String?
                do {
                    description = try node.axDescription()
                } catch {
                    // Live WeCom can fail AXDescription on an AXTextArea
                    // even when that same node's AXValue contains the exact
                    // readable label. The value is still hashed, so a recycled
                    // row with a changed label fails revalidation. Other AX
                    // read failures remain fatal to this candidate.
                    guard [AXRole.textArea, AXRole.textField, AXRole.staticText].contains(role ?? ""),
                          case .string(let label)? = value, !label.isEmpty else { return nil }
                    description = nil
                }
                guard feed(role), feed(title), feed(value?.summary), feed(description) else { return nil }
                if depth < depthLimit {
                    let children = try node.children()
                    if queue.count + children.count > 48 { return nil }
                    queue.append(contentsOf: children.map { ($0, depth + 1) })
                }
            } catch { return nil }
        }
        return Data(digest.finalize())
    }

    private static func nearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
            && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}

private extension CGRect {
    var isFinitePositive: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }

    func containsMostly(_ other: CGRect) -> Bool {
        let visible = intersection(other)
        return !visible.isNull && visible.width * visible.height >= other.width * other.height * 0.8
    }
}
