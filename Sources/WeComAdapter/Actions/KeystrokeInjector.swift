import CoreGraphics
import Foundation

/// The sanctioned exceptions to "no synthetic input", all delivered to ONE
/// process via CGEventPostToPid: one Return key press (user decision
/// 2026-09-12: WeCom has no send button, Enter is the only way to send; the
/// same key on the group picker's search field, approved 2026-09-15 16:3x) and
/// the client's own "切换左侧 Tab" shortcuts ⌘1–⌘8 / ⌃Tab plus ⌘N (user
/// decisions 2026-09-15: the navigation rail is unreachable through AX, there
/// is no deep link to 通讯录, and the + button ignores AXPress), plus ⌘V (user
/// decision 2026-09-22 17:43: paste the outbox file URL into the composer for
/// message.sendFile; B13). Never a global event tap, never posted to the HID
/// event stream, never mouse, never any other key. `ForbiddenAPITests`
/// allows `CGEvent` only in this file and checks those constraints textually.
public enum KeystrokeInjector {
    static let returnKey: CGKeyCode = 36 // kVK_Return

    /// Keys approved on 2026-09-15 for reaching 通讯录 (⌘1–⌘8, ⌃Tab) and
    /// opening 发起群聊 (⌘N, approved 16:3x), and ⌘V (2026-09-22). Nothing else.
    public enum Shortcut: Equatable {
        case commandDigit(Int)
        case controlTab
        case shiftControlTab
        /// ⌘N = 发起群聊 (the + button does not react to AXPress; live 2026-09-15; user-approved 16:3x).
        case commandN
        /// ⌘V = paste the file URL the daemon put on the pasteboard (message.sendFile; user-approved 2026-09-22 17:43). Never text, never ⌘C / ⌘X.
        case commandV

        public var keyCode: CGKeyCode? {
            switch self {
            case .commandDigit(let d): return [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28][d]
            case .controlTab, .shiftControlTab: return 48
            case .commandN: return 45
            case .commandV: return 9
            }
        }

        public var flags: CGEventFlags {
            switch self {
            case .commandDigit, .commandN, .commandV: return [.maskCommand]
            case .controlTab: return [.maskControl]
            case .shiftControlTab: return [.maskControl, .maskShift]
            }
        }
    }

    public static func postShortcut(_ shortcut: Shortcut, toPid pid: pid_t) throws {
        guard let key = shortcut.keyCode,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else {
            throw Failure.eventCreation
        }
        down.flags = shortcut.flags
        up.flags = shortcut.flags
        down.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.03)
        up.postToPid(pid)
    }

    public enum Failure: Error, Equatable {
        case eventCreation
    }

    public static func postReturn(toPid pid: pid_t, control: Bool) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: returnKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: returnKey, keyDown: false) else {
            throw Failure.eventCreation
        }
        let flags: CGEventFlags = control ? [.maskControl] : []
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.02)
        up.postToPid(pid)
    }
}
