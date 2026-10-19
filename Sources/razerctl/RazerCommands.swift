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

    /// 0x04/0x85 takes a varstore byte; the Viper V3 Pro answers with NOSTORE, other
    /// models with VARSTORE, so try both.
    static func dpi(_ device: RazerDevice) throws -> DPISetting {
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

    /// 0x04/0x05 with VARSTORE, x and y as big-endian 16-bit values.
    static func setDPI(_ device: RazerDevice, x: Int, y: Int) throws {
        let clampedX = min(max(x, dpiMin), dpiMax)
        let clampedY = min(max(y, dpiMin), dpiMax)
        let request = RazerReport(
            commandClass: 0x04,
            commandId: 0x05,
            dataSize: 0x07,
            arguments: [
                0x01,
                UInt8((clampedX >> 8) & 0xFF), UInt8(clampedX & 0xFF),
                UInt8((clampedY >> 8) & 0xFF), UInt8(clampedY & 0xFF),
                0x00, 0x00,
            ]
        )
        _ = try device.send(request)
    }

    // MARK: - Polling rate

    /// Extended command (0x00/0xC0) covers 125 Hz to 8000 Hz. The standard command
    /// (0x00/0x85) tops out at 1000 Hz and is what wired-only models answer.
    static func pollingRate(_ device: RazerDevice) throws -> PollingSetting {
        if let reply = try? device.send(RazerReport(commandClass: 0x00, commandId: 0xC0, dataSize: 0x01)),
           let hz = pollingRateFromExtended(reply.arguments[1]) {
            return PollingSetting(hz: hz, family: "extended")
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
