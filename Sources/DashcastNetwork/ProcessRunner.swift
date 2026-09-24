import Foundation

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool

    /// stdout + stderr, trimmed to the last `maxLines` lines. For error messages.
    func tail(_ maxLines: Int = 25) -> String {
        let combined = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines).joined(separator: "\n")
    }
}

/// Thread-safe box for values filled in from background queues.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Runs a child process off the main thread and collects its output.
enum ProcessRunner {
    static func run(_ executable: String,
                    _ arguments: [String],
                    environment: [String: String]? = nil,
                    stdin: Data? = nil,
                    timeout: TimeInterval = 120) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                let inPipe: Pipe? = stdin == nil ? nil : Pipe()
                process.standardInput = inPipe ?? FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let timedOut = LockedBox(false)
                let killer = DispatchWorkItem {
                    if process.isRunning {
                        timedOut.value = true
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                if let stdin, let inPipe {
                    let writer = inPipe.fileHandleForWriting
                    // A child that exits early must not SIGPIPE the app.
                    _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                    DispatchQueue.global().async {
                        try? writer.write(contentsOf: stdin)
                        try? writer.close()
                    }
                }

                let out = LockedBox(Data())
                let err = LockedBox(Data())
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    out.value = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    err.value = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                process.waitUntilExit()
                group.wait()
                killer.cancel()

                continuation.resume(returning: ProcessResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: out.value, as: UTF8.self),
                    stderr: String(decoding: err.value, as: UTF8.self),
                    timedOut: timedOut.value))
            }
        }
    }
}
