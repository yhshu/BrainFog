// Draws the BrainFog app icon: a glowing core behind wavy layers that run
// from foggy at the top to sharp at the bottom.
//
// Usage: swift scripts/make-icon.swift <output.png>   (1024×1024)
import AppKit
import CoreImage

let size = 1024.0
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)   // macOS icon grid
let corner = 186.0

let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ci = CIContext(options: [.workingColorSpace: space])

func canvas(_ draw: (CGContext) -> Void) -> CIImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return CIImage(cgImage: ctx.makeImage()!)
}

func blurred(_ image: CIImage, _ radius: Double) -> CIImage {
    radius == 0 ? image : image.clampedToExtent()
        .applyingGaussianBlur(sigma: radius)
        .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
}

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

// 1. Night-sky tile.
let background = canvas { ctx in
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        color(0.16, 0.17, 0.33), color(0.06, 0.07, 0.15),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
}

// 2. Core glow in the three agent colors.
let glow = blurred(canvas { ctx in
    let blobs: [(CGPoint, Double, CGColor)] = [
        (CGPoint(x: 430, y: 560), 190, color(0.85, 0.47, 0.34, 0.95)),   // Claude Code
        (CGPoint(x: 600, y: 590), 180, color(0.36, 0.55, 0.98, 0.95)),   // Codex
        (CGPoint(x: 520, y: 450), 170, color(0.30, 0.75, 0.55, 0.85)),   // opencode
    ]
    for (c, r, col) in blobs {
        ctx.setFillColor(col)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
}, 70)

// 3. Layers: a gentle wave each, blur falling and opacity rising toward the bottom.
func wave(y: Double, amplitude: Double, phase: Double) -> CGPath {
    let path = CGMutablePath()
    let left = 250.0, right = 774.0, steps = 120
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        let x = left + (right - left) * t
        let p = CGPoint(x: x, y: y + amplitude * sin(t * .pi * 2 + phase))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    return path
}

let layers: [(y: Double, blur: Double, alpha: Double, width: Double)] = [
    (690, 16, 0.35, 34),
    (580, 9, 0.55, 34),
    (470, 3.5, 0.8, 34),
    (360, 0, 1.0, 34),
]
var strata = CIImage.empty()
for (i, layer) in layers.enumerated() {
    let line = canvas { ctx in
        ctx.addPath(wave(y: layer.y, amplitude: 26, phase: Double(i) * 0.9))
        ctx.setLineWidth(layer.width)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color(1, 1, 1, layer.alpha))
        ctx.strokePath()
    }
    strata = blurred(line, layer.blur).composited(over: strata)
}

// 4. Glass rim: a faint light edge along the top of the tile.
let rim = canvas { ctx in
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.addPath(tilePath)
    ctx.setLineWidth(6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        color(1, 1, 1, 0.45), color(1, 1, 1, 0.0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 500), options: [])
}

// Composite and clip the glow and layers to the tile.
let mask = canvas { ctx in
    ctx.setFillColor(color(1, 1, 1))
    ctx.addPath(tilePath)
    ctx.fillPath()
}
let inside = strata.composited(over: glow.composited(over: background))
let clipped = inside.applyingFilter("CIBlendWithAlphaMask", parameters: [
    kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
])
let final = rim.composited(over: clipped)

// Soft drop shadow under the tile, as macOS icons have.
let shadow = blurred(mask.applyingFilter("CIColorMatrix", parameters: [
    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35),
]).transformed(by: CGAffineTransform(translationX: 0, y: -12)), 14)

let output = final.composited(over: shadow)
let url = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png")
try ci.writePNGRepresentation(of: output.cropped(to: CGRect(x: 0, y: 0, width: size, height: size)),
                              to: url, format: .RGBA8, colorSpace: space)
print("Wrote \(url.path)")
