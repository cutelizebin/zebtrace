import Darwin
import Foundation

final class SingleInstanceLock {
    private var descriptors: [Int32] = []

    init(applicationSupportDirectory: URL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]) throws {
        do {
            // Always acquire the old lock first so MyContext and ZebTrace cannot record together.
            for name in ["MyContext", "ZebTrace"] {
                try acquire(at: applicationSupportDirectory.appendingPathComponent(name, isDirectory: true))
            }
        } catch {
            releaseLocks()
            throw error
        }
    }

    private func acquire(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent(".instance.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EWOULDBLOCK
            close(descriptor)
            throw POSIXError(code)
        }
        descriptors.append(descriptor)
    }

    private func releaseLocks() {
        for descriptor in descriptors.reversed() {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        descriptors.removeAll()
    }

    deinit { releaseLocks() }
}
