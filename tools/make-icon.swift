// 기본 캐릭터 시트의 일부를 잘라 앱 아이콘을 만든다.
// 사용: swift tools/make-icon.swift <head|clipboard> <출력.iconset> [미리보기.png]
// 각 크기를 개별 렌더링해 작은 크기에서도 선명하게 유지한다.
import AppKit
import ImageIO

let args = CommandLine.arguments
let variant = args.count > 1 ? args[1] : "head"
let out = args.count > 2 ? args[2] : "AppIcon.iconset"
let preview = args.count > 3 ? args[3] : nil

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sheetURL = repo.appendingPathComponent("characters/default/sheet.png")
guard let src = CGImageSourceCreateWithURL(sheetURL as CFURL, nil),
      let sheet = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("시트를 열 수 없음: \(sheetURL.path)") }

// 시트 첫 프레임(160×199) 안의 잘라낼 영역. 좌표는 위에서부터.
struct Spec { let crop: CGRect; let top: NSColor; let bottom: NSColor; let peek: Bool }
let c = { (r: Int, g: Int, b: Int) in NSColor(calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
let specs: [String: Spec] = [
    // 머리 윗부분이 아이콘 아래 가장자리에서 빼꼼 올라온 모습
    "head": Spec(crop: CGRect(x: 4, y: 14, width: 152, height: 120), top: c(255, 246, 222), bottom: c(255, 222, 196), peek: true),
    // 손에 든 클립보드만
    "clipboard": Spec(crop: CGRect(x: 44, y: 130, width: 58, height: 52), top: c(232, 222, 252), bottom: c(196, 176, 232), peek: false),
]
guard let spec = specs[variant], let cropped = sheet.cropping(to: spec.crop) else { fatalError("종류는 head 또는 clipboard") }

// 클립보드만 남긴다: 갈색 판 주변 2픽셀 안의 외곽선까지만 두고, 몸통·손은 투명하게
func isolateBoard(_ img: CGImage) -> CGImage {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpaceCreateDeviceRGB(), info = CGImageAlphaInfo.premultipliedLast.rawValue
    px.withUnsafeMutableBytes { p in
        CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info)!
            .draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    func rgb(_ i: Int) -> (Int, Int, Int) { (Int(px[i * 4]), Int(px[i * 4 + 1]), Int(px[i * 4 + 2])) }
    let board = (0..<(w * h)).map { i -> Bool in let (r, g, b) = rgb(i); return px[i * 4 + 3] > 0 && r > 140 && r - b > 40 && g < 170 }
    let dark = (0..<(w * h)).map { i -> Bool in let (r, g, b) = rgb(i); return px[i * 4 + 3] > 0 && r + g + b < 200 }
    var keep = board
    for i in 0..<(w * h) where dark[i] {
        let x = i % w, y = i / w
        outer: for dy in -2...2 { for dx in -2...2 {
            let nx = x + dx, ny = y + dy
            if nx >= 0, ny >= 0, nx < w, ny < h, board[ny * w + nx] { keep[i] = true; break outer }
        } }
    }
    for i in 0..<(w * h) where !keep[i] { for k in 0..<4 { px[i * 4 + k] = 0 } }
    return px.withUnsafeMutableBytes { p in
        CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info)!.makeImage()!
    }
}
let part = variant == "clipboard" ? isolateBoard(cropped) : cropped

func render(_ size: Int) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS 아이콘 그리드: 여백을 두고 둥근 사각형
    let inset = s * 0.065
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.2237
    let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSGradient(starting: spec.top, ending: spec.bottom)?.draw(in: shape, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    ctx.interpolationQuality = .none
    let pw = CGFloat(part.width), ph = CGFloat(part.height)
    if spec.peek {
        // 폭을 타일의 84% 로 맞추고, 잘린 아랫면을 타일 아래 가장자리에 붙여 빼꼼 올라온 것처럼
        let k = tile.width * 0.84 / pw
        let w = pw * k, h = ph * k
        ctx.draw(part, in: CGRect(x: tile.midX - w / 2, y: tile.minY, width: w, height: h))
    } else {
        let k = min(tile.width * 0.74 / pw, tile.height * 0.74 / ph)
        let w = pw * k, h = ph * k
        ctx.draw(part, in: CGRect(x: tile.midX - w / 2, y: tile.midY - h / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()

    if size >= 64 {
        shape.lineWidth = max(1, s * 0.006)
        NSColor.black.withAlphaComponent(0.08).setStroke()
        shape.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let want: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in want {
    try? render(px)?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
if let p = preview { try? render(512)?.write(to: URL(fileURLWithPath: p)) }
print("저장: \(out)")
