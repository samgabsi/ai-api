import Foundation

enum BashStream {
    case stdout
    case stderr
}

struct BashChunk {
    let stream: BashStream
    let text: String
}

enum BashRunner {
    static func run(command: String, timeout: TimeInterval) -> (AsyncStream<BashChunk>, Process?) {
        let process = Process()
        process.launchPath = "/bin/bash"
        process.arguments = ["-lc", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

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

            // Read handler for a pipe
            func installReader(pipe: Pipe, streamType: BashStream) {
                let handle = pipe.fileHandleForReading
                handle.readabilityHandler = { fh in
                    let data = fh.availableData
                    if data.isEmpty {
                        // EOF on this pipe
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

            // Termination handler
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

            // Start the process
            do {
                try process.run()
            } catch {
                continuation.yield(BashChunk(stream: .stderr, text: "Failed to start process: \(error.localizedDescription)\n"))
                finishIfNeeded()
                return
            }

            // Timeout
            if timeout > 0 {
                Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if process.isRunning {
                        process.terminate()
                        continuation.yield(BashChunk(stream: .stderr, text: "\n[Process timed out after \(Int(timeout))s]\n"))
                    }
                }
            }
        }

        return (stream, process)
    }
}
