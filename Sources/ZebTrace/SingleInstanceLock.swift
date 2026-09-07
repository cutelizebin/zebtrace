import Darwin
import Foundation

/// The primary lock uses macOS temporary storage. Compatibility locks for older
/// builds exist only while running and are removed on orderly quit/uninstall.
final class SingleInstanceLock {
    private var locks: [(descriptor: Int32, url: URL)] = []

    init(applicationSupportDirectory: URL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]) throws {
        do {
            for name in ["MyContext", "ZebTrace"] {
                let url = applicationSupportDirectory.appendingPathComponent(name).appendingPathComponent(".instance.lock")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try acquire(url, create: true)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("org.zebtrace.app-\(getuid()).lock")
            try acquire(url, create: true)
        } catch {
            // A failed second launch must never unlink the running app's lock.
            releaseLocks(removeFiles: false)
            throw error
        }
    }

    private func acquire(_ url: URL, create: Bool) throws {
        let descriptor = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | (create ? O_CREAT : 0), 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EWOULDBLOCK
            close(descriptor)
            throw POSIXError(code)
        }
        locks.append((descriptor, url))
    }

    /// Called only after capture/inference has stopped during quit/uninstall.
    func prepareForUninstall() { releaseLocks(removeFiles: true) }

    private func releaseLocks(removeFiles: Bool) {
        for lock in locks.reversed() {
            if removeFiles {
                try? FileManager.default.removeItem(at: lock.url)
                if lock.url.lastPathComponent == ".instance.lock" {
                    let parent = lock.url.deletingLastPathComponent()
                    if ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? ["unknown"]).isEmpty {
                        try? FileManager.default.removeItem(at: parent)
                    }
                }
            }
            flock(lock.descriptor, LOCK_UN); close(lock.descriptor)
        }
        locks.removeAll()
    }
    deinit { releaseLocks(removeFiles: true) }
}
