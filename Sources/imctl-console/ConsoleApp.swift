import AppKit
import SwiftUI

@main
struct ConsoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = ConsoleModel()

    var body: some Scene {
        Window("imctl 控制台", id: "console") {
            ConsoleWindow().environment(model)
                .background(WindowHider())
        }
        .defaultSize(width: 1180, height: 780)
        .commands { CommandGroup(replacing: .newItem) {} }
        MenuBarExtra("imctl", systemImage: model.menuBarSymbol) {
            MenuBarMenu().environment(model)
        }
    }
}

/// Dock + menu bar (B12, user 2026-09-16: the menu-bar item alone was easy to miss). `DockPresence` keeps the
/// choice; clicking the Dock icon or the menu-bar item reopens the console window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openConsole = Notification.Name("imctl.console.open")

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockPresence.apply()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dock icon clicked with no window open: bring the console back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.showConsole() }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开控制台", action: #selector(openConsoleAction), keyEquivalent: "").target = self
        return menu
    }

    @objc func openConsoleAction() { Self.showConsole() }

    @discardableResult
    static func showConsole() -> Bool {
        // Closing only hides the window; restore it directly when it already exists.
        let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "console" || $0.title == "imctl 控制台" })
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window != nil
    }
}

/// Closing the console hides it instead of destroying it, so the Dock icon and the menu-bar item can bring it back.
struct WindowHider: NSViewRepresentable {
    final class Interceptor: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    }
    final class HostView: NSView {
        let interceptor = Interceptor()
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.delegate = interceptor
            window?.identifier = NSUserInterfaceItemIdentifier("console")
            window?.collectionBehavior.insert(.fullScreenPrimary)   // the green button enters full screen (user 2026-09-16)
            window?.minSize = NSSize(width: 920, height: 620)
        }
    }
    func makeNSView(context: Context) -> HostView { HostView() }
    func updateNSView(_ nsView: HostView, context: Context) {}
}

/// Whether the console shows in the Dock (regular app) or only in the menu bar (accessory). Stored in
/// UserDefaults; default on since B12 — a menu-bar-only app was hard to find.
enum DockPresence {
    static let key = "showInDock"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key); apply() }
    }
    static func apply() {
        NSApp.setActivationPolicy(enabled ? .regular : .accessory)
    }
}
