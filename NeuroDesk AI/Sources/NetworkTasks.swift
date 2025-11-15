import Foundation

/// Represents the result of a port scan operation.
public struct PortScanResult {
    /// The host that was scanned.
    public let host: String
    /// The standard output collected from the scan command.
    public let stdout: String
    /// The standard error collected from the scan command.
    public let stderr: String
    /// The exit code returned by the scan command.
    public let exitCode: Int32
}

/// Namespace for network-related tasks using BashRunner utilities.
public enum NetworkTasks {
    /// Performs an `nmap` port scan on the specified host.
    ///
    /// The function runs the command `nmap -sV -Pn <host>` asynchronously,
    /// collecting the standard output and standard error streams as they arrive.
    /// If the `nmap` command is not found, it appends a helpful hint to stderr
    /// about installing `nmap` via Homebrew on macOS.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address to scan.
    ///   - timeout: The timeout interval for running the scan command (default 60 seconds).
    /// - Returns: A `PortScanResult` containing the stdout, stderr, exit code, and host.
    public static func scanHost(_ host: String, timeout: TimeInterval = 60) async -> PortScanResult {
        let command = "nmap -sV -Pn \(host)"
        
        var stdoutBuilder = ""
        var stderrBuilder = ""
        
        let (stream, exitCodeTask) = BashRunner.run(command: command, timeout: timeout, stdinData: nil)
        
        for await output in stream {
            switch output {
            case .stdout(let string):
                stdoutBuilder.append(string)
            case .stderr(let string):
                stderrBuilder.append(string)
            }
        }
        
        let exitCode = await exitCodeTask
        
        // Detect if 'nmap' was not found
        let nmapNotFound =
            exitCode == 127 ||
            stderrBuilder.localizedCaseInsensitiveContains("command not found")
        
        if nmapNotFound {
            var hint = "\n\nHint: `nmap` is not installed or not found in PATH."
            #if os(macOS)
            hint += " You can install it using Homebrew:\n  brew install nmap\n"
            #endif
            stderrBuilder.append(hint)
        }
        
        return PortScanResult(host: host, stdout: stdoutBuilder, stderr: stderrBuilder, exitCode: exitCode)
    }
    
    /// Checks if the `nmap` tool is available on the system by running `command -v nmap`.
    ///
    /// - Parameter timeout: The timeout interval for the check command (default 10 seconds).
    /// - Returns: `true` if `nmap` is found and executable; `false` otherwise.
    public static func isNmapAvailable(timeout: TimeInterval = 10) async -> Bool {
        let command = "command -v nmap"
        let (_, exitCodeTask) = BashRunner.run(command: command, timeout: timeout, stdinData: nil)
        let exitCode = await exitCodeTask
        return exitCode == 0
    }
}
