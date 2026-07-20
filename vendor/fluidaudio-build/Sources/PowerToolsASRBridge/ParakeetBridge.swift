import Foundation
import FluidAudio

// Fully opaque wrapper: no FluidAudio type ever appears in this file's public
// signatures, so the consuming (swiftc, non-SPM) build only needs this module's
// .swiftmodule for typechecking — FluidAudio's own module is never imported there,
// only linked in at the object-code level via the harvested static libraries.

public enum ParakeetModelVersion: Sendable, Equatable {
    case english
    case multilingual
}

public struct ParakeetTranscriptionResult: Sendable {
    public let text: String
    public let confidence: Float
    public let duration: TimeInterval
}

public enum ParakeetBridgeError: Error {
    case notLoaded
}

public final class ParakeetBridge: @unchecked Sendable {
    private var manager: AsrManager?

    public init() {}

    public func loadModels(version: ParakeetModelVersion) async throws {
        let resolved: AsrModelVersion = (version == .english) ? .v2 : .v3
        let models = try await AsrModels.downloadAndLoad(version: resolved)
        let mgr = AsrManager()
        try await mgr.loadModels(models)
        self.manager = mgr
    }

    public func transcribe(fileURL: URL) async throws -> ParakeetTranscriptionResult {
        guard let manager else { throw ParakeetBridgeError.notLoaded }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(fileURL, decoderState: &decoderState, language: nil)
        return ParakeetTranscriptionResult(text: result.text, confidence: result.confidence, duration: result.duration)
    }
}
