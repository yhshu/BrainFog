// Draws the BrainFog app icon: a brain over a glow in the three agent
// colors, its lower half lost in drifting fog.
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
        (CGPoint(x: 520, y: 450), 170, color(0.30, 0.75, 0.55, 0.85)),   // OpenCode
    ]
    for (c, r, col) in blobs {
        ctx.setFillColor(col)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
}, 70)

// 3. Brain: two scalloped hemispheres seen from above, with a few folds.
func hemisphere(center: CGPoint, mirrored: Bool) -> (outline: CGPath, folds: CGPath) {
    let rx = 132.0, ry = 200.0, lumps = 11
    var outline = CGPath(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
    for i in 0..<lumps {
        let a = Double(i) / Double(lumps) * 2 * .pi
        let p = CGPoint(x: center.x + rx * cos(a), y: center.y + ry * sin(a))
        // Leave the inner edge, along the midline, smooth.
        if (mirrored ? -cos(a) : cos(a)) > 0.7 { continue }
        outline = outline.union(CGPath(ellipseIn: CGRect(x: p.x - 52, y: p.y - 52, width: 104, height: 104), transform: nil))
    }
    let s = mirrored ? -1.0 : 1.0
    let folds = CGMutablePath()
    folds.move(to: CGPoint(x: center.x - s * 70, y: center.y + 120))
    folds.addCurve(to: CGPoint(x: center.x + s * 60, y: center.y + 60),
                   control1: CGPoint(x: center.x - s * 10, y: center.y + 150), control2: CGPoint(x: center.x + s * 10, y: center.y + 60))
    folds.move(to: CGPoint(x: center.x - s * 100, y: center.y - 10))
    folds.addCurve(to: CGPoint(x: center.x + s * 70, y: center.y - 40),
                   control1: CGPoint(x: center.x - s * 40, y: center.y + 40), control2: CGPoint(x: center.x + s * 20, y: center.y - 60))
    folds.move(to: CGPoint(x: center.x - s * 60, y: center.y - 150))
    folds.addCurve(to: CGPoint(x: center.x + s * 50, y: center.y - 110),
                   control1: CGPoint(x: center.x - s * 20, y: center.y - 100), control2: CGPoint(x: center.x + s * 20, y: center.y - 150))
    return (outline, folds)
}

let brain = canvas { ctx in
    ctx.setStrokeColor(color(1, 1, 1, 0.95))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for mirrored in [false, true] {
        let h = hemisphere(center: CGPoint(x: mirrored ? 662 : 362, y: 560), mirrored: mirrored)
        ctx.setLineWidth(26)
        ctx.addPath(h.outline)
        ctx.strokePath()
        ctx.setLineWidth(20)
        ctx.addPath(h.folds)
        ctx.strokePath()
    }
}

// 4. Fog: the brain goes from sharp at the top to blurred and faded at the
// bottom, with long soft strands drifting across it.
func verticalMask(top: Double, bottom: Double, opaqueAtTop: Bool) -> CIImage {
    canvas { ctx in
        let ends = [color(1, 1, 1, 1), color(1, 1, 1, 0)]
        let gradient = CGGradient(colorsSpace: space, colors: (opaqueAtTop ? ends : ends.reversed()) as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: top), end: CGPoint(x: 512, y: bottom),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
func masked(_ image: CIImage, _ mask: CIImage) -> CIImage {
    image.applyingFilter("CIBlendWithAlphaMask", parameters: [
        kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
    ])
}
let sharpBrain = masked(brain, verticalMask(top: 640, bottom: 470, opaqueAtTop: true))
let foggyBrain = masked(blurred(brain, 16), verticalMask(top: 640, bottom: 470, opaqueAtTop: false))
    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.6)])

let strands: [(rect: CGRect, blur: Double, alpha: Double)] = [
    (CGRect(x: 40, y: 440, width: 620, height: 90), 30, 0.55),
    (CGRect(x: 360, y: 360, width: 640, height: 110), 32, 0.7),
    (CGRect(x: 20, y: 200, width: 800, height: 170), 38, 0.85),
]
var fog = CIImage.empty()
for s in strands {
    let strand = canvas { ctx in
        ctx.setFillColor(color(0.86, 0.88, 0.98, s.alpha))
        ctx.fillEllipse(in: s.rect)
    }
    fog = blurred(strand, s.blur).composited(over: fog)
}
let strata = fog.composited(over: sharpBrain.composited(over: foggyBrain))

// 5. Glass rim: a faint light edge along the top of the tile.
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
