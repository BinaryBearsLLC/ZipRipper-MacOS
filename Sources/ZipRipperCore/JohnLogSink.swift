import Foundation

/// Pipe reads do not align with lines. Buffer before redacting candidate text.
final class JohnLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let emit: @Sendable (String) -> Void
    private let candidate: @Sendable (String?) -> Void
    private let candidateLength: Int?
    init(emit: @escaping @Sendable (String) -> Void, candidate: @escaping @Sendable (String?) -> Void = { _ in }, candidateLength: Int? = nil) {
        self.emit = emit; self.candidate = candidate; self.candidateLength = candidateLength
    }
    private func consume(_ line: String) {
        // Capture only the status suffix, before the existing redaction. John
        // reports a sampled candidate/range, possibly one per fork worker.
        if line.contains("g/s"), let boundary = line.range(of: #"(?:^|\s)[0-9.,eE+\-kKMGT]+C/s\s+"#, options: .regularExpression) {
            let sample = line[boundary.upperBound...].trimmingCharacters(in: .newlines)
            if !sample.isEmpty { candidate(displaySample(String(sample))) }
        }
        emit(JohnResult.redactedDiagnostics(line))
    }
    private func displaySample(_ sample: String) -> String {
        // John prints key1..key2. For a fixed printable mask the known byte
        // length identifies the separator without confusing literal '..'.
        // John caps each displayed key at 200 bytes; never infer beyond that.
        if let length = candidateLength, (1...200).contains(length) {
            let bytes = Array(sample.utf8)
            if bytes.count == length { return "Sample: " + sample }
            if bytes.count == length * 2 + 2, bytes[length] == 46, bytes[length + 1] == 46 {
                return "Sample: " + String(decoding: bytes.prefix(length), as: UTF8.self)
            }
        }
        // Variable-length/advanced searches have an ambiguous delimiter.
        // Preserve their bytes and explicitly label the group of samples.
        return "Samples: " + String(sample.prefix(160))
    }
    func accept(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        pending += text
        while let end = pending.firstIndex(of: "\n") {
            let line = String(pending[...end]); pending.removeSubrange(...end)
            consume(line)
        }
        if pending.count > 65536 { pending = "[Long engine diagnostic omitted]" }
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { consume(pending); pending = "" }
    }
}
