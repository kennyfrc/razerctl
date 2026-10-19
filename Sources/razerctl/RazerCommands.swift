import Foundation

struct BatteryReading {
    let raw: Int
    let percent: Int
    let charging: Bool?
}

struct DPISetting {
    let x: Int
    let y: Int
}

struct PollingSetting {
    let hz: Int
    /// Which command family answered: "extended" (0x00/0xC0) or "standard" (0x00/0x85).
    let family: String
}

/// Command builders and parsers, ported from OpenRazer.
/// Reference: driver/razerchromacommon.c and driver/razermouse_driver.c.
enum RazerCommands {
    static let dpiMax = 35_000
    static let dpiMin = 100

    // MARK: - Identity

    static func firmwareVersion(_ device: RazerDevice) throws -> String {
        let reply = try device.send(RazerReport(commandClass: 0x00, commandId: 0x81, dataSize: 0x02))
        return "v\(reply.arguments[0]).\(reply.arguments[1])"
    }

    static func serialNumber(_ device: RazerDevice) throws -> String? {
        let reply = try device.send(RazerReport(commandClass: 0x00, commandId: 0x82, dataSize: 0x16))
        let bytes = reply.arguments.prefix(22).prefix { $0 != 0x00 }
        let text = String(decoding: bytes, as: UTF8.self).filter { $0.isLetter || $0.isNumber }
        guard text.count >= 4, Set(text).count > 1 else { return nil }
        return text
    }

    // MARK: - Battery

    /// 0x07/0x80 reply carries the level in arguments[1] on a 0-255 scale.
    static func battery(_ device: RazerDevice) throws -> BatteryReading {
        let reply = try device.send(RazerReport(commandClass: 0x07, commandId: 0x80, dataSize: 0x02))
        let raw = Int(reply.arguments[1])
        return BatteryReading(
            raw: raw,
            percent: Int((Double(raw) * 100.0 / 255.0).rounded()),
            charging: try? isCharging(device)
        )
    }

    /// 0x07/0x84 reply arguments[0] is 1 while charging.
    static func isCharging(_ device: RazerDevice) throws -> Bool {
        let reply = try device.send(RazerReport(commandClass: 0x07, commandId: 0x84, dataSize: 0x02))
        return reply.arguments[0] != 0
    }

    // MARK: - DPI

    /// The mouse runs a stage list, not a single DPI value. The active stage decides the
    /// real sensitivity; the single-value register can disagree with it, which makes the
    /// mouse feel slower than the number the CLI reports.
    struct DPIStages {
        var active: Int
        var values: [Int]
    }

    static func dpiStages(_ device: RazerDevice) throws -> DPIStages {
        let reply = try device.send(
            RazerReport(commandClass: 0x04, commandId: 0x86, dataSize: 0x26, arguments: [0x01])
        )
        let active = Int(reply.arguments[1])
        let count = Int(reply.arguments[2])
        var values: [Int] = []
        var offset = 3
        for _ in 0..<max(0, count) where offset + 4 < RazerReport.argumentCount {
            let x = (Int(reply.arguments[offset + 1]) << 8) | Int(reply.arguments[offset + 2])
            values.append(x)
            offset += 7
        }
        guard !values.isEmpty else { throw RazerError.deviceFailure }
        return DPIStages(active: active, values: values)
    }

    static func writeDPIStages(_ device: RazerDevice, active: Int, values: [Int]) throws {
        var arguments: [UInt8] = [
            0x01,
            UInt8(truncatingIfNeeded: active),
            UInt8(truncatingIfNeeded: values.count),
        ]
        for (index, value) in values.enumerated() {
            arguments.append(UInt8(truncatingIfNeeded: index))
            arguments.append(UInt8((value >> 8) & 0xFF))
            arguments.append(UInt8(value & 0xFF))
            arguments.append(UInt8((value >> 8) & 0xFF))
            arguments.append(UInt8(value & 0xFF))
            arguments.append(0x00)
            arguments.append(0x00)
        }
        let request = RazerReport(
            commandClass: 0x04,
            commandId: 0x06,
            dataSize: 0x26,
            arguments: arguments
        )
        _ = try device.send(request)
    }

    /// Effective DPI: the value of the active stage. Falls back to the single-value
    /// register on models that do not expose stages.
    static func dpi(_ device: RazerDevice) throws -> DPISetting {
        if let stages = try? dpiStages(device),
           stages.active >= 1, stages.active <= stages.values.count {
            let value = stages.values[stages.active - 1]
            if value > 0 { return DPISetting(x: value, y: value) }
        }
        for store: UInt8 in [0x01, 0x00] {
            guard let reply = try? device.send(
                RazerReport(commandClass: 0x04, commandId: 0x85, dataSize: 0x07, arguments: [store])
            ) else { continue }
            let x = (Int(reply.arguments[1]) << 8) | Int(reply.arguments[2])
            let y = (Int(reply.arguments[3]) << 8) | Int(reply.arguments[4])
            if x > 0, y > 0 { return DPISetting(x: x, y: y) }
        }
        throw RazerError.deviceFailure
    }

    /// Sets the real DPI: reuses a stage that already holds the value, or overwrites the
    /// active stage and keeps it active. Writing the single-value register alone does not
    /// change which stage is active, so the mouse can keep running at the old sensitivity.
    static func setDPI(_ device: RazerDevice, x: Int, y: Int) throws {
        let target = min(max(x, dpiMin), dpiMax)
        guard var stages = try? dpiStages(device) else {
            try setDPISingle(device, value: target)
            return
        }
        if let index = stages.values.firstIndex(of: target) {
            stages.active = index + 1
        } else {
            let index = min(max(stages.active - 1, 0), stages.values.count - 1)
            stages.values[index] = target
            stages.active = index + 1
        }
        do {
            try writeDPIStages(device, active: stages.active, values: stages.values)
        } catch {
            try setDPISingle(device, value: target)
        }
    }

    static func setDPISingle(_ device: RazerDevice, value: Int) throws {
        let request = RazerReport(
            commandClass: 0x04,
            commandId: 0x05,
            dataSize: 0x07,
            arguments: [
                0x00,
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
                0x00, 0x00,
            ]
        )
        _ = try device.send(request)
    }

    // MARK: - Polling rate

    /// Extended command (0x00/0xC0) covers 125 Hz to 8000 Hz. The standard command
    /// (0x00/0x85) tops out at 1000 Hz and is what wired-only models answer.
    static func pollingRate(_ device: RazerDevice) throws -> PollingSetting {
        // The dongle can answer BUSY right after a settings write, so give this read a
        // second chance before falling back to the standard command.
        for attempt in 0..<2 {
            if let reply = try? device.send(RazerReport(commandClass: 0x00, commandId: 0xC0, dataSize: 0x01)),
               let hz = pollingRateFromExtended(reply.arguments[1]) {
                return PollingSetting(hz: hz, family: "extended")
            }
            if attempt == 0 { usleep(120_000) }
        }
        if let reply = try? device.send(RazerReport(commandClass: 0x00, commandId: 0x85, dataSize: 0x01)),
           let hz = pollingRateFromStandard(reply.arguments[0]) {
            return PollingSetting(hz: hz, family: "standard")
        }
        throw RazerError.notSupported
    }

    static func setPollingRate(_ device: RazerDevice, hz: Int) throws {
        if let mask = extendedMask(for: hz) {
            let request = RazerReport(
                commandClass: 0x00,
                commandId: 0x40,
                dataSize: 0x02,
                arguments: [0x00, mask]
            )
            if (try? device.send(request)) != nil { return }
        }
        guard let mask = standardMask(for: hz) else { throw RazerError.notSupported }
        let request = RazerReport(commandClass: 0x00, commandId: 0x05, dataSize: 0x01, arguments: [mask])
        _ = try device.send(request)
    }

    static let supportedRates = [125, 250, 500, 1000, 2000, 4000, 8000]

    // MARK: - Dongle pairing

    /// Puts the HyperPolling dongle into pairing mode, then binds it to a mouse product id.
    /// Ported from razer_attr_write_hyperpolling_wireless_dongle_pair(). Only needed when
    /// the dongle lost its factory pairing; a new mouse and dongle already match.
    static func pairDongle(_ device: RazerDevice, mouseProductId: Int = 0x00C0) throws {
        _ = try device.send(
            RazerReport(commandClass: 0x00, commandId: 0x46, dataSize: 0x01, arguments: [0x01])
        )
        _ = try device.send(
            RazerReport(
                commandClass: 0x00,
                commandId: 0x41,
                dataSize: 0x03,
                arguments: [
                    0x01,
                    UInt8((mouseProductId >> 8) & 0xFF),
                    UInt8(mouseProductId & 0xFF),
                ]
            )
        )
    }

    static func extendedMask(for hz: Int) -> UInt8? {
        switch hz {
        case 8000: return 0x01
        case 4000: return 0x02
        case 2000: return 0x04
        case 1000: return 0x08
        case 500: return 0x10
        case 250: return 0x20
        case 125: return 0x40
        default: return nil
        }
    }

    static func standardMask(for hz: Int) -> UInt8? {
        switch hz {
        case 1000: return 0x01
        case 500: return 0x02
        case 125: return 0x08
        default: return nil
        }
    }

    static func pollingRateFromExtended(_ mask: UInt8) -> Int? {
        switch mask {
        case 0x01: return 8000
        case 0x02: return 4000
        case 0x04: return 2000
        case 0x08: return 1000
        case 0x10: return 500
        case 0x20: return 250
        case 0x40: return 125
        default: return nil
        }
    }

    static func pollingRateFromStandard(_ mask: UInt8) -> Int? {
        switch mask {
        case 0x01: return 1000
        case 0x02: return 500
        case 0x08: return 125
        default: return nil
        }
    }
}
