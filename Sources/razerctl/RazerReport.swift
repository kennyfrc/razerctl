import Foundation

/// A Razer control message, 90 bytes on the wire.
/// Layout comes from OpenRazer's `struct razer_report` (driver/razercommon.h):
///
///   [0]      status
///   [1]      transaction id
///   [2..3]   remaining packets (big endian)
///   [4]      protocol type (always 0x00)
///   [5]      data size
///   [6]      command class
///   [7]      command id
///   [8..87]  arguments
///   [88]     crc (xor of bytes 2..87)
///   [89]     reserved
struct RazerReport {
    static let wireSize = 90
    static let argumentCount = 80

    var status: UInt8 = 0x00
    var transactionId: UInt8 = 0x1f
    var protocolType: UInt8 = 0x00
    var dataSize: UInt8 = 0x00
    var commandClass: UInt8 = 0x00
    var commandId: UInt8 = 0x00
    var arguments = [UInt8](repeating: 0x00, count: RazerReport.argumentCount)

    init(commandClass: UInt8, commandId: UInt8, dataSize: UInt8, arguments: [UInt8] = []) {
        self.commandClass = commandClass
        self.commandId = commandId
        self.dataSize = dataSize
        for (index, byte) in arguments.enumerated() where index < RazerReport.argumentCount {
            self.arguments[index] = byte
        }
    }

    /// Packs the report into the 90-byte buffer, computing the checksum.
    func serialized() -> [UInt8] {
        var buffer = [UInt8](repeating: 0x00, count: RazerReport.wireSize)
        buffer[0] = status
        buffer[1] = transactionId
        buffer[2] = 0x00
        buffer[3] = 0x00
        buffer[4] = protocolType
        buffer[5] = dataSize
        buffer[6] = commandClass
        buffer[7] = commandId
        for index in 0..<RazerReport.argumentCount {
            buffer[8 + index] = arguments[index]
        }
        buffer[88] = RazerReport.checksum(buffer)
        return buffer
    }

    /// Parses a 90-byte reply. Returns nil for short buffers.
    static func parse(_ buffer: [UInt8]) -> RazerReport? {
        guard buffer.count >= wireSize else { return nil }
        var report = RazerReport(commandClass: buffer[6], commandId: buffer[7], dataSize: buffer[5])
        report.status = buffer[0]
        report.transactionId = buffer[1]
        report.protocolType = buffer[4]
        report.arguments = Array(buffer[8..<88])
        return report
    }

    /// xor of bytes 2..87, matching razer_calculate_crc().
    static func checksum(_ buffer: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for index in 2..<88 where index < buffer.count {
            crc ^= buffer[index]
        }
        return crc
    }

    /// Whether a reply belongs to this request. A stale reply echoes another command.
    func isReply(to other: RazerReport) -> Bool {
        commandClass == other.commandClass && commandId == other.commandId
    }

    /// Arguments as an uppercase hex string, for the `raw` command.
    var argumentsHex: String {
        arguments.prefix(Int(dataSize)).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// Reply status codes (razercommon.h "Report Responses").
enum RazerStatus: UInt8 {
    case busy = 0x01
    case successful = 0x02
    case failure = 0x03
    case timeout = 0x04
    case notSupported = 0x05

    var label: String {
        switch self {
        case .busy: return "busy"
        case .successful: return "ok"
        case .failure: return "failed"
        case .timeout: return "timeout"
        case .notSupported: return "not supported"
        }
    }
}
