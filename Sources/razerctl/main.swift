import Foundation

let usageText = """
razerctl - control Razer mice on macOS without Synapse

USAGE
  razerctl list                    Show Razer HID interfaces on the bus
  razerctl info                    Device name, firmware, serial, battery, DPI, polling
  razerctl battery                 Battery percentage and charging state
  razerctl dpi                     Read the current DPI
  razerctl dpi <value>             Set DPI (100-35000)
  razerctl polling                 Read the polling rate
  razerctl polling <hz>            Set the polling rate (125/250/500/1000/2000/4000/8000)
  razerctl raw <class> <id> <size> [hex bytes...]
                                   Send a raw Razer report, for protocol work
  razerctl doctor                  Permissions, device detection, and a live probe
  razerctl bluetooth               Report the Bluetooth capability of this model

OPTIONS
  --json          Machine readable output (info, battery, dpi, polling)
  --pid <hex>     Target one product id, for example --pid 0xC1
  --txid <hex>    Override the transaction id byte (default from the model table)
"""

struct Options {
    var json = false
    var productId: Int?
    var transactionId: UInt8?
}

func parseNumber(_ text: String) -> Int? {
    if text.lowercased().hasPrefix("0x") {
        return Int(text.dropFirst(2), radix: 16)
    }
    return Int(text)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("razerctl: \(message)\n".utf8))
    exit(1)
}

func printJSON(_ object: [String: Any]) {
    let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    if let data, let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func openDevice(_ options: Options) throws -> RazerDevice {
    let device = try RazerDevice.open(productId: options.productId)
    if let txid = options.transactionId { device.transactionId = txid }
    return device
}

// MARK: - Commands

func runList(options: Options) {
    let interfaces = RazerDevice.interfaces()
    guard !interfaces.isEmpty else {
        print("No Razer HID device found. Check the cable or the 2.4 GHz dongle.")
        return
    }
    let rows = interfaces.map { iface -> [String] in
        let control = iface.maxFeatureReportSize >= RazerReport.wireSize ? "yes" : "-"
        return [
            String(format: "0x%04X", iface.productId),
            String(format: "0x%08X", iface.locationId),
            String(format: "0x%02X/0x%02X", iface.usagePage, iface.usage),
            String(iface.maxFeatureReportSize),
            control,
            RazerDevice.describe(productId: iface.productId, productName: iface.productName),
        ]
    }
    printTable(headers: ["PID", "LOCATION", "USAGE", "FEATURE", "CONTROL", "DEVICE"], rows: rows)
}

func runInfo(options: Options) throws {
    let device = try openDevice(options)
    let model = RazerDevice.describe(productId: device.productId, productName: device.productName)
    let firmware = try? RazerCommands.firmwareVersion(device)
    let serial = try? RazerCommands.serialNumber(device)
    let battery = try? RazerCommands.battery(device)
    let dpi = try? RazerCommands.dpi(device)
    let polling = try? RazerCommands.pollingRate(device)

    if options.json {
        var object: [String: Any] = [
            "product": device.productName,
            "model": model,
            "productId": String(format: "0x%04X", device.productId),
        ]
        if let firmware { object["firmware"] = firmware }
        if let serial { object["serial"] = serial }
        if let battery {
            object["batteryPercent"] = battery.percent
            object["batteryRaw"] = battery.raw
            if let charging = battery.charging { object["charging"] = charging }
        }
        if let dpi { object["dpiX"] = dpi.x; object["dpiY"] = dpi.y }
        if let polling { object["pollingHz"] = polling.hz }
        printJSON(object)
        return
    }

    let rows: [[String]] = [
        ["Device", "\(model) (\(String(format: "1532:%04X", device.productId)))"],
        ["Port", String(format: "0x%08X", device.locationId)],
        ["Firmware", firmware ?? "unknown"],
        ["Serial", serial ?? "unknown"],
        ["Battery", battery.map { "\($0.percent)%\($0.charging == true ? " (charging)" : "")" } ?? "unavailable"],
        ["DPI", dpi.map { "\($0.x) x \($0.y)" } ?? "unavailable"],
        ["Polling", polling.map { "\($0.hz) Hz" } ?? "unavailable"],
    ]
    for row in rows {
        let padding = String(repeating: " ", count: max(0, 8 - row[0].count))
        print("\(row[0]):\(padding)\(row[1])")
    }
}

func runBattery(options: Options) throws {
    let device = try openDevice(options)
    let reading = try RazerCommands.battery(device)
    if options.json {
        var object: [String: Any] = ["percent": reading.percent, "raw": reading.raw]
        if let charging = reading.charging { object["charging"] = charging }
        printJSON(object)
        return
    }
    print("\(reading.percent)%\(reading.charging == true ? " (charging)" : "")")
}

func runDPI(options: Options, argument: String?) throws {
    let device = try openDevice(options)
    guard let argument else {
        let dpi = try RazerCommands.dpi(device)
        if options.json {
            printJSON(["x": dpi.x, "y": dpi.y])
        } else {
            print("\(dpi.x) x \(dpi.y)")
        }
        return
    }
    guard let value = Int(argument) else { fail("dpi expects a number, got '\(argument)'") }
    try RazerCommands.setDPI(device, x: value, y: value)
    let dpi = try RazerCommands.dpi(device)
    if options.json {
        printJSON(["x": dpi.x, "y": dpi.y])
    } else {
        print("DPI set to \(dpi.x) x \(dpi.y)")
    }
}

func runPolling(options: Options, argument: String?) throws {
    let device = try openDevice(options)
    guard let argument else {
        let polling = try RazerCommands.pollingRate(device)
        if options.json {
            printJSON(["hz": polling.hz, "command": polling.family])
        } else {
            print("\(polling.hz) Hz")
        }
        return
    }
    guard let hz = Int(argument) else { fail("polling expects a number, got '\(argument)'") }
    guard RazerCommands.supportedRates.contains(hz) else {
        fail("supported rates: \(RazerCommands.supportedRates.map(String.init).joined(separator: ", "))")
    }
    try RazerCommands.setPollingRate(device, hz: hz)
    let polling = try RazerCommands.pollingRate(device)
    if options.json {
        printJSON(["hz": polling.hz, "command": polling.family])
    } else {
        print("Polling rate set to \(polling.hz) Hz")
    }
}

func runRaw(options: Options, arguments: [String]) throws {
    guard arguments.count >= 3,
          let commandClass = parseNumber(arguments[0]),
          let commandId = parseNumber(arguments[1]),
          let dataSize = parseNumber(arguments[2])
    else {
        fail("usage: razerctl raw <class> <id> <size> [hex bytes...]")
    }
    let payload = arguments.dropFirst(3).map { parseNumber($0) ?? 0 }.map { UInt8(truncatingIfNeeded: $0) }
    let device = try openDevice(options)
    let request = RazerReport(
        commandClass: UInt8(truncatingIfNeeded: commandClass),
        commandId: UInt8(truncatingIfNeeded: commandId),
        dataSize: UInt8(truncatingIfNeeded: dataSize),
        arguments: payload
    )
    let reply = try device.send(request)
    let status = RazerStatus(rawValue: reply.status)
    print("status: \(status?.label ?? String(format: "0x%02X", reply.status))")
    print("args:   \(reply.argumentsHex)")
}

func runDoctor(options: Options) {
    var problems = 0
    print("Input Monitoring: \(HIDAccess.label)")
    if !HIDAccess.isGranted {
        problems += 1
        print("  macOS blocks reading a mouse interface without it.")
        print("  Enable the app that runs your shell in System Settings > Privacy & Security > Input Monitoring,")
        print("  then quit and reopen that app. This opens the pane:")
        print("    open \"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent\"")
    }

    let interfaces = RazerDevice.interfaces()
    let control = RazerDevice.controlInterfaces()
    print("Razer interfaces: \(interfaces.count) (\(control.count) can carry the 90-byte control report)")
    if interfaces.isEmpty {
        problems += 1
        print("  Nothing found on vendor 0x1532. Check the cable or the dongle.")
    }

    if HIDAccess.isGranted, let device = try? openDevice(options) {
        let model = RazerDevice.describe(productId: device.productId, productName: device.productName)
        print("Selected device:  \(model) (\(String(format: "1532:%04X", device.productId)))")
        if let firmware = try? RazerCommands.firmwareVersion(device) {
            print("Firmware:         \(firmware)")
        } else {
            problems += 1
            print("Firmware:         no reply")
        }
        if let battery = try? RazerCommands.battery(device) {
            print("Battery:          \(battery.percent)%\(battery.charging == true ? " (charging)" : "")")
        } else {
            print("Battery:          unavailable on this link")
        }
        if let polling = try? RazerCommands.pollingRate(device) {
            print("Polling:          \(polling.hz) Hz")
        }
        if let dpi = try? RazerCommands.dpi(device) {
            print("DPI:              \(dpi.x) x \(dpi.y)")
        }
    }

    print("Bluetooth:        \(bluetoothNote(for: control.first?.productId))")
    exit(problems == 0 ? 0 : 1)
}

func bluetoothNote(for productId: Int?) -> String {
    switch productId {
    case 0x00C0, 0x00C1, 0x00DE, 0x00DF:
        return "not available on the Viper V3 Pro; it links over the 2.4 GHz HyperPolling dongle or USB-C only"
    case .some(let pid):
        return "unknown for product 0x\(String(format: "%04X", pid))"
    case .none:
        return "unknown, no Razer device selected"
    }
}

func runBluetooth() {
    print("Bluetooth support")
    print("")
    print("The Viper V3 Pro (1532:00C0 wired, 1532:00C1 dongle) has no Bluetooth radio.")
    print("Razer ships it with two links only: the 2.4 GHz HyperPolling dongle and USB-C.")
    print("There is no pairing mode to enable and no BLE service to talk to on this model.")
    print("")
    print("Razer mice that do support Bluetooth, such as the Cobra Pro or the DeathAdder V2 Pro,")
    print("pair from their underside switch (2.4 GHz / Bluetooth / off) and show a second HID")
    print("interface over Bluetooth instead of 1532:xxxx.")
    if let device = try? openDevice(Options()) {
        print("")
        print("Currently connected: \(RazerDevice.describe(productId: device.productId, productName: device.productName))")
    }
}

func printTable(headers: [String], rows: [[String]]) {
    var widths = headers.map { $0.count }
    for row in rows {
        for (index, cell) in row.enumerated() where index < widths.count {
            widths[index] = max(widths[index], cell.count)
        }
    }
    func line(_ cells: [String]) -> String {
        cells.enumerated()
            .map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }
            .joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
    }
    print(line(headers))
    for row in rows { print(line(row)) }
}

// MARK: - Entry point

var arguments = Array(CommandLine.arguments.dropFirst())
var options = Options()
var positional: [String] = []

var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--json":
        options.json = true
    case "--pid":
        index += 1
        guard index < arguments.count, let pid = parseNumber(arguments[index]) else { fail("--pid needs a number") }
        options.productId = pid
    case "--txid":
        index += 1
        guard index < arguments.count, let txid = parseNumber(arguments[index]) else { fail("--txid needs a number") }
        options.transactionId = UInt8(truncatingIfNeeded: txid)
    case "-h", "--help", "help":
        print(usageText)
        exit(0)
    default:
        positional.append(argument)
    }
    index += 1
}

guard let command = positional.first else {
    print(usageText)
    exit(0)
}

do {
    switch command {
    case "list":
        runList(options: options)
    case "info":
        try runInfo(options: options)
    case "battery":
        try runBattery(options: options)
    case "dpi":
        try runDPI(options: options, argument: positional.count > 1 ? positional[1] : nil)
    case "polling":
        try runPolling(options: options, argument: positional.count > 1 ? positional[1] : nil)
    case "raw":
        try runRaw(options: options, arguments: Array(positional.dropFirst()))
    case "doctor":
        runDoctor(options: options)
    case "bluetooth", "bt":
        runBluetooth()
    default:
        fail("unknown command '\(command)' (try razerctl --help)")
    }
} catch let error as RazerError {
    fail(error.description)
} catch {
    fail("\(error)")
}
