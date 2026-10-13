// Writes the gallery's contact sheet: out/gallery/index.html with every screenshot of the native
// engine next to the lab's (same session, same step), a note per image whether the pixels are
// identical, and for differing pairs a difference image (out/gallery/diff/NAME.png: the native
// frame dimmed, differing pixels in red).
//
//     swift Scripts/gallery/index.swift <gallery dir> <sessions dir>
//
// Captions come from the sessions' "#: NAME: caption" comment lines. Run by Scripts/gallery/gallery.sh.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: swift index.swift <gallery dir> <sessions dir>\n".utf8))
    exit(2)
}
let gallery = URL(fileURLWithPath: args[1], isDirectory: true)
let sessions = URL(fileURLWithPath: args[2], isDirectory: true)
let fm = FileManager.default

/// Captions and order from the session files.
var captions: [String: String] = [:]
var order: [String] = []
for file in (try fm.contentsOfDirectory(atPath: sessions.path)).filter({ $0.hasSuffix(".txt") }).sorted() {
    let text = try String(contentsOf: sessions.appendingPathComponent(file), encoding: .utf8)
    for line in text.split(separator: "\n") where line.hasPrefix("#: ") {
        let body = line.dropFirst(3)
        guard let colon = body.firstIndex(of: ":") else { continue }
        let name = String(body[..<colon])
        captions[name] = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
}

/// RGBA pixels of a PNG.
func pixels(_ url: URL) -> (width: Int, height: Int, data: [UInt8])? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ok = data.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (w, h, data) : nil
}

func writePNG(_ data: [UInt8], width: Int, height: Int, to url: URL) {
    var copy = data
    copy.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

/// The VIC frame the PNGs scale up (`VICPresenter`): 384 × 248, frame row 0 = raster line 27.
let frameWidth = 384, frameHeight = 248, firstRasterLine = 27

let diffDir = gallery.appendingPathComponent("diff")
try fm.createDirectory(at: diffDir, withIntermediateDirectories: true)

/// One pair: the image paths relative to the gallery, the note, whether a difference image exists.
struct Row { var name: String; var native: String; var lab: String; var note: String; var identical: Bool; var diff: String? }

/// Compares two PNGs pixel by pixel; writes a difference image when they differ.
func compare(name: String, native nativePath: String, lab labPath: String) -> Row {
    var row = Row(name: name, native: nativePath, lab: labPath, note: "", identical: false, diff: nil)
    let n = pixels(gallery.appendingPathComponent(nativePath))
    let l = pixels(gallery.appendingPathComponent(labPath))
    guard let n, let l else {
        row.note = n == nil ? "no native image" : "no lab image"
        return row
    }
    guard n.width == l.width && n.height == l.height else {
        row.note = "sizes differ"
        return row
    }
    var differing = 0
    var diff = [UInt8](repeating: 0, count: n.data.count)
    for p in 0..<(n.width * n.height) {
        let i = p * 4
        let same = n.data[i] == l.data[i] && n.data[i + 1] == l.data[i + 1] && n.data[i + 2] == l.data[i + 2]
        if same {
            for c in 0..<3 { diff[i + c] = n.data[i + c] / 4 }
        } else {
            differing += 1
            diff[i] = 255; diff[i + 1] = 0; diff[i + 2] = 0
        }
        diff[i + 3] = 255
    }
    if differing == 0 {
        row.note = "pixel-identical"
        row.identical = true
    } else {
        row.diff = "diff/\(name).png"
        writePNG(diff, width: n.width, height: n.height, to: gallery.appendingPathComponent(row.diff!))
        // Count in C64 frame pixels (384 × 248, the PNGs are scaled) and say where they are.
        let sx = n.width / frameWidth, sy = n.height / frameHeight
        var window = 0, panel = 0, border = 0, splitLine = 0, total = 0
        for fy in 0..<frameHeight {
            for fx in 0..<frameWidth {
                let i = ((fy * sy) * n.width + fx * sx) * 4
                guard n.data[i] != l.data[i] || n.data[i + 1] != l.data[i + 1] || n.data[i + 2] != l.data[i + 2] else { continue }
                total += 1
                let raster = fy + firstRasterLine
                if raster == 0xA3 { splitLine += 1 }
                if fx < 32 || fx >= 352 || raster < 0x33 || raster > 0xFA { border += 1 }
                else if raster <= 0xA3 { window += 1 } else { panel += 1 }
            }
        }
        var note = String(format: "%d of %d frame pixels differ (%.2f%%): %d in the window, %d in the panel, %d in the border",
                          total, frameWidth * frameHeight, Double(total) / Double(frameWidth * frameHeight) * 100,
                          window, panel, border)
        if splitLine == total {
            note = "Only raster line $A3 differs (\(total) border pixels): on that badline the lab's line-granular VIC "
                + "model shows the panel's border color or the window's depending on where the raster IRQ lands in the "
                + "instruction stream; the port always shows the window state through line $A3 (re/docs/engine.md). "
                + "Otherwise pixel-identical."
        }
        row.note = note
    }
    return row
}

func pngNames(_ dir: String) -> [String] {
    ((try? fm.contentsOfDirectory(atPath: gallery.appendingPathComponent(dir).path)) ?? [])
        .filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) }.sorted()
}

/// The headless screenshots: native/NAME.png against lab/NAME.png.
let rows = Set(pngNames("native") + pngNames("lab")).sorted().map {
    compare(name: $0, native: "native/\($0).png", lab: "lab/\($0).png")
}
/// The replays' last checkpoints (`ReplayMatrixTests`): replay/SESSION-native.png against -lab.png.
let replayRows = Set(pngNames("replay").compactMap { n -> String? in
    n.hasSuffix("-native") ? String(n.dropLast(7)) : n.hasSuffix("-lab") ? String(n.dropLast(4)) : nil
}).sorted().map { compare(name: "replay-\($0)", native: "replay/\($0)-native.png", lab: "replay/\($0)-lab.png") }

func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

let identical = rows.filter(\.identical).count
let splitOnly = rows.filter { $0.note.hasPrefix("Only raster line $A3") }.count
let replayIdentical = replayRows.filter(\.identical).count
var html = """
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>FS2 Screenshot Gallery</title>
<style>
:root { --bg: #f6f6f4; --fg: #1d1d1b; --muted: #6b6b66; --card: #ffffff; --line: #deddd8; --ok: #1f7a3a; --bad: #a3361f; }
@media (prefers-color-scheme: dark) { :root { --bg: #161615; --fg: #ecebe6; --muted: #9b9a94; --card: #1f1f1d; --line: #33322f; --ok: #6fcf8a; --bad: #f08a70; } }
body { margin: 0; padding: 24px 16px; background: var(--bg); color: var(--fg); font: 15px/1.45 -apple-system, system-ui, sans-serif; }
h1 { font-size: 22px; margin: 0 0 4px; }
p.lead { color: var(--muted); margin: 0 0 20px; max-width: 70em; }
.shot { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 14px; margin: 0 0 18px; }
.shot h2 { font-size: 15px; margin: 0 0 2px; font-family: ui-monospace, Menlo, monospace; }
.shot .caption { margin: 0 0 6px; }
.note { font-weight: 600; margin: 0 0 10px; }
.note.ok { color: var(--ok); } .note.bad { color: var(--bad); }
.pair { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 10px; }
figure { margin: 0; }
figure img { width: 100%; height: auto; image-rendering: pixelated; border-radius: 4px; display: block; }
figcaption { color: var(--muted); font-size: 13px; margin-top: 4px; }
</style></head><body>
<h1>Flight Simulator II: native engine vs. lab</h1>
<p class="lead">Each pair is the same headless session (<code>FS2 --headless --quick-boot</code>) played on the native engine
(the Swift port) and on the lab (the original 6502 program), with the screenshot taken at the same session step.
\(identical) of \(rows.count) pairs are pixel-identical, and \(splitOnly) more differ only on raster line $A3 (the split
line, see the note). In normal (non-replay) mode the two engines run on different clocks: the port charges modeled cycle
costs, and the lab executes cycles and adds the VIC's DMA. A main-loop pass therefore ends a little earlier on the port
(about 7% per pass, measured by <code>PacingTests</code>). The session steps drift apart too: while a disk load is charged
the native engine delivers the load's frames in a catch-up burst, and a <code>wait</code> step running into one ends that burst
first, so on the native engine a step during a load spans more frames than on the lab (up to 2.7 times as many). Pairs
taken mid-flight show the same scene a pass or more apart, and the needles, digits and flight paths have moved on by
different amounts.</p>

"""
func section(_ r: Row, nativeLabel: String, labLabel: String) -> String {
    var s = "<section class=\"shot\"><h2>\(escape(r.name))</h2>"
    if let c = captions[r.name] { s += "<p class=\"caption\">\(escape(c))</p>" }
    s += "<p class=\"note \(r.identical ? "ok" : "bad")\">\(escape(r.note))</p><div class=\"pair\">"
    s += "<figure><img src=\"\(r.native)\" alt=\"native \(escape(r.name))\"><figcaption>\(nativeLabel)</figcaption></figure>"
    s += "<figure><img src=\"\(r.lab)\" alt=\"lab \(escape(r.name))\"><figcaption>\(labLabel)</figcaption></figure>"
    if let d = r.diff {
        s += "<figure><img src=\"\(d)\" alt=\"difference \(escape(r.name))\"><figcaption>difference (red)</figcaption></figure>"
    }
    return s + "</div></section>\n"
}
for r in rows { html += section(r, nativeLabel: "native engine", labLabel: "lab (original code)") }
if !replayRows.isEmpty {
    html += """
    <h1 style="margin-top:32px">Replays: the last checkpoint of every replay-matrix session</h1>
    <p class="lead">Each session in <code>re/sessions</code> was recorded in the lab and replayed through the native engine
    (<code>ReplayMatrixTests</code>). Each pair is the frame at the session's last main-loop checkpoint, from the port's
    machine and from the lab's RAM with the split its raster IRQ latched. \(replayIdentical) of \(replayRows.count) pairs are
    pixel-identical. The test compares every checkpoint this way, along with memory and the I/O registers.</p>

    """
    for r in replayRows { html += section(r, nativeLabel: "native engine (replay)", labLabel: "lab (recording)") }
}
html += "</body></html>\n"
try html.write(to: gallery.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
print("wrote \(gallery.appendingPathComponent("index.html").path): \(identical) of \(rows.count) headless pairs "
      + "pixel-identical (\(splitOnly) more differ only on line $A3); \(replayIdentical) of \(replayRows.count) replay pairs")
for r in rows + replayRows where !r.identical { print("  \(r.name): \(r.note)") }
