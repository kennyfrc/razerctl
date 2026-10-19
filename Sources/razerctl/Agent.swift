import Foundation

/// The desired spec, as the agent sees it. Reads and writes the declarative Mouse resource,
/// so an imperative "razerctl dpi 1600" and an applied mouse.yaml change the same thing.
struct Settings: Codable, Equatable {
    var dpi: Int?
    var polling: Int?
    var stage: Int?
    var buttonsSide: String?
    var idleSeconds: Int?
    var lowBatteryPercent: Int?

    static let directory = MouseResource.directory
    static let file = MouseResource.file

    static func load() -> Settings {
        guard let resource = MouseResource.load() else { return Settings() }
        return Settings(
            dpi: resource.spec.dpi,
            polling: resource.spec.pollingHz,
            stage: resource.spec.stage,
            buttonsSide: resource.spec.buttonsSide,
            idleSeconds: resource.spec.idleSeconds,
            lowBatteryPercent: resource.spec.lowBatteryPercent
        )
    }
}

/// One reconciliation fact, with the time it last changed state.
struct Condition: Codable, Equatable {
    var type: String
    var status: Bool
    var reason: String
    var lastTransitionTime: Date

    /// Keeps the old timestamp while the condition does not change, like a Kubernetes condition.
    static func next(_ previous: [Condition]?, type: String, status: Bool, reason: String, now: Date = Date()) -> Condition {
        let carried = previous?.first { $0.type == type && $0.status == status }?.lastTransitionTime
        return Condition(type: type, status: status, reason: reason, lastTransitionTime: carried ?? now)
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
    var link: String?
    var activeStage: Int?
    var sideButtons: String?
    var accessibility: String?
    var idleSeconds: Int?
    var lowBatteryPercent: Int?
    var deviceMode: Int?
    var phase: String?
    var conditions: [Condition]?
    var updatedAt: Date

    static let file = MouseResource.directory.appendingPathComponent("status.json")

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
        MouseResource.seedDefaults()
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
    // A first run with no config starts from the defaults instead of applying nothing.
    if MouseResource.seedDefaults() {
        Agent.logLine("wrote default config (800 dpi, 125 Hz)")
    }
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
    let buttonFilter = ButtonFilter()
    var sideFiltering = false
    var wantedSideSeen = "back"

    while true {
        // The side buttons are filtered by an OS event tap, so this must run whether or not
        // the mouse is present: the tap works on whatever device sends button 3 or 4.
        let wantedSide = Settings.load().buttonsSide ?? "back"
        let filtering = buttonFilter.sync(swallow: wantedSide == "off")
        if filtering != sideFiltering || wantedSide != wantedSideSeen {
            if wantedSide == "off" {
                Agent.logLine(filtering
                    ? "side buttons off"
                    : "side buttons asked off, but Accessibility is not granted for razerctl")
            } else if wantedSideSeen == "off" {
                Agent.logLine("side buttons back to back and forward")
            }
            wantedSideSeen = wantedSide
            sideFiltering = filtering
        }
        if var state = AgentState.load() {
            let side = filtering ? "off" : "back"
            let accessibility = ButtonFilter.hasAccessibility ? "granted" : "denied"
            if state.sideButtons != side || state.accessibility != accessibility {
                state.sideButtons = side
                state.accessibility = accessibility
                state.save()
            }
        }

        // The CLI opens the same HID device; without this lock the two reply queues interleave
        // and every command after that reads the previous answer.
        guard let deviceLock = DeviceLock.acquire(timeoutMs: 1500) else {
            Thread.sleep(forTimeInterval: 0.3)
            continue
        }
        guard let device = try? RazerDevice.open() else {
            deviceLock.release()
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
        defer { deviceLock.release() }
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
        // Mark a value as applied even when the write fails, so a setting the current link
        // cannot take (8 kHz on the cable) does not retry every five seconds. A reconnect
        // resets this, which is when the setting becomes possible again.
        // A failed write is only "done" when the link cannot do it at all. A busy or
        // timed-out write is retried on the next pass instead of being forgotten.
        if let stage = settings.stage, stage != applied.stage {
            do {
                try RazerCommands.activateStage(device, index: stage)
                noted.append("stage \(stage)")
                applied.stage = stage
            } catch RazerError.notSupported {
                applied.stage = stage
                Agent.logLine("stage \(stage) not supported on this link")
            } catch RazerError.deviceFailure {
                applied.stage = stage
                Agent.logLine("stage \(stage) rejected by the device")
            } catch {
                Agent.logLine("stage \(stage) failed (\(error)), retrying")
            }
        }
        if let dpi = settings.dpi, dpi != applied.dpi {
            do {
                try RazerCommands.setDPI(device, x: dpi, y: dpi)
                noted.append("dpi \(dpi)")
                applied.dpi = dpi
            } catch RazerError.notSupported {
                applied.dpi = dpi
                Agent.logLine("dpi \(dpi) not supported on this link")
            } catch RazerError.deviceFailure {
                applied.dpi = dpi
                Agent.logLine("dpi \(dpi) rejected by the device")
            } catch {
                Agent.logLine("dpi \(dpi) failed (\(error)), retrying")
            }
        }
        if let polling = settings.polling, polling != applied.polling {
            do {
                try RazerCommands.setPollingRate(device, hz: polling)
                noted.append("polling \(polling) Hz")
                applied.polling = polling
            } catch RazerError.notSupported {
                applied.polling = polling
                Agent.logLine("polling \(polling) not supported on this link")
            } catch {
                Agent.logLine("polling \(polling) failed (\(error)), retrying")
            }
        }
        if let seconds = settings.idleSeconds, seconds != applied.idleSeconds {
            do {
                try RazerCommands.setIdleTime(device, seconds: seconds)
                noted.append("sleep \(seconds)s")
                applied.idleSeconds = seconds
            } catch RazerError.notSupported {
                applied.idleSeconds = seconds
                Agent.logLine("sleep \(seconds)s not supported on this link")
            } catch {
                Agent.logLine("sleep \(seconds)s failed (\(error)), retrying")
            }
        }
        if let percent = settings.lowBatteryPercent, percent != applied.lowBatteryPercent {
            do {
                try RazerCommands.setLowBatteryPercent(device, percent: percent)
                noted.append("low battery \(percent)%")
                applied.lowBatteryPercent = percent
            } catch RazerError.notSupported {
                applied.lowBatteryPercent = percent
                Agent.logLine("low battery \(percent)% not supported on this link")
            } catch {
                Agent.logLine("low battery \(percent)% failed (\(error)), retrying")
            }
        }
        if !noted.isEmpty {
            Agent.logLine("applied \(noted.joined(separator: ", "))")
            // Let the link settle before reading values back, or the read comes back BUSY.
            Thread.sleep(forTimeInterval: 0.4)
            lastBatteryRead = .distantPast
        }

        if Date().timeIntervalSince(lastBatteryRead) > 60 {
            let battery = try? RazerCommands.battery(device)
            let dpi = try? RazerCommands.dpi(device)
            let activeStage = (try? RazerCommands.dpiStages(device))?.active
            let polling = try? RazerCommands.pollingRate(device)
            let idle = try? RazerCommands.idleTime(device)
            let lowBattery = try? RazerCommands.lowBatteryPercent(device)
            let mode = try? RazerCommands.deviceMode(device)
            let state = AgentState(
                product: RazerDevice.describe(productId: device.productId, productName: device.productName),
                productId: String(format: "1532:%04X", device.productId),
                batteryPercent: battery?.percent,
                charging: battery?.charging,
                dpiX: dpi?.x,
                dpiY: dpi?.y,
                pollingHz: polling?.hz,
                connected: true,
                activeStage: activeStage,
                sideButtons: sideFiltering ? "off" : "back",
                accessibility: ButtonFilter.hasAccessibility ? "granted" : "denied",
                idleSeconds: idle,
                lowBatteryPercent: lowBattery,
                deviceMode: mode,
                updatedAt: Date()
            )
            state.save()
            lastBatteryRead = Date()
        }

        Thread.sleep(forTimeInterval: 5)
    }
}
