import Foundation

/// A sequence of shell steps to accomplish an installation or setup task.
struct Plan {
    let description: String
    let steps: [Step]
}

/// A single shell step in a plan.
struct Step {
    enum Safety { case safe, needsConsent, privileged }
    let title: String
    let command: String
    let timeout: TimeInterval
    let safety: Safety
    /// Whether the step must be executed with sudo -S.
    var requiresSudo: Bool = false
    /// Optional stdin provider; used to feed passwords or other input when needed.
    var stdin: (() -> Data?)? = nil
}
