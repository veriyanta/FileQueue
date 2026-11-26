import Darwin
import Foundation

/// Copies one item (file, folder, package or symlink) with `copyfile(3)`, reporting progress
/// and honouring pause/cancel from inside the copy. APFS clones are used when possible.
final class Copier: @unchecked Sendable {
    private let control: JobControl
    private let onProgress: (_ bytes: Int64, _ files: Int) -> Void
    private var finishedBytes: Int64 = 0
    private var finishedFiles = 0
    private var currentFileBytes: Int64 = 0

    init(control: JobControl, onProgress: @escaping (_ bytes: Int64, _ files: Int) -> Void) {
        self.control = control
        self.onProgress = onProgress
    }

    /// `destination` must not exist. On failure or cancel the caller removes any partial copy.
    func copy(from source: URL, to destination: URL) throws {
        guard let state = copyfile_state_alloc() else { throw FQError.posix(ENOMEM, source.path) }
        defer { copyfile_state_free(state) }

        let callback: copyfile_callback_t = copierCallback
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(self).toOpaque())

        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)
        if !FS.isDirectory(source) { flags |= copyfile_flags_t(COPYFILE_CLONE) }

        let result = withExtendedLifetime(self) { copyfile(source.path, destination.path, state, flags) }
        if result != 0 {
            let code = errno
            if control.isCancelled || code == ECANCELED { throw CancellationError() }
            throw FQError.posix(code, source.path)
        }
    }

    fileprivate func handle(what: Int32, stage: Int32, state: copyfile_state_t?, src: UnsafePointer<CChar>?) -> Int32 {
        guard control.blockingCheckpoint() else { return COPYFILE_QUIT }
        switch (what, stage) {
        case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            currentFileBytes = Int64(copied)
            onProgress(finishedBytes + currentFileBytes, finishedFiles)
        case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
            var st = stat()
            if let src, lstat(src, &st) == 0 { finishedBytes += Int64(st.st_size) }
            finishedFiles += 1
            currentFileBytes = 0
            onProgress(finishedBytes, finishedFiles)
        case (COPYFILE_RECURSE_ERROR, _), (_, COPYFILE_ERR):
            return COPYFILE_QUIT
        default:
            break
        }
        return COPYFILE_CONTINUE
    }
}

private func copierCallback(
    what: Int32, stage: Int32, state: copyfile_state_t?,
    src: UnsafePointer<CChar>?, dst: UnsafePointer<CChar>?, ctx: UnsafeMutableRawPointer?
) -> Int32 {
    guard let ctx else { return COPYFILE_CONTINUE }
    let copier = Unmanaged<Copier>.fromOpaque(ctx).takeUnretainedValue()
    return copier.handle(what: what, stage: stage, state: state, src: src)
}
