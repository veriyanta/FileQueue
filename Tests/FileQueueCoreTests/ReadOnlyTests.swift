import Foundation
import Testing
@testable import FileQueueCore

@Suite("Read-only disks", .serialized)
struct ReadOnlyTests {
    /// Mounts a small disk image read-only, like macOS mounts NTFS disks.
    func readOnlyImage(with files: [String]) -> (DiskImage, URL)? {
        guard let image = DiskImage(caseSensitive: false, sizeMB: 32) else { return nil }
        for f in files { try? Data("x".utf8).write(to: image.mountPoint.appendingPathComponent(f)) }
        let mount = image.mountPoint
        // Detach the whole image (not just unmount its volume), or the first attachment stays behind
        // with nothing mounted — one leftover "FQTEST" disk in Disk Utility per test run.
        _ = DiskImage.run(["detach", "-quiet", "-force", mount.path])
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard DiskImage.run(["attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mount.path, image.imagePath]) else {
            image.detach(); return nil
        }
        return (image, mount)
    }

    @Test("Impossible jobs on a read-only disk are refused before anything is copied")
    func refusedUpFront() async throws {
        guard let (image, ro) = readOnlyImage(with: ["photo.jpg"]) else { return }
        defer { image.detach() }
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("local.txt")
        let engine = await s.engine()
        let photo = ro.appendingPathComponent("photo.jpg")

        #expect(try SystemDiskResolver().disk(for: ro).isReadOnly)
        #expect(FS.isOnReadOnlyFileSystem(photo))

        // Move off it: refused immediately, with a suggestion.
        do {
            try await engine.enqueue(.move(sources: [photo], destinationDir: s.root))
            Issue.record("move should be refused")
        } catch let error as FQError {
            #expect(error.localizedDescription.contains("read-only"))
            #expect(error.localizedDescription.contains("Use Copy instead"))
        }
        await #expect(throws: FQError.self) { try await engine.enqueue(.copy(sources: [s.path("local.txt")], destinationDir: ro)) }
        await #expect(throws: FQError.self) { try await engine.enqueue(.rename(source: photo, newName: "p.jpg")) }
        await #expect(throws: FQError.self) { try await engine.enqueue(.trash(sources: [photo])) }
        #expect(await engine.jobs.isEmpty) // nothing was queued

        // Copying off a read-only disk is fine.
        try await engine.enqueue(.copy(sources: [photo], destinationDir: s.root))
        await engine.waitUntilIdle()
        #expect(s.exists("photo.jpg"))
    }

    @Test("Writable places on the read-only system volume are not flagged")
    func systemVolume() throws {
        #expect(!FS.isOnReadOnlyFileSystem(URL(fileURLWithPath: "/Applications")))
        #expect(!FS.isOnReadOnlyFileSystem(FileManager.default.homeDirectoryForCurrentUser))
        #expect(!FS.isOnReadOnlyFileSystem(FileManager.default.temporaryDirectory))
    }

    @Test("Jobs saved before read-only tracking still load")
    func oldDiskJSON() throws {
        let json = #"{"id":{"rawValue":"bsd:disk3"},"name":"HD","volumePath":"/","isCaseSensitive":false}"#
        let disk = try JSONDecoder().decode(DiskInfo.self, from: Data(json.utf8))
        #expect(disk.isReadOnly == false)
        #expect(disk.fileSystem == nil)
    }
}
