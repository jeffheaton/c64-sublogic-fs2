import C64Kit
import CoreGraphics
import Foundation
import Synchronization

/// Converts palette-index frames to 32-bit BGRA images, scaled by integer factors with nearest
/// neighbor (the "sharp" half of sharp bilinear; the layer does the linear half).
enum FrameConverter {
    /// Writes `indices` (`width` × `height`) as pixels `0xFFRRGGBB` (BGRA bytes in memory) into
    /// `out`, which must hold `width * scaleX * height * scaleY` pixels.
    static func convert(indices: UnsafeBufferPointer<UInt8>, width: Int, height: Int, palette: [UInt32],
                        scaleX: Int, scaleY: Int, into out: UnsafeMutablePointer<UInt32>) {
        precondition(indices.count >= width * height && palette.count >= 16 && scaleX >= 1 && scaleY >= 1)
        let outWidth = width * scaleX
        palette.withUnsafeBufferPointer { pal in
            for y in 0..<height {
                let row = out + y * scaleY * outWidth
                let src = indices.baseAddress! + y * width
                var o = row
                if scaleX == 1 {
                    for x in 0..<width { o[x] = pal[Int(src[x] & 0x0F)] }
                } else {
                    for x in 0..<width {
                        let c = pal[Int(src[x] & 0x0F)]
                        for k in 0..<scaleX { o[k] = c }
                        o += scaleX
                    }
                }
                if scaleY > 1 {
                    for r in 1..<scaleY { (row + r * outWidth).update(from: row, count: outWidth) }
                }
            }
        }
    }

    /// Array convenience for tests and tools.
    static func convert(indices: [UInt8], width: Int, height: Int, palette: [UInt32], scaleX: Int,
                        scaleY: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: width * scaleX * height * scaleY)
        out.withUnsafeMutableBufferPointer { o in
            indices.withUnsafeBufferPointer { i in
                convert(indices: i, width: width, height: height, palette: palette, scaleX: scaleX,
                        scaleY: scaleY, into: o.baseAddress!)
            }
        }
        return out
    }
}

/// Reusable pixel buffers for frame images. Each image keeps its buffer until CoreAnimation lets go
/// of it (the data provider's release callback), so a buffer is never overwritten while displayed,
/// and steady-state presentation allocates nothing.
final class ImageBufferPool: Sendable {
    final class Buffer: @unchecked Sendable {
        let pixels: UnsafeMutablePointer<UInt32>
        let count: Int
        weak var pool: ImageBufferPool?

        fileprivate init(count: Int, pool: ImageBufferPool) {
            pixels = .allocate(capacity: count)
            self.count = count
            self.pool = pool
        }

        deinit { pixels.deallocate() }
    }

    private let free = Mutex<[Buffer]>([])

    /// A buffer of exactly `count` pixels (buffers of other sizes are dropped).
    func take(count: Int) -> Buffer {
        let reused: Buffer? = free.withLock { list in
            list.removeAll { $0.count != count }
            return list.popLast()
        }
        return reused ?? Buffer(count: count, pool: self)
    }

    fileprivate func giveBack(_ b: Buffer) {
        free.withLock { list in if list.count < 4 { list.append(b) } }
    }

    /// Wraps a filled buffer as an sRGB image; the buffer returns to the pool when the image dies.
    func makeImage(_ buffer: Buffer, width: Int, height: Int) -> CGImage? {
        let info = Unmanaged.passRetained(buffer).toOpaque()
        guard let provider = CGDataProvider(dataInfo: info, data: buffer.pixels, size: width * height * 4,
                                            releaseData: releaseImageBuffer) else {
            Unmanaged<Buffer>.fromOpaque(info).release()
            return nil
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

/// CGDataProvider release callback: hands the buffer back to its pool.
private func releaseImageBuffer(_ info: UnsafeMutableRawPointer?, _ data: UnsafeRawPointer, _ size: Int) {
    guard let info else { return }
    let buffer = Unmanaged<ImageBufferPool.Buffer>.fromOpaque(info).takeRetainedValue()
    buffer.pool?.giveBack(buffer)
}
