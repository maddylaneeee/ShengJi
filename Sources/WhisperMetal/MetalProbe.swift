import Foundation
import Metal

enum MetalProbe {
    static func describeDevice() -> String {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return "No Metal device detected"
        }
        let memory = ByteCountFormatter.string(fromByteCount: Int64(device.recommendedMaxWorkingSetSize), countStyle: .memory)
        return "Metal device: \(device.name), recommended working set \(memory)"
    }
}
