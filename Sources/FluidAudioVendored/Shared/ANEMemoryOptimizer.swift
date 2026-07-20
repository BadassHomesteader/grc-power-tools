import CoreML
import Foundation

// Trimmed from upstream ANEMemoryOptimizer.swift: only this MLMultiArray
// extension is used by the ASR path. The ANEMemoryOptimizer class and
// ZeroCopyDiarizerFeatureProvider that used to live in this file are
// Diarizer-specific (throw DiarizerError, not vendored) — see NOTICE.md.
extension MLMultiArray {
    /// Prefetch data to Neural Engine (iOS 17+/macOS 14+)
    public func prefetchToNeuralEngine() {
        // Trigger ANE prefetch by accessing first and last elements
        // This causes the ANE to initiate DMA transfer
        if count > 0 {
            _ = self[0]
            _ = self[count - 1]
        }
    }
}
