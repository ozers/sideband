#!/usr/bin/env swift
//
// Draws the app icon and writes Resources/AppIcon.icns.
//
// Drawn in code rather than checked in as an SVG so that regenerating it needs
// nothing but the Swift toolchain — no rsvg, Inkscape or design tool, none of
// which are present by default on macOS.
//
// Usage: swift Scripts/make-icon.swift

import AppKit
import Foundation

/// A control dial over a graduated arc, with the arc running from a cold dark
/// blue to a warm white. The sweep carries the meaning: this is about light,
/// not just about a knob.
func drawIcon(size: CGFloat, into context: CGContext) {
    let scale = size / 1024
    context.scaleBy(x: scale, y: scale)

    let centre = CGPoint(x: 512, y: 512)

    // Plate
    let plateRect = CGRect(x: 64, y: 64, width: 896, height: 896)
    let plate = CGPath(roundedRect: plateRect, cornerWidth: 200, cornerHeight: 200, transform: nil)
    context.saveGState()
    context.addPath(plate)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.23, green: 0.25, blue: 0.29, alpha: 1),
            CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 512, y: 960),
            end: CGPoint(x: 512, y: 64),
            options: []
        )
    }
    context.restoreGState()

    // Graduated arc, open at the bottom so it reads as a range rather than a
    // ring. Drawn as a clipped gradient because CoreGraphics has no gradient
    // stroke.
    context.saveGState()
    let arc = CGMutablePath()
    arc.addArc(
        center: centre,
        radius: 286,
        startAngle: -.pi * 0.75,
        endAngle: -.pi * 0.25,
        clockwise: true
    )
    context.addPath(
        arc.copy(strokingWithWidth: 54, lineCap: .round, lineJoin: .round, miterLimit: 10)
    )
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.17, green: 0.42, blue: 0.69, alpha: 1),
            CGColor(red: 0.91, green: 0.72, blue: 0.29, alpha: 1),
            CGColor(red: 1.00, green: 0.96, blue: 0.88, alpha: 1),
        ] as CFArray,
        locations: [0, 0.55, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 226, y: 300),
            end: CGPoint(x: 798, y: 760),
            options: []
        )
    }
    context.restoreGState()

    // Knob
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -10),
        blur: 26,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45)
    )
    let knobRect = CGRect(x: 324, y: 324, width: 376, height: 376)
    context.addEllipse(in: knobRect)
    context.setFillColor(CGColor(red: 0.86, green: 0.88, blue: 0.92, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addEllipse(in: knobRect)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1),
            CGColor(red: 0.72, green: 0.75, blue: 0.80, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 400, y: 700),
            end: CGPoint(x: 640, y: 324),
            options: []
        )
    }
    context.restoreGState()

    // Pointer, aimed at the bright end of the sweep.
    context.saveGState()
    context.translateBy(x: centre.x, y: centre.y)
    // Clockwise, so the pointer sits over the warm end of the sweep. Turning it
    // the other way puts it over the cold end, which reads as turned down.
    context.rotate(by: -.pi * 0.3)
    context.translateBy(x: -centre.x, y: -centre.y)
    let pointer = CGPath(
        roundedRect: CGRect(x: 492, y: 546, width: 40, height: 122),
        cornerWidth: 20,
        cornerHeight: 20,
        transform: nil
    )
    context.addPath(pointer)
    context.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1))
    context.fillPath()
    context.restoreGState()
}

func writePNG(size: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }

    drawIcon(size: CGFloat(size), into: context)

    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes iconutil expects, each with its @2x companion.
for base in [16, 32, 128, 256, 512] {
    try writePNG(size: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(
        size: base * 2,
        to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png")
    )
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = [
    "-c", "icns",
    iconset.path,
    "-o", root.appendingPathComponent("Resources/AppIcon.icns").path,
]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else { exit(convert.terminationStatus) }

try FileManager.default.removeItem(at: iconset)
print("Wrote Resources/AppIcon.icns")
