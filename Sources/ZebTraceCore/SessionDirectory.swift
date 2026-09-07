import Darwin
import Foundation

/// Human-readable directory names; the manifest remains the session's identity.
enum SessionDirectory {
    static func create(in root: URL, startedAt: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = formatter.string(from: startedAt)
        let day = root.appendingPathComponent(String(name.prefix(10)), isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        var sequence = 1
        while true {
            let candidate = day.appendingPathComponent(name + suffix(for: sequence), isDirectory: true)
            // mkdir reserves a fresh directory atomically. Existing directories,
            // files, and dangling links all count as collisions, never as ours.
            let result = candidate.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return EINVAL }
                return Darwin.mkdir(path, 0o700) == 0 ? 0 : errno
            }
            if result == 0 { return candidate }
            guard result == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(result),
                              userInfo: [NSFilePathErrorKey: candidate.path])
            }
            sequence += 1
        }
    }

    static func isTimestampName(_ name: String, day: String) -> Bool {
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts[0] == day, isTime(parts[1]) else { return false }
        if parts.count == 3 {
            guard parts[2].utf8.allSatisfy({ (48...57).contains($0) }),
                  let sequence = Int(parts[2]), sequence >= 2,
                  "_" + parts[2] == suffix(for: sequence) else { return false }
        }
        return true
    }

    static func legacyID(from name: String) -> UUID? {
        guard name.count == 45, isTime(name.prefix(8)),
              name[name.index(name.startIndex, offsetBy: 8)] == "-" else { return nil }
        return UUID(uuidString: String(name.suffix(36)))
    }

    private static func suffix(for sequence: Int) -> String {
        sequence == 1 ? "" : (sequence < 10 ? "_0\(sequence)" : "_\(sequence)")
    }

    private static func isTime(_ value: Substring) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ $0.count == 2 && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute),
              let second = Int(parts[2]), (0...59).contains(second) else { return false }
        return true
    }
}
