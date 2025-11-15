import Foundation

/// A structure representing the result of executing a Bash query.
public struct BashQueryResult {
    /// The original query string requested.
    public let requested: String
    /// The actual Bash command executed.
    public let executedCommand: String
    /// The collected standard output from the command.
    public let stdout: String
    /// The collected standard error output from the command.
    public let stderr: String
    /// The exit code returned by the command.
    public let exitCode: Int32
    /// A list of tools that were installed during execution.
    public let installedTools: [String]
}

/// An executor for running queries starting with "bash:" using BashRunner.
/// 
/// This executor parses the input command, attempts to ensure the primary tool is installed (using Homebrew on macOS if needed),
/// runs the command, and collects output asynchronously.
/// 
/// - Note: Timeouts are applied to installation and execution phases to avoid indefinite hangs.
/// - Note: This executor assumes a POSIX-like environment with Bash and the availability of `command -v`.
public enum BashQueryExecutor {
    
    /// Returns whether the input string can be handled by this executor.
    /// - Parameter input: The input query string.
    /// - Returns: True if the input starts with "bash:" (case-insensitive, trimmed).
    public static func canHandle(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("bash:")
    }
    
    /// Executes the given bash query command asynchronously.
    /// - Parameters:
    ///   - input: The full input string starting with "bash:".
    ///   - timeout: The maximum time allowed for command execution and installation steps (default 120s).
    /// - Returns: A `BashQueryResult` containing outputs, exit code, and installed tools.
    public static func execute(_ input: String, timeout: TimeInterval = 120) async -> BashQueryResult {
        let requested = input
        // Extract command substring after the first colon
        let commandPart = input.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        let executedCommand = commandPart
        
        var installedTools: [String] = []
        
        // Identify primary tool name (first token of command)
        let tool = commandPart.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
        
        var stderrAcc = ""
        
        if let toolName = tool, !toolName.isEmpty {
            // Check if tool is available
            let available = await isToolAvailable(toolName, timeout: timeout)
            if !available {
                #if os(macOS)
                // Try installing with brew if available
                let brewAvailable = await isToolAvailable("brew", timeout: timeout)
                if brewAvailable {
                    let installResult = await attemptInstallWithBrew(toolName, timeout: timeout)
                    if installResult.installed {
                        installedTools.append(toolName)
                    }
                    stderrAcc += installResult.stderr
                } else {
                    stderrAcc += "Homebrew is not installed or not found in PATH; cannot install tool \(toolName).\n"
                }
                #else
                stderrAcc += "Tool \(toolName) not found and automatic installation is supported only on macOS with Homebrew.\n"
                #endif
            }
        }
        
        // Run the original command and collect outputs
        let (stdout, stderr, exitCode) = await runAndCollect(commandPart, timeout: timeout)
        
        return BashQueryResult(
            requested: requested,
            executedCommand: executedCommand,
            stdout: stdout,
            stderr: stderrAcc + stderr,
            exitCode: exitCode,
            installedTools: installedTools
        )
    }
    
    /// Runs a command via BashRunner and collects stdout and stderr asynchronously.
    /// - Parameters:
    ///   - command: The command string to run.
    ///   - timeout: Maximum time allowed for execution.
    /// - Returns: A tuple with collected stdout, stderr, and the exit code.
    private static func runAndCollect(_ command: String, timeout: TimeInterval) async -> (stdout: String, stderr: String, code: Int32) {
        var stdoutBuilder = ""
        var stderrBuilder = ""
        
        let stream = BashRunner.run(command: command, timeout: timeout)
        
        for await output in stream {
            switch output {
            case .stdout(let line):
                stdoutBuilder.append(contentsOf: line)
            case .stderr(let line):
                stderrBuilder.append(contentsOf: line)
            }
        }
        
        let exitCode = await BashRunner.exitCode
        
        return (stdoutBuilder, stderrBuilder, exitCode)
    }
    
    /// Checks if a tool/command is available in the PATH by running `command -v <name>`.
    /// - Parameters:
    ///   - name: The tool or command name to check.
    ///   - timeout: Timeout for the check.
    /// - Returns: True if the command exists and returns exit code 0.
    private static func isToolAvailable(_ name: String, timeout: TimeInterval) async -> Bool {
        let checkCommand = "command -v \(name)"
        let (_, _, code) = await runAndCollect(checkCommand, timeout: timeout)
        return code == 0
    }
    
    /// Attempts to install a tool using Homebrew on macOS.
    /// - Parameters:
    ///   - name: The tool name to install.
    ///   - timeout: Timeout for the installation process.
    /// - Returns: A tuple indicating if installation succeeded, along with stdout, stderr, and exit code from `brew install`.
    private static func attemptInstallWithBrew(_ name: String, timeout: TimeInterval) async -> (installed: Bool, stdout: String, stderr: String, code: Int32) {
        let installCommand = "brew install \(name)"
        let (stdout, stderr, code) = await runAndCollect(installCommand, timeout: timeout)
        let installed = code == 0
        return (installed, stdout, stderr, code)
    }
}
