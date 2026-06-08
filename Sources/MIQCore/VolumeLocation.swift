import Foundation

/// Whether a file lives on a local disk or a network mount.
///
/// Uses `statfs(2)`'s `MNT_LOCAL` flag, which is reliable inside the sandboxed
/// Quick Look preview and thumbnail extensions — unlike `URLResourceValues`
/// `.volumeIsLocalKey`, which can return `nil` there (volume metadata is
/// restricted) and silently mislead a caller into the wrong path.
public enum VolumeLocation {
    /// `true` when `url` is on a local volume. Defaults to `true` on a failed
    /// probe so callers keep their local fast path rather than the network one.
    public static func isLocal(_ url: URL) -> Bool {
        var info = statfs()
        let ok = url.withUnsafeFileSystemRepresentation { pointer -> Bool in
            guard let pointer else { return false }
            return statfs(pointer, &info) == 0
        }
        guard ok else { return true }
        return (info.f_flags & UInt32(MNT_LOCAL)) != 0
    }
}
