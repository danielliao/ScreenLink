import Foundation
import Darwin

// All path components are opened without following links. Retain directory descriptors
// throughout reception so a renamed directory cannot redirect publication or cleanup.
private func sharingDirectory(_ url: URL) throws -> Int32 {
    guard url.isFileURL, url.path.hasPrefix("/") else { throw SharingError.filesystem }
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw SharingError.filesystem }
    for component in url.path.split(separator: "/") {
        guard component != "..", component != ".", !component.utf8.contains(0) else { Darwin.close(fd); throw SharingError.filesystem }
        let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        Darwin.close(fd)
        guard next >= 0 else { throw SharingError.filesystem }
        fd = next
    }
    return fd
}

func sharingSource(_ url: URL) throws -> (FileHandle, Int64) {
    guard url.isFileURL, !url.lastPathComponent.utf8.contains(0) else { throw SharingError.filesystem }
    let directory = try sharingDirectory(url.deletingLastPathComponent())
    defer { Darwin.close(directory) }
    let fd = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw SharingError.filesystem }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 2_147_483_648 else {
        Darwin.close(fd); throw SharingError.filesystem
    }
    return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), info.st_size)
}

/// Private staging directory plus descriptor-relative publication: replacing or renaming
/// its visible directory entry cannot substitute a symlink or different file at commit.
public final class SharingFileSink {
    private let directory: Int32
    private let staging: Int32
    private var file: FileHandle?
    private var temporary: String?
    private let destination: URL
    private let name: String
    public init(directory url: URL, name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 200,
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SharingError.invalid }
        let parent = try sharingDirectory(url)
        let temp = ".screenlink-\(UUID().uuidString).partial"
        guard mkdirat(parent, temp, S_IRWXU) == 0 else { Darwin.close(parent); throw SharingError.filesystem }
        let child = openat(parent, temp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard child >= 0, fstat(child, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            if child >= 0 { Darwin.close(child) }
            _ = unlinkat(parent, temp, AT_REMOVEDIR); Darwin.close(parent); throw SharingError.filesystem
        }
        let fd = openat(child, "content", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            Darwin.close(child); _ = unlinkat(parent, temp, AT_REMOVEDIR); Darwin.close(parent); throw SharingError.filesystem
        }
        directory = parent; staging = child; destination = url; self.name = name
        temporary = temp; file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    deinit { abort(); Darwin.close(staging); Darwin.close(directory) }
    public func append(_ bytes: Data) throws {
        guard let file else { throw SharingError.filesystem }
        try file.write(contentsOf: bytes)
    }
    public func abort() {
        try? file?.close(); file = nil
        if temporary != nil { _ = unlinkat(staging, "content", 0); removeStagingDirectory() }
    }
    private func removeStagingDirectory() {
        guard let temp = temporary else { return }
        var held = stat(), visible = stat()
        if fstat(staging, &held) == 0, fstatat(directory, temp, &visible, AT_SYMLINK_NOFOLLOW) == 0,
           held.st_dev == visible.st_dev, held.st_ino == visible.st_ino {
            _ = unlinkat(directory, temp, AT_REMOVEDIR)
        }
        temporary = nil
    }
    public func finish() throws -> URL {
        guard let file, temporary != nil else { throw SharingError.filesystem }
        let quarantine = Data("0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));ScreenLink;\(UUID().uuidString)".utf8)
        let marked = quarantine.withUnsafeBytes { fsetxattr(file.fileDescriptor, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
        guard marked == 0, fsync(file.fileDescriptor) == 0 else { throw SharingError.filesystem }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for index in 0..<10_000 {
            let candidate = index == 0 ? name : "\(base) (\(index))" + (ext.isEmpty ? "" : ".\(ext)")
            if renameatx_np(staging, "content", directory, candidate, UInt32(RENAME_EXCL)) == 0 {
                try? file.close(); self.file = nil; removeStagingDirectory()
                return destination.appendingPathComponent(candidate)
            }
            guard errno == EEXIST else { throw SharingError.filesystem }
        }
        throw SharingError.limit
    }
}
