// Renders the app icon from Design/Glass/vessel.png: tinted glass with a violet rim on a white tile.
// The shipped AppIcon-1024.png:
//   swiftc -O render.swift -o /tmp/render
//   TINT=CDB6FF RIM_R=18 RIM_B=7 /tmp/render ../Glass/vessel.png AppIcon-1024.png white 2.6 1.5 1.0 0.86

import AppKit
import CoreImage

// usage: render2 <vessel.png> <out.png> <tile: white|dark> <saturation> <contrast> <rim 0..1> [scale]
let a = CommandLine.arguments
let vesselURL = URL(fileURLWithPath: a[1]), out = URL(fileURLWithPath: a[2])
let dark = a[3] == "dark"
let saturation = Double(a[4])!, contrast = Double(a[5])!, rim = CGFloat(Double(a[6])!)
let scale = a.count > 7 ? CGFloat(Double(a[7])!) : 0.80
let size: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185
let ci = CIContext()

guard let src = CIImage(contentsOf: vesselURL) else { fatalError("no vessel") }
var v = src.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation, kCIInputContrastKey: contrast, kCIInputBrightnessKey: dark ? 0.0 : -0.05])
v = v.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.6])
// Optional glass tint: multiply the vessel by a violet so its clear body reads as tinted glass on white.
if let hex = ProcessInfo.processInfo.environment["TINT"], let rgb = UInt32(hex, radix: 16) {
    let tint = CIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255)
    let solid = CIImage(color: tint).cropped(to: src.extent)
    let multiplied = solid.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: v])
    // Keep the vessel's own alpha.
    v = multiplied.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty().cropped(to: src.extent), kCIInputMaskImageKey: v])
}
// Rim: the outer band of the alpha mask, tinted deep violet, so the glass edge reads on any tile.
if rim > 0 {
    let alpha = src.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                                                               "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    // Only the solid glass counts as the edge, not the soft glow around it.
    let solidAlpha = alpha.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 4, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 4, z: 0, w: 0),
                                                                      "inputBVector": CIVector(x: 0, y: 0, z: 4, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 4),
                                                                      "inputBiasVector": CIVector(x: -2.6, y: -2.6, z: -2.6, w: -2.6)]).applyingFilter("CIColorClamp")
    let eroded = solidAlpha.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: Double(ProcessInfo.processInfo.environment["RIM_R"] ?? "9")!]).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Double(ProcessInfo.processInfo.environment["RIM_B"] ?? "6")!]).cropped(to: src.extent)
    let band = solidAlpha.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: eroded])
    let tint = CIImage(color: dark ? CIColor(red: 1, green: 1, blue: 1, alpha: 1) : CIColor(red: 0.22, green: 0.06, blue: 0.42, alpha: 1)).cropped(to: src.extent)
    let mask = band.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: rim, y: 0, z: 0, w: 0)])
    let rimLayer = tint.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty().cropped(to: src.extent), kCIInputMaskImageKey: mask])
    v = rimLayer.composited(over: v)
}
guard let vessel = ci.createCGImage(v, from: src.extent) else { fatalError("render") }

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.30))
ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(path); ctx.clip()
if dark {
    let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.20, green: 0.08, blue: 0.42, alpha: 1), CGColor(red: 0.05, green: 0.03, blue: 0.16, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let glow = CGGradient(colorsSpace: cs, colors: [CGColor(red: 1.0, green: 0.30, blue: 0.70, alpha: 0.45), CGColor(red: 0.4, green: 0.2, blue: 1.0, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0, endCenter: CGPoint(x: 512, y: 470), endRadius: 420, options: [])
} else {
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(tile)
    let glow = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.62, green: 0.18, blue: 0.85, alpha: 0.30), CGColor(red: 1, green: 0.3, blue: 0.7, alpha: 0.10), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 480), startRadius: 0, endCenter: CGPoint(x: 512, y: 480), endRadius: 400, options: [])
    let sh = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.25, green: 0.06, blue: 0.40, alpha: 0.42), CGColor(red: 0.25, green: 0.06, blue: 0.40, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.saveGState(); ctx.translateBy(x: 512, y: 200); ctx.scaleBy(x: 1, y: 0.20)
    ctx.drawRadialGradient(sh, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 300, options: []); ctx.restoreGState()
}
let w = size * scale
let rect = CGRect(x: (size - w) / 2, y: (size - w) / 2 + 18, width: w, height: w)
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: CGColor(red: 0.25, green: 0.05, blue: 0.40, alpha: dark ? 0.5 : 0.40))
ctx.draw(vessel, in: rect)
ctx.restoreGState()
if !dark { ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08)); ctx.setLineWidth(2); ctx.strokePath() }
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote", out.lastPathComponent)
