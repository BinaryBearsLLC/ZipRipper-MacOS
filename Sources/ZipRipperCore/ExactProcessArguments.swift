import Foundation

/// Foundation converts non-ASCII argv through filesystem representations on
/// macOS, decomposing NFC strings. That changes password-mask bytes. Only those
/// launches use a fixed ASCII shell program which reconstructs each UTF-8 argv
/// from octal bytes and immediately execs the original executable at the same
/// PID. User text is never interpreted as shell source. The sentinel preserves
/// trailing newlines that ordinary command substitution would otherwise strip.
enum ExactProcessArguments {
    static func configure(_ process: Process, executable: URL, arguments: [String]) throws {
        let values = [executable.path] + arguments
        guard values.allSatisfy({ !$0.utf8.contains(0) }) else { throw RecoveryError.message("A process argument contains an unsupported NUL byte.") }
        if values.allSatisfy({ $0.utf8.allSatisfy { $0 < 128 } }) {
            process.executableURL = executable; process.arguments = arguments
            return
        }
        var script = ""
        for (index, value) in values.enumerated() {
            let escaped = value.utf8.map { String(format: "\\%03o", Int($0)) }.joined()
            script += "a\(index)=$(printf '\(escaped)x'); a\(index)=${a\(index)%x}\n"
        }
        script += "exec " + values.indices.map { "\"$a\($0)\"" }.joined(separator: " ") + "\n"
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
    }
}
