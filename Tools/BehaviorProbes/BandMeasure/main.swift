// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// bandmeasure <out.png>: captures the built-in display's camera-housing band
// with screencapture and prints the non-black fraction of the areas left and
// right of the housing, plus a "text-like" fraction (bright pixels), which is
// high when the menu bar's titles are drawn over the band. Read-only.
//
//   swiftc -O main.swift -o bandmeasure && ./bandmeasure /tmp/band.png

import AppKit

guard CommandLine.arguments.count > 1 else {
    print("usage: bandmeasure <out.png>"); exit(2)
}
let path = CommandLine.arguments[1]
guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
      let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
    print("no built-in display with a camera housing"); exit(3)
}
let band = screen.safeAreaInsets.top
// Global top-left (CoreGraphics) rect of the band.
let primaryMaxY = NSScreen.screens[0].frame.maxY
let bandRect = CGRect(x: screen.frame.minX, y: primaryMaxY - screen.frame.maxY,
                      width: screen.frame.width, height: band)
let task = Process()
task.launchPath = "/usr/sbin/screencapture"
task.arguments = ["-x", "-R\(Int(bandRect.minX)),\(Int(bandRect.minY)),\(Int(bandRect.width)),\(Int(bandRect.height))", path]
try task.run(); task.waitUntilExit()
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("capture failed (Screen Recording permission?)"); exit(4)
}
let scale = CGFloat(image.width) / screen.frame.width
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

// Area x ranges relative to the screen's left edge, in pixels.
func measure(_ area: NSRect) -> (nonBlack: Double, bright: Double) {
    let x0 = Int((area.minX - screen.frame.minX) * scale), x1 = Int((area.maxX - screen.frame.minX) * scale)
    var nonBlack = 0, bright = 0, total = 0
    for y in 0..<height {
        for x in max(0, x0)..<min(width, x1) {
            let i = (y * width + x) * 4
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            total += 1
            if r + g + b > 60 { nonBlack += 1 }
            if r > 200 && g > 200 && b > 200 { bright += 1 }
        }
    }
    return (Double(nonBlack) / Double(max(total, 1)), Double(bright) / Double(max(total, 1)))
}
let l = measure(left), r = measure(right)
// Click targets for spacesctl (global top-left points): middle of each area.
let cgTop = primaryMaxY - screen.frame.maxY
print(String(format: "targets left=%.0f,%.0f right=%.0f,%.0f", left.midX, cgTop + band / 2,
             right.midX, cgTop + band / 2))
print(String(format: "band=%.0fpt left nonBlack=%.3f bright=%.3f right nonBlack=%.3f bright=%.3f",
             band, l.nonBlack, l.bright, r.nonBlack, r.bright))
