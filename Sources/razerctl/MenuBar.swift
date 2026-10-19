import AppKit
import Foundation

/// Menu bar item for the mouse. It only reads the agent's state file and writes the spec, so
/// it needs no permissions of its own: the agent does the talking to the device.
final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var signature = ""

    static let dpiChoices = [800, 1000, 1600, 2400, 3200]
    static let pollingChoices = [125, 500, 1000, 2000, 8000]
    static let sleepChoices = [120, 300, 600, 900]
    static let lowBatteryChoices = [5, 10, 15, 20]

    func start() {
        NSApp.setActivationPolicy(.accessory)
        item.isVisible = false
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
        NSApp.run()
    }

    private func refresh() {
        guard let state = AgentState.load(), state.connected == true, state.isFresh else {
            // The user asked for the item only while the mouse is connected.
            item.isVisible = false
            signature = ""
            return
        }
        item.isVisible = true
        let percent = state.batteryPercent.map { "\($0)%" } ?? "--"
        item.button?.title = "Razer \(percent)"

        let spec = MouseResource.load()?.spec
        let next = [
            state.product, percent,
            "\(state.dpiX ?? 0)", "\(state.pollingHz ?? 0)", "\(state.idleSeconds ?? 0)",
            "\(state.lowBatteryPercent ?? 0)", spec?.buttonsSide ?? "back",
            "\(state.activeStage ?? 0)",
        ].joined(separator: "|")
        guard next != signature else { return }
        signature = next
        item.menu = buildMenu(state: state, spec: spec)
    }

    private func buildMenu(state: AgentState, spec: MouseSpec?) -> NSMenu {
        let menu = NSMenu()

        let title = NSMenuItem(title: state.product, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let battery = NSMenuItem(
            title: "Battery \(state.batteryPercent.map { "\($0)%" } ?? "-")\(state.charging == true ? " (charging)" : "")",
            action: nil,
            keyEquivalent: ""
        )
        battery.isEnabled = false
        menu.addItem(battery)
        menu.addItem(.separator())

        menu.addItem(submenu("DPI", choices: MenuBarController.dpiChoices.map { ($0, "\($0)") },
                             current: spec?.dpi ?? state.dpiX,
                             action: #selector(setDPI(_:))))
        menu.addItem(submenu("Polling", choices: MenuBarController.pollingChoices.map { ($0, "\($0) Hz") },
                             current: spec?.pollingHz ?? state.pollingHz,
                             action: #selector(setPolling(_:))))
        menu.addItem(submenu("Sleep after", choices: MenuBarController.sleepChoices.map { ($0, "\($0 / 60) min") },
                             current: spec?.idleSeconds ?? state.idleSeconds,
                             action: #selector(setSleep(_:))))
        menu.addItem(submenu("Low battery warning", choices: MenuBarController.lowBatteryChoices.map { ($0, "\($0)%") },
                             current: spec?.lowBatteryPercent ?? state.lowBatteryPercent,
                             action: #selector(setLowBattery(_:))))
        menu.addItem(submenu("Side buttons", choices: [(0, "Do nothing"), (1, "Back and forward")],
                             current: (spec?.buttonsSide ?? "back") == "off" ? 0 : 1,
                             action: #selector(setSide(_:))))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open config", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit razerctl menu", action: #selector(quit), keyEquivalent: "q"))

        for entry in menu.items where entry.action != nil { entry.target = self }
        return menu
    }

    private func submenu(_ name: String, choices: [(Int, String)], current: Int?, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for (value, label) in choices {
            let entry = NSMenuItem(title: label, action: action, keyEquivalent: "")
            entry.tag = value
            entry.state = value == current ? .on : .off
            entry.target = self
            menu.addItem(entry)
        }
        parent.submenu = menu
        return parent
    }

    private func write(_ change: (inout MouseSpec) -> Void) {
        var resource = MouseResource.load() ?? MouseResource()
        change(&resource.spec)
        try? resource.save()
        signature = ""
        refresh()
    }

    @objc private func setDPI(_ sender: NSMenuItem) {
        let value = sender.tag
        write { $0.dpi = value; $0.stage = nil }
    }

    @objc private func setPolling(_ sender: NSMenuItem) {
        let value = sender.tag
        write { $0.pollingHz = value }
    }

    @objc private func setSleep(_ sender: NSMenuItem) {
        let value = sender.tag
        write { $0.idleSeconds = value }
    }

    @objc private func setLowBattery(_ sender: NSMenuItem) {
        let value = sender.tag
        write { $0.lowBatteryPercent = value }
    }

    @objc private func setSide(_ sender: NSMenuItem) {
        let value = sender.tag == 0 ? "off" : "back"
        write { $0.buttonsSide = value }
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(MouseResource.file)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Agent.log)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

func runMenuBar() {
    let controller = MenuBarController()
    controller.start()
}

/// The menu bar runs as its own LaunchAgent so it starts with the session and restarts if it
/// dies. It needs no grants: it reads the state file and writes the spec.
enum MenuBarAgent {
    static let label = "local.razerctl.menubar"
    static let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/local.razerctl.menubar.plist")

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static var isRunning: Bool {
        Agent.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]) == 0
    }

    static func install() throws {
        let binary = CommandLine.arguments[0]
        let resolved = binary.hasPrefix("/") ? binary : FileManager.default.currentDirectoryPath + "/" + binary
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key><array><string>\(resolved)</string><string>menubar</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>ProcessType</key><string>Interactive</string>
        </dict></plist>
        """
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: plist, atomically: true, encoding: .utf8)
        _ = Agent.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        _ = Agent.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path])
    }

    static func uninstall() {
        _ = Agent.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plist)
    }
}
