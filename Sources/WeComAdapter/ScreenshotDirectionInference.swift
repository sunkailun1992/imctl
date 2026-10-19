import ControlCore
import CoreGraphics

/// Resolves a textless message row only when one side of a window screenshot
/// contains a substantial image-shaped region. The image is examined in memory;
/// neither pixels nor a derived thumbnail are written or returned.
public enum ScreenshotDirectionInference {
    /// `windowFrame`, `tableFrame` and `rowFrame` use the same global point
    /// coordinates as the AX tree. A clipped row or ambiguous pixels stay unknown.
    public static func infer(image: CGImage, windowFrame: CGRect, tableFrame: CGRect, rowFrame: CGRect) -> MessageDirection {
        guard image.width > 0, image.height > 0,
              windowFrame.width > 0, windowFrame.height > 0,
              tableFrame.width > 0, tableFrame.height > 0,
              rowFrame.width > 0, rowFrame.height >= 80 else { return .unknown }

        let visible = rowFrame.intersection(tableFrame).intersection(windowFrame)
        guard !visible.isNull, visible.width >= tableFrame.width * 0.8,
              visible.height >= rowFrame.height * 0.7 else { return .unknown }

        let scaleX = CGFloat(image.width) / windowFrame.width
        let scaleY = CGFloat(image.height) / windowFrame.height
        guard scaleX >= 0.5, scaleY >= 0.5 else { return .unknown }

        let crop = CGRect(
            x: floor((visible.minX - windowFrame.minX) * scaleX),
            y: floor((visible.minY - windowFrame.minY) * scaleY),
            width: ceil(visible.width * scaleX),
            height: ceil(visible.height * scaleY)
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !crop.isNull, crop.width >= 160, crop.height >= 80,
              let clipped = image.cropping(to: crop) else { return .unknown }

        let width = clipped.width
        let height = clipped.height
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        return rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return .unknown }
            context.draw(clipped, in: CGRect(x: 0, y: 0, width: width, height: height))

            let leftBoundary = (tableFrame.minX + tableFrame.width * 0.46 - visible.minX) * scaleX
            let rightBoundary = (tableFrame.minX + tableFrame.width * 0.54 - visible.minX) * scaleX
            return classify(
                buffer: buffer, width: width, height: height, bytesPerRow: bytesPerRow,
                leftBoundary: Int(leftBoundary), rightBoundary: Int(rightBoundary),
                scaleX: scaleX, scaleY: scaleY, tableWidth: tableFrame.width
            )
        }
    }

    private static func classify(
        buffer: UnsafeMutableRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
        leftBoundary: Int, rightBoundary: Int, scaleX: CGFloat, scaleY: CGFloat, tableWidth: CGFloat
    ) -> MessageDirection {
        guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return .unknown }
        // Ignore both vertical ends: the row's centered time label can land at
        // either end after Core Graphics rasterization, while the media remains tall.
        let top = Int(Double(height) * 0.13)
        let bottom = Int(Double(height) * 0.87)
        guard bottom - top >= 50 else { return .unknown }

        // The chat background occupies most of a row. A coarse modal RGB bin
        // tolerates antialiasing and avoids relying on a particular dark theme.
        var bins = [Int](repeating: 0, count: 4096)
        var red = [Int](repeating: 0, count: 4096)
        var green = [Int](repeating: 0, count: 4096)
        var blue = [Int](repeating: 0, count: 4096)
        for y in stride(from: top, to: bottom, by: 5) {
            for x in stride(from: 0, to: width, by: 5) {
                let offset = y * bytesPerRow + x * 4
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                let bin = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
                bins[bin] += 1
                red[bin] += r
                green[bin] += g
                blue[bin] += b
            }
        }
        guard let mode = bins.indices.max(by: { bins[$0] < bins[$1] }), bins[mode] > 0 else { return .unknown }
        let baseR = red[mode] / bins[mode]
        let baseG = green[mode] / bins[mode]
        let baseB = blue[mode] / bins[mode]

        let tile = max(8, Int(10 * min(scaleX, scaleY)))
        let columns = (width + tile - 1) / tile
        let rows = (bottom - top + tile - 1) / tile
        var active = [Bool](repeating: false, count: columns * rows)
        for ty in 0..<rows {
            let y0 = top + ty * tile
            let y1 = min(bottom, y0 + tile)
            for tx in 0..<columns {
                let x0 = tx * tile
                let x1 = min(width, x0 + tile)
                var total = 0
                var changed = 0
                for y in stride(from: y0, to: y1, by: 2) {
                    for x in stride(from: x0, to: x1, by: 2) {
                        let offset = y * bytesPerRow + x * 4
                        let difference = abs(Int(bytes[offset]) - baseR)
                            + abs(Int(bytes[offset + 1]) - baseG)
                            + abs(Int(bytes[offset + 2]) - baseB)
                        total += 1
                        if difference >= 64 { changed += 1 }
                    }
                }
                active[ty * columns + tx] = total > 0 && changed * 4 >= total
            }
        }

        var seen = [Bool](repeating: false, count: active.count)
        var inbound = false
        var outbound = false
        let minimumWidth = max(48 * scaleX, tableWidth * 0.045 * scaleX)
        let minimumHeight = max(52 * scaleY, CGFloat(height) * 0.22)

        for index in active.indices where active[index] && !seen[index] {
            var pending = [index]
            seen[index] = true
            var minX = columns, maxX = 0, minY = rows, maxY = 0
            while let next = pending.popLast() {
                let x = next % columns, y = next / columns
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < columns, ny >= 0, ny < rows else { continue }
                        let neighbor = ny * columns + nx
                        if active[neighbor] && !seen[neighbor] {
                            seen[neighbor] = true
                            pending.append(neighbor)
                        }
                    }
                }
            }
            let componentMinX = minX * tile
            let componentMaxX = min(width, (maxX + 1) * tile)
            let componentWidth = componentMaxX - componentMinX
            let componentHeight = min(bottom, top + (maxY + 1) * tile) - (top + minY * tile)
            guard CGFloat(componentWidth) >= minimumWidth,
                  CGFloat(componentHeight) >= minimumHeight else { continue }
            if componentMaxX <= leftBoundary { inbound = true }
            if componentMinX >= rightBoundary { outbound = true }
            if inbound && outbound { return .unknown }
        }
        if inbound { return .inbound }
        if outbound { return .outbound }
        return .unknown
    }
}
