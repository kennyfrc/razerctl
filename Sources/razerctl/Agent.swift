import Foundation

/// Settings the agent reapplies when the mouse reconnects. The CLI writes this file;
/// the launchd agent reads it, so a change lands even when the CLI itself holds no
/// Input Monitoring grant.
struct Settings: Codable {
    var dpi: Int?
    var polling: Int?

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/razerctl", isDirectory: true)
    static let file = directory.appendingPathComponent("config.json")

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return settings
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Settings.file)
    }
}

/// What the agent last saw, so a CLI without permission can still report the mouse.
struct AgentState: Codable {
    var product: String
    var productId: String
    var batteryPercent: Int?
    var charging: Bool?
    var dpiX: Int?
    var dpiY: Int?
    var pollingHz: Int?
    var connected: Bool?
    var updatedAt: Date

    static let file = Settings.directory.appendingPathComponent("state.json")

    static func load() -> AgentState? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentState.self, from: data)
    }

    func save() {
        try? FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: AgentState.file)
    }

    var age: TimeInterval { Date().timeIntervalSince(updatedAt) }
    var isFresh: Bool { age < 300 }
}

enum Agent {
    static let label = "local.razerctl"
    static let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/local.razerctl.plist")
    static let log = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/razerctl.log")

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plist.path)
    }

    static var isRunning: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func logLine(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        // launchd points both stdout and stderr at the same file, so only write to stderr
        // when a person is watching in a terminal.
        if isatty(STDERR_FILENO) == 1 {
            FileHandle.standardError.write(Data(line.utf8))
        }
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: log.path, contents: Data(line.utf8))
        }
    }

    static func install() throws {
        guard let executable = Bundle.main.executablePath ?? CommandLine.arguments.first else {
            throw CLIError("cannot work out my own path")
        }
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Agent.log.deletingLastPathComponent(), withIntermediateDirectories: true)

        let contents = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(path)</string>
                <string>watch</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(log.path)</string>
            <key>StandardErrorPath</key>
            <string>\(log.path)</string>
        </dict>
        </plist>
        """
        try contents.write(to: plist, atomically: true, encoding: .utf8)
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        let status = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path])
        if status != 0 {
            throw CLIError("launchctl bootstrap failed with status \(status)")
        }
    }

    static func uninstall() throws {
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        if FileManager.default.fileExists(atPath: plist.path) {
            try FileManager.default.removeItem(at: plist)
        }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

/// Runs until stopped: reopens the mouse when it appears, applies saved settings once,
/// and records battery and DPI so the CLI can report them without permission.
func runWatch() {
    Agent.logLine("agent started")
    // Anything the last run recorded is stale until this run sees the mouse again.
    if var previous = AgentState.load() {
        previous.connected = false
        previous.updatedAt = Date()
        previous.save()
    }
    var connected = false
    var permissionProblemLogged = false
    var applied = Settings()
    var lastBatteryRead = Date.distantPast

    while true {
        guard let device = try? RazerDevice.open() else {
            if !HIDAccess.isGranted, !permissionProblemLogged {
                Agent.logLine("no Input Monitoring grant; turn on razerctl in System Settings > Privacy & Security")
                permissionProblemLogged = true
            }
            if connected {
                Agent.logLine("device gone")
                // Keep the last readings but mark them stale, so the CLI does not present
                // them as live values while the mouse is unplugged.
                if var state = AgentState.load() {
                    state.connected = false
                    state.updatedAt = Date()
                    state.save()
                }
            }
            connected = false
            applied = Settings()
            Thread.sleep(forTimeInterval: 5)
            continue
        }
        permissionProblemLogged = false

        if !connected {
            Agent.logLine("device connected: \(RazerDevice.describe(productId: device.productId, productName: device.productName))")
            connected = true
            lastBatteryRead = .distantPast
        }

        // Re-read the config file every pass, so a change made by the CLI lands without
        // waiting for the mouse to reconnect.
        let settings = Settings.load()
        var noted: [String] = []
        if let dpi = settings.dpi, dpi != applied.dpi,
           (try? RazerCommands.setDPI(device, x: dpi, y: dpi)) != nil {
            noted.append("dpi \(dpi)")
            applied.dpi = dpi
        }
        if let polling = settings.polling, polling != applied.polling,
           (try? RazerCommands.setPollingRate(device, hz: polling)) != nil {
            noted.append("polling \(polling) Hz")
            applied.polling = polling
        }
        if !noted.isEmpty {
            Agent.logLine("applied \(noted.joined(separator: ", "))")
            lastBatteryRead = .distantPast
        }

        if Date().timeIntervalSince(lastBatteryRead) > 60 {
            let battery = try? RazerCommands.battery(device)
            let dpi = try? RazerCommands.dpi(device)
            let polling = try? RazerCommands.pollingRate(device)
            let state = AgentState(
                product: RazerDevice.describe(productId: device.productId, productName: device.productName),
                productId: String(format: "1532:%04X", device.productId),
                batteryPercent: battery?.percent,
                charging: battery?.charging,
                dpiX: dpi?.x,
                dpiY: dpi?.y,
                pollingHz: polling?.hz,
                connected: true,
                updatedAt: Date()
            )
            state.save()
            lastBatteryRead = Date()
        }

        Thread.sleep(forTimeInterval: 5)
    }
}
