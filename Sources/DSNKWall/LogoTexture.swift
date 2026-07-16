import Foundation
import Metal
import CoreGraphics
import AppKit

/// Rasterizes the DSNK SVG path into a mipmapped alpha-mask Metal texture.
enum LogoTexture {

    /// White DSNK path from `assets/DSNK cover.svg` (viewBox 0 0 516 516).
    static let pathData = """
    M268.35 211.344C268.35 247.224 242.142 270 200.334 270H130.134V62.208H200.334C242.142 62.208 268.35 89.976 268.35 125.856V211.344ZM212.502 207.6V124.608C212.502 113.064 207.51 106.512 196.278 106.512H185.982V225.696H196.278C207.51 225.696 212.502 219.144 212.502 207.6ZM389.796 212.544C389.796 244.464 366.692 275.168 324.74 275.168C283.396 275.168 258.468 253.584 258.468 217.408V206.464H305.892V216.192C305.892 225.92 311.972 232.912 322.308 232.912C332.644 232.912 337.508 227.136 337.508 216.496C337.508 204.032 322.612 195.216 305.892 184.576C284.308 171.2 259.988 154.784 259.988 124.992C259.988 93.376 282.484 62.672 326.26 62.672C362.132 62.672 386.756 88.512 386.756 120.128V128.64H339.332V119.216C339.332 110.4 333.556 104.928 326.26 104.928C319.268 104.928 311.972 109.792 311.972 119.52C311.972 131.984 326.868 140.496 343.588 151.136C365.172 164.816 389.796 181.536 389.796 212.544ZM258.885 456H217.431L188.103 394.806L175.131 367.734V456H130.011V268.188H173.721L201.921 331.074L214.047 358.146V268.188H258.885V456ZM394.06 456H343.018L322.714 386.064L312.28 409.188V456H261.802V268.188H312.28V348.558L341.044 268.188H390.394L359.092 345.738L394.06 456Z
    """

    static let viewBoxSize: CGFloat = 516

    static func make(device: MTLDevice, size: Int = 2048) -> MTLTexture? {
        guard let cgPath = parseSVGPath(pathData) else {
            fputs("LogoTexture: failed to parse SVG path\n", stderr)
            return nil
        }

        // Pad so glow / distortion has room at edges.
        let padding: CGFloat = 40
        let canvas = viewBoxSize + padding * 2
        let scale = CGFloat(size) / canvas

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // SVG Y grows downward; CoreGraphics Y grows upward — flip Y only while drawing.
        // (Do not flip X — that mirrors the logo.)
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: padding, y: padding)

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(cgPath)
        ctx.fillPath()

        guard let image = ctx.makeImage() else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: size,
            height: size,
            mipmapped: true
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        // After the SVG Y-flip draw above, row 0 of the context is the visual top (D/S).
        // Upload as-is so Metal v=0 matches screen top (logoUV.y = 0).
        guard let data = ctx.data else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: size
        )

        // Generate mipmaps for free glow blur.
        if let queue = device.makeCommandQueue(),
           let cmd = queue.makeCommandBuffer(),
           let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        _ = image // keep alive through upload
        return texture
    }

    // MARK: - SVG path parser (M/L/C/H/V/Z, absolute + relative)

    private static func parseSVGPath(_ data: String) -> CGPath? {
        let path = CGMutablePath()
        var i = data.startIndex
        var current = CGPoint.zero
        var startSubpath = CGPoint.zero
        var lastCommand: Character = "M"

        func skipWhitespaceAndCommas() {
            while i < data.endIndex {
                let c = data[i]
                if c.isWhitespace || c == "," { i = data.index(after: i) } else { break }
            }
        }

        func peekNumber() -> Bool {
            skipWhitespaceAndCommas()
            guard i < data.endIndex else { return false }
            let c = data[i]
            return c == "-" || c == "+" || c == "." || c.isNumber
        }

        func readNumber() -> CGFloat? {
            skipWhitespaceAndCommas()
            guard i < data.endIndex else { return nil }
            let start = i
            if data[i] == "-" || data[i] == "+" { i = data.index(after: i) }
            var sawDot = false
            var sawExp = false
            while i < data.endIndex {
                let c = data[i]
                if c.isNumber {
                    i = data.index(after: i)
                } else if c == "." && !sawDot && !sawExp {
                    sawDot = true
                    i = data.index(after: i)
                } else if (c == "e" || c == "E") && !sawExp {
                    sawExp = true
                    i = data.index(after: i)
                    if i < data.endIndex && (data[i] == "-" || data[i] == "+") {
                        i = data.index(after: i)
                    }
                } else {
                    break
                }
            }
            guard start < i, let v = Double(data[start..<i]) else { return nil }
            return CGFloat(v)
        }

        func readPoint() -> CGPoint? {
            guard let x = readNumber(), let y = readNumber() else { return nil }
            return CGPoint(x: x, y: y)
        }

        skipWhitespaceAndCommas()
        while i < data.endIndex {
            skipWhitespaceAndCommas()
            guard i < data.endIndex else { break }

            var command = data[i]
            if command.isLetter {
                i = data.index(after: i)
                lastCommand = command
            } else {
                // Implicit command repetition
                command = lastCommand
                if command == "M" { command = "L"; lastCommand = "L" }
                if command == "m" { command = "l"; lastCommand = "l" }
            }

            switch command {
            case "M":
                guard let p = readPoint() else { return nil }
                path.move(to: p)
                current = p
                startSubpath = p
                while peekNumber() {
                    guard let n = readPoint() else { break }
                    path.addLine(to: n)
                    current = n
                    lastCommand = "L"
                }
            case "m":
                guard let d = readPoint() else { return nil }
                let p = CGPoint(x: current.x + d.x, y: current.y + d.y)
                path.move(to: p)
                current = p
                startSubpath = p
                while peekNumber() {
                    guard let n = readPoint() else { break }
                    let abs = CGPoint(x: current.x + n.x, y: current.y + n.y)
                    path.addLine(to: abs)
                    current = abs
                    lastCommand = "l"
                }
            case "L":
                while true {
                    guard let p = readPoint() else { break }
                    path.addLine(to: p)
                    current = p
                    if !peekNumber() { break }
                }
            case "l":
                while true {
                    guard let d = readPoint() else { break }
                    let p = CGPoint(x: current.x + d.x, y: current.y + d.y)
                    path.addLine(to: p)
                    current = p
                    if !peekNumber() { break }
                }
            case "H":
                while true {
                    guard let x = readNumber() else { break }
                    let p = CGPoint(x: x, y: current.y)
                    path.addLine(to: p)
                    current = p
                    if !peekNumber() { break }
                }
            case "h":
                while true {
                    guard let dx = readNumber() else { break }
                    let p = CGPoint(x: current.x + dx, y: current.y)
                    path.addLine(to: p)
                    current = p
                    if !peekNumber() { break }
                }
            case "V":
                while true {
                    guard let y = readNumber() else { break }
                    let p = CGPoint(x: current.x, y: y)
                    path.addLine(to: p)
                    current = p
                    if !peekNumber() { break }
                }
            case "v":
                while true {
                    guard let dy = readNumber() else { break }
                    let p = CGPoint(x: current.x, y: current.y + dy)
                    path.addLine(to: p)
                    current = p
                    if !peekNumber() { break }
                }
            case "C":
                while true {
                    guard let c1 = readPoint(), let c2 = readPoint(), let end = readPoint() else { break }
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end
                    if !peekNumber() { break }
                }
            case "c":
                while true {
                    guard let d1 = readPoint(), let d2 = readPoint(), let de = readPoint() else { break }
                    let c1 = CGPoint(x: current.x + d1.x, y: current.y + d1.y)
                    let c2 = CGPoint(x: current.x + d2.x, y: current.y + d2.y)
                    let end = CGPoint(x: current.x + de.x, y: current.y + de.y)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end
                    if !peekNumber() { break }
                }
            case "Z", "z":
                path.closeSubpath()
                current = startSubpath
            default:
                fputs("LogoTexture: unsupported command \(command)\n", stderr)
                return nil
            }
        }
        return path
    }
}
