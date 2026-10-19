import Foundation
import IOKit
import IOKit.hid

/// One HID interface exposed by a Razer device. A mouse usually shows several
/// (pointer, consumer control, and the 90-byte control interface we need).
struct HIDInterface {
    let device: IOHIDDevice
    let productId: Int
    let productName: String
    let locationId: Int
    let usagePage: Int
    let usage: Int
    let maxFeatureReportSize: Int
}

enum RazerError: Error, CustomStringConvertible {
    case permissionDenied
    case deviceNotFound
    case openFailed(IOReturn)
    case setReportFailed(IOReturn)
    case getReportFailed(IOReturn)
    case badReply
    case busy
    case deviceFailure
    case notSupported

    var description: String {
        func hex(_ value: IOReturn) -> String { String(format: "0x%08X", UInt32(bitPattern: value)) }
        switch self {
        case .permissionDenied:
            return """
            Input Monitoring permission is missing for this process.
            macOS blocks opening a mouse or keyboard HID interface until the app that
            launched this command has that permission.

              1. Run: razerctl doctor
              2. Open System Settings > Privacy & Security > Input Monitoring
              3. Enable the app that runs your shell (Terminal, iTerm, Paseo, ...)
              4. Quit and reopen that app, then retry
            """
        case .deviceNotFound:
            return "No Razer device found. Plug in the cable or the 2.4 GHz dongle."
        case .openFailed(let code):
            return "IOHIDDeviceOpen failed: \(hex(code))"
        case .setReportFailed(let code):
            return "Sending the command failed: \(hex(code))"
        case .getReportFailed(let code):
            return "Reading the reply failed: \(hex(code))"
        case .badReply:
            return "The device sent a malformed or stale reply."
        case .busy:
            return "The device stayed busy and never answered."
        case .deviceFailure:
            return "The device rejected the command (status 0x03)."
        case .notSupported:
            return "The device reports this command as not supported (status 0x05)."
        }
    }
}

/// Input Monitoring state, as reported by IOKit.
enum HIDAccess {
    static var state: IOHIDAccessType { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) }

    static var isGranted: Bool { state == kIOHIDAccessTypeGranted }

    static var label: String {
        if state == kIOHIDAccessTypeGranted { return "granted" }
        if state == kIOHIDAccessTypeDenied { return "denied" }
        return "not asked yet"
    }

    /// Asks the system to show the permission prompt. Only works once per app.
    static func request() -> Bool {
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}

/// Talks to a Razer mouse over USB HID feature reports.
///
/// Razer's protocol is request/response: write a 90-byte feature report, wait for the
/// receiver to process it, then read a 90-byte feature report back. This is the same
/// conversation OpenRazer has over USB control transfers.
final class RazerDevice {
    /// OpenRazer's RAZER_VIPER_MOUSE_RECEIVER_WAIT_US. Shorter waits return status BUSY.
    static let replyWaitMicroseconds: useconds_t = 31_000

    let device: IOHIDDevice
    let productId: Int
    let productName: String
    let locationId: Int
    var transactionId: UInt8

    private init(interface: HIDInterface, transactionId: UInt8) {
        self.device = interface.device
        self.productId = interface.productId
        self.productName = interface.productName
        self.locationId = interface.locationId
        self.transactionId = transactionId
    }

    /// Product id to (model, link) for the models this repo has been checked against.
    static let knownModels: [Int: (name: String, link: String)] = [
        0x00C0: ("Razer Viper V3 Pro", "wired"),
        0x00C1: ("Razer Viper V3 Pro", "2.4 GHz dongle"),
        0x00DE: ("Razer Viper V3 Pro SE", "wired"),
        0x00DF: ("Razer Viper V3 Pro SE", "2.4 GHz dongle"),
        0x00B8: ("Razer Viper V3 HyperSpeed", "2.4 GHz dongle"),
        0x00DA: ("Razer Cobra HyperSpeed", "wired"),
        0x00DB: ("Razer Cobra HyperSpeed", "2.4 GHz dongle"),
    ]

    static func describe(productId: Int, productName: String) -> String {
        guard let known = knownModels[productId] else { return productName }
        return "\(known.name) (\(known.link))"
    }

    /// Every HID interface on the bus whose vendor id is Razer's (0x1532).
    static func interfaces() -> [HIDInterface] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1532] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }

        func int(_ device: IOHIDDevice, _ key: String) -> Int {
            (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
        }
        return devices.map { device in
            HIDInterface(
                device: device,
                productId: int(device, kIOHIDProductIDKey),
                productName: (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Razer device",
                locationId: int(device, kIOHIDLocationIDKey),
                usagePage: int(device, kIOHIDPrimaryUsagePageKey),
                usage: int(device, kIOHIDPrimaryUsageKey),
                maxFeatureReportSize: int(device, kIOHIDMaxFeatureReportSizeKey)
            )
        }
        .sorted { ($0.locationId, $0.usagePage, $0.usage) < ($1.locationId, $1.usagePage, $1.usage) }
    }

    /// Interfaces able to carry the 90-byte control report. On the Viper V3 Pro that is
    /// the mouse interface (usage 0x01/0x02); the others top out at 1 byte.
    static func controlInterfaces() -> [HIDInterface] {
        interfaces().filter { $0.maxFeatureReportSize >= RazerReport.wireSize }
    }

    /// Opens the control interface, preferring a specific product id when given.
    static func open(productId wanted: Int? = nil) throws -> RazerDevice {
        guard HIDAccess.isGranted else {
            _ = HIDAccess.request()
            throw RazerError.permissionDenied
        }
        let candidates = controlInterfaces()
        guard !candidates.isEmpty else { throw RazerError.deviceNotFound }
        let chosen = candidates.first { $0.productId == wanted } ?? candidates[0]

        let result = IOHIDDeviceOpen(chosen.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            if result == kIOReturnNotPermitted { throw RazerError.permissionDenied }
            throw RazerError.openFailed(result)
        }
        return RazerDevice(interface: chosen, transactionId: transactionId(for: chosen.productId))
    }

    /// Transaction id byte OpenRazer stamps on this model's ordinary commands.
    /// Viper V3 Pro, Viper V3 HyperSpeed, Cobra, and most current mice answer to 0x1f.
    static func transactionId(for productId: Int) -> UInt8 {
        switch productId {
        case 0x00C0, 0x00C1, 0x00DE, 0x00DF, 0x00DA, 0x00DB, 0x00B8:
            return 0x1f
        default:
            return 0x1f
        }
    }

    /// Sends one request and returns the device's reply.
    func send(_ request: RazerReport, transactionId override: UInt8? = nil) throws -> RazerReport {
        var request = request
        request.transactionId = override ?? transactionId
        let outgoing = request.serialized()

        let setResult = outgoing.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, outgoing.count)
        }
        guard setResult == kIOReturnSuccess else { throw RazerError.setReportFailed(setResult) }

        usleep(RazerDevice.replyWaitMicroseconds)

        var lastError = RazerError.badReply
        for attempt in 0..<5 {
            var reply = [UInt8](repeating: 0x00, count: RazerReport.wireSize)
            var length = reply.count
            let getResult = reply.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, &length)
            }
            guard getResult == kIOReturnSuccess else { throw RazerError.getReportFailed(getResult) }

            // A short read parses as an all-zero reply: not ready yet, read again.
            if length == RazerReport.wireSize,
               let parsed = RazerReport.parse(reply),
               parsed.isReply(to: request) {
                switch RazerStatus(rawValue: parsed.status) {
                case .busy:
                    lastError = .busy
                case .timeout:
                    throw RazerError.badReply
                case .failure:
                    throw RazerError.deviceFailure
                case .notSupported:
                    throw RazerError.notSupported
                default:
                    return parsed
                }
            }
            if attempt < 4 {
                usleep(RazerDevice.replyWaitMicroseconds * useconds_t(attempt + 1))
            }
        }
        throw lastError
    }
}
