// Crops a PNG: crop.swift <in> <out> <x> <y> <width> <height> (pixels, origin top-left).
import AppKit
let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let r = CGRect(x: Double(a[3])!, y: Double(a[4])!, width: Double(a[5])!, height: Double(a[6])!)
let out = NSBitmapImageRep(cgImage: src.cropping(to: r)!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
