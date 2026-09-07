import Darwin
import Foundation
import ZebTraceCore

/// Cooperating app and CLI processes share this lease for inference and take it
/// exclusively before changing model files. Acquisition never blocks the caller.
public final class LocalModelLease: @unchecked Sendable {
    public static let filename = ".model-store.lock"
    private let stateLock = NSLock()
    private var descriptor: Int32

    public init(directory: URL, exclusive: Bool) throws {
        guard directory.isFileURL else {
            throw AnalysisFailure(L10n.string("modelStore.error.modelDirectory"))
        }
        // Anchor openat to the actual directory and reject a Models symlink.
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: directory.path])
        }
        defer { Darwin.close(directoryDescriptor) }
        let opened = openat(directoryDescriptor, Self.filename,
                            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard opened >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: directory.appendingPathComponent(Self.filename).path])
        }
        var info = stat()
        guard fstat(opened, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == 0 else {
            Darwin.close(opened)
            throw AnalysisFailure(L10n.string("modelStore.error.lockFile"))
        }
        guard flock(opened, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(opened)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw AnalysisFailure(L10n.string("modelStore.error.busy"))
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil)
        }
        descriptor = opened
    }

    public func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { close() }
}
