import Foundation

/// One HID device, one talker at a time.
///
/// The mouse answers on a single feature-report queue. When the agent and a CLI command both
/// open it, the second one reads the reply meant for the first, and every answer after that is
/// off by one: "the device sent a malformed or stale reply" for every command, including ones
/// that worked minutes earlier. A file lock serialises them.
final class DeviceLock {
    private let fd: Int32

    private static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/razerctl/device.lock").path

    private init(fd: Int32) { self.fd = fd }

    /// Waits up to timeoutMs for the device, then gives up. Nil means it stayed busy.
    static func acquire(timeoutMs: Int = 2000) -> DeviceLock? {
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return DeviceLock(fd: fd) }
            if Date() >= deadline { close(fd); return nil }
            usleep(20_000)
        }
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
