import Foundation
import Metal

/// Immutable device-specific pipelines are shared; command queues and mutable
/// buffers remain private to each filter. No recompilation between sessions.
enum MetalPipelines {
    private static let lock = NSLock()
    private static var cache: [UInt64: [String: MTLComputePipelineState]] = [:]
    static func load(device: MTLDevice) throws -> [String: MTLComputePipelineState] {
        lock.lock(); defer { lock.unlock() }
        if let pipelines = cache[device.registryID] { return pipelines }
        let sources = try ["WinZipAES", "ArchiveSHA256"].map { name -> String in
            guard let url = CoreResources.bundle.url(forResource: name, withExtension: "metal") else { throw MetalZIPFilter.FilterError.missingShader }
            return try String(contentsOf: url, encoding: .utf8)
        }
        let library = try device.makeLibrary(source: sources.joined(separator: "\n"), options: nil)
        var pipelines: [String: MTLComputePipelineState] = [:]
        for name in ["winZipAESVerifier", "sevenZIPKey", "rar5Key", "pdfR5Key", "zipCryptoHeader", "pdfLegacyKey", "rar3Key"] {
            guard let function = library.makeFunction(name: name) else { throw MetalZIPFilter.FilterError.missingShader }
            pipelines[name] = try device.makeComputePipelineState(function: function)
        }
        cache[device.registryID] = pipelines
        return pipelines
    }
}
