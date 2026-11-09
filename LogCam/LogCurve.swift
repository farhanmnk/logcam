import CoreImage
import Foundation

/// Builds a 3D LUT (CIColorCube) that applies a log-style flattening curve to each channel.
/// This simulates a log profile; it is NOT true Apple Log.
enum LogCurve {
    /// Higher k = more shadow lift / flatter image.
    static let k: Double = 12

    static func encode(_ x: Double) -> Double {
        let y = log2(1 + k * x) / log2(1 + k)      // lifts shadows, compresses highlights
        return 0.06 + y * 0.84                      // keep inside a safe range (no crushed/clipped ends)
    }

    static func makeFilter(size: Int = 64) -> CIFilter? {
        var cube = [Float]()
        cube.reserveCapacity(size * size * size * 4)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let rr = Float(encode(Double(r) / Double(size - 1)))
                    let gg = Float(encode(Double(g) / Double(size - 1)))
                    let bb = Float(encode(Double(b) / Double(size - 1)))
                    cube.append(contentsOf: [rr, gg, bb, 1])
                }
            }
        }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        let filter = CIFilter(name: "CIColorCube")
        filter?.setValue(size, forKey: "inputCubeDimension")
        filter?.setValue(data, forKey: "inputCubeData")
        return filter
    }
}
