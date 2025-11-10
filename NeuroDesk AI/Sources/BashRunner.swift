import Foundation

enum BashStream {
    case stdout
    case stderr
}

struct BashChunk {
    let stream: BashStream
    let text: String
}

struct BashRunHandle {
    let stream: AsyncStream<BashChunk>
    let exitCodeTask: Task<Int32, Never>
    let process: Process?
}

enum BashRunner {
    // Use a clean, non-login shell to avoid sourcing /etc/profile and user rc files that can be blocked.
    // If you prefer keeping rc files, switch args to ["-c", command].
    // stdinData: optional data to write to the process stdin immediately after launch (e.g., "password\n" for sudo -S).
    static func run(command: String, timeout: TimeInterval, stdinData: Data? = nil) -> BashRunHandle {
        let process = Process()
        process.launchPath = "/bin/bash"
        process.arguments = ["--noprofile", "--norc", "-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let lock = NSLock()
        var isFinished = false

        let stream = AsyncStream<BashChunk> { continuation in
            func finishIfNeeded() {
                lock.lock()
                defer { lock.unlock() }
                if !isFinished {
                    isFinished = true
                    continuation.finish()
                }
            }

            func installReader(pipe: Pipe, streamType: BashStream) {
                let handle = pipe.fileHandleForReading
                handle.readabilityHandler = { fh in
                    let data = fh.availableData
                    if data.isEmpty {
                        fh.readabilityHandler = nil
                        return
                    }
                    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        continuation.yield(BashChunk(stream: streamType, text: text))
                    }
                }
            }

            installReader(pipe: stdoutPipe, streamType: .stdout)
            installReader(pipe: stderrPipe, streamType: .stderr)

            process.terminationHandler = { _ in
                // Drain any remaining bytes just in case
                let drainOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: drainOut, encoding: .utf8), !text.isEmpty {
                    continuation.yield(BashChunk(stream: .stdout, text: text))
                }
                let drainErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: drainErr, encoding: .utf8), !text.isEmpty {
                    continuation.yield(BashChunk(stream: .stderr, text: text))
                }
                finishIfNeeded()
            }

            do {
                try process.run()
            } catch {
                continuation.yield(BashChunk(stream: .stderr, text: "Failed to start process: \(error.localizedDescription)\n"))
                finishIfNeeded()
                return
            }

            // If we have stdin data to send (e.g., sudo password), write it once then close stdin.
            if let stdinData {
                do {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
                } catch {
                    continuation.yield(BashChunk(stream: .stderr, text: "Failed to write to stdin: \(error.localizedDescription)\n"))
                }
                // Close stdin so processes waiting on EOF can proceed.
                try? stdinPipe.fileHandleForWriting.close()
            } else {
                // Close stdin by default so commands don't hang waiting for input.
                try? stdinPipe.fileHandleForWriting.close()
            }

            if timeout > 0 {
                Task.detached { [weak process] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard let process else { return }
                    if process.isRunning {
                        process.terminate()
                        continuation.yield(BashChunk(stream: .stderr, text: "\n[Process timed out after \(Int(timeout))s]\n"))
                    }
                }
            }
        }

        // Exit code reporting task
        let exitCodeTask = Task<Int32, Never> {
            process.waitUntilExit()
            return process.terminationStatus
        }

        return BashRunHandle(stream: stream, exitCodeTask: exitCodeTask, process: process)
    }
}
