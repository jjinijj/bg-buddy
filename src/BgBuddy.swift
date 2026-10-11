// BgBuddy — Claude Code 백그라운드 작업을 캐릭터로 보여주는 macOS 플로팅 HUD.
//
// 감지 원리: Claude Code 는 세션마다 트랜스크립트(jsonl)를 남긴다.
//   시작 — tool_result 의 toolUseResult 에 backgroundTaskId(Bash) / isAsync(Agent) / taskId(Monitor 등)
//   끝   — <task-notification> 의 <status> (completed / failed …)
// 이 형식은 공개 API 가 아니므로, 모르는 모양은 죽지 않고 조용히 넘긴다.
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let testedClaudeVersion = "2.1.295"

struct BuddyError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - 경로·설정

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    // 앱 번들 바로 위 폴더(~/Applications/BgBuddy). 개발 중에는 BGBUDDY_HOME 으로 바꿀 수 있다.
    static let root: URL = {
        if let e = ProcessInfo.processInfo.environment["BGBUDDY_HOME"], !e.isEmpty {
            return URL(fileURLWithPath: (e as NSString).expandingTildeInPath)
        }
        let b = Bundle.main.bundleURL
        if b.pathExtension == "app" { return b.deletingLastPathComponent() }
        return home.appendingPathComponent("Applications/BgBuddy")
    }()
    static var config: URL { root.appendingPathComponent("config.json") }
    static var characters: URL { root.appendingPathComponent("characters") }
}

struct Config {
    var character = "default"
    var scale: Double?
    var bubbleSeconds = 15.0
    var sound: String?
    var hideWhenIdle = false
    var visible = true          // 캐릭터 보이기 (끄면 말풍선도 안 뜨고 메뉴 막대에만 표시)
    var menuBarIcon = true
    var size = 1.0              // 캐릭터 기본 크기에 곱하는 배율
    var ignoreKinds: Set<String> = []
    var maxTaskHours = 12.0
    var claudeDir: String?

    static func raw() -> [String: Any] {
        guard let d = try? Data(contentsOf: Paths.config),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }

    static func load() -> Config {
        let j = raw()
        var c = Config()
        if let v = j["character"] as? String, !v.isEmpty { c.character = v }
        if let v = j["scale"] as? Double, v > 0 { c.scale = v }
        if let v = j["bubble_seconds"] as? Double { c.bubbleSeconds = v }
        if let v = j["sound"] as? String, !v.isEmpty { c.sound = v }
        if let v = j["hide_when_idle"] as? Bool { c.hideWhenIdle = v }
        if let v = j["visible"] as? Bool { c.visible = v }
        if let v = j["menu_bar_icon"] as? Bool { c.menuBarIcon = v }
        if let v = j["size"] as? Double, v > 0 { c.size = v }
        if let v = j["ignore_kinds"] as? [String] { c.ignoreKinds = Set(v.map { $0.lowercased() }) }
        if let v = j["max_task_hours"] as? Double, v > 0 { c.maxTaskHours = v }
        if let v = j["claude_dir"] as? String, !v.isEmpty { c.claudeDir = v }
        return c
    }

    // 다른 키는 그대로 두고 하나만 바꾼다. nil 이면 키를 지운다.
    static func set(_ key: String, _ value: Any?) throws {
        var j = raw()
        if let v = value { j[key] = v } else { j.removeValue(forKey: key) }
        let d = try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: Paths.root, withIntermediateDirectories: true)
        try d.write(to: Paths.config, options: .atomic)
    }

    // 로그인 시 LaunchAgent 로 뜨면 셸 환경변수를 못 받으므로 config 의 claude_dir 이 우선한다.
    var claudeRoot: URL {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        if let p = claudeDir ?? env, !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return Paths.home.appendingPathComponent(".claude")
    }
}

// MARK: - 캐릭터

struct Anim {
    var frames: [Int]
    var fps: Double
    var loop: Bool
    var bob = 0.0            // 프레임마다 통통 튀는 높이(pt). 그림이 거의 같은 프레임도 움직여 보이게 한다
    var extras: [Anim] = []  // 반복하는 동안 가끔 한 번씩 끼워 넣는 동작
    var every = (min: 20.0, max: 60.0)
    var duration: Double { Double(frames.count) / max(fps, 0.1) }
}

final class Character {
    let name: String
    let frames: [CGImage]
    let frameSize: CGSize
    let scale: CGFloat
    let pixelated: Bool
    private let anims: [String: Anim]

    init(name: String, frames: [CGImage], frameSize: CGSize, scale: CGFloat, pixelated: Bool, anims: [String: Anim]) {
        self.name = name; self.frames = frames; self.frameSize = frameSize
        self.scale = scale; self.pixelated = pixelated; self.anims = anims
    }

    var displaySize: CGSize { CGSize(width: frameSize.width * scale, height: frameSize.height * scale) }

    // 상태별 애니메이션. 캐릭터에 없으면 비슷한 것으로 대신한다.
    func anim(_ state: String) -> Anim {
        let chain: [String: [String]] = [
            "working": ["working", "idle"], "done": ["done", "working", "idle"],
            "failed": ["failed", "idle", "working"], "idle": ["idle", "working"],
        ]
        for k in chain[state] ?? [state] { if let a = anims[k] { return a } }
        return Anim(frames: [0], fps: 1, loop: true)
    }

    static func available() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Paths.characters.path) else { return [] }
        return names.filter {
            fm.fileExists(atPath: Paths.characters.appendingPathComponent("\($0)/character.json").path)
        }.sorted()
    }

    static func load(_ name: String, scaleOverride: Double? = nil, size: Double = 1) throws -> Character {
        let dir = Paths.characters.appendingPathComponent(name)
        let jf = dir.appendingPathComponent("character.json")
        guard let d = try? Data(contentsOf: jf) else { throw BuddyError("캐릭터 '\(name)' 없음: \(jf.path)") }
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw BuddyError("\(jf.path) 의 JSON 형식이 잘못됨")
        }
        let sheetURL = dir.appendingPathComponent(j["sheet"] as? String ?? "sheet.png")
        guard let src = CGImageSourceCreateWithURL(sheetURL as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw BuddyError("스프라이트 시트를 열 수 없음: \(sheetURL.path)")
        }
        let fw = (j["frameWidth"] as? Int) ?? sheet.width
        let fh = (j["frameHeight"] as? Int) ?? sheet.height
        guard fw > 0, fh > 0, fw <= sheet.width, fh <= sheet.height else {
            throw BuddyError("frameWidth/frameHeight(\(fw)×\(fh))가 시트(\(sheet.width)×\(sheet.height))와 맞지 않음")
        }
        let cols = sheet.width / fw, rows = sheet.height / fh
        let count = min((j["frameCount"] as? Int) ?? cols * rows, cols * rows)
        var frames: [CGImage] = []
        for i in 0..<count {
            if let f = sheet.cropping(to: CGRect(x: (i % cols) * fw, y: (i / cols) * fh, width: fw, height: fh)) {
                frames.append(f)
            }
        }
        guard !frames.isEmpty else { throw BuddyError("프레임이 없음") }
        var anims: [String: Anim] = [:]
        func parse(_ name: String, _ a: [String: Any], loop defaultLoop: Bool) throws -> Anim? {
            guard let fr = a["frames"] as? [Int], !fr.isEmpty else { return nil }
            if let bad = fr.first(where: { $0 < 0 || $0 >= frames.count }) {
                throw BuddyError("애니메이션 '\(name)' 의 프레임 \(bad) 이 범위(0~\(frames.count - 1))를 벗어남")
            }
            var an = Anim(frames: fr, fps: (a["fps"] as? Double) ?? 4, loop: (a["loop"] as? Bool) ?? defaultLoop,
                          bob: (a["bob"] as? Double) ?? 0)
            for (i, e) in ((a["extras"] as? [[String: Any]]) ?? []).enumerated() {
                if let x = try parse("\(name).extras[\(i)]", e, loop: false) { an.extras.append(x) }
            }
            if let ev = a["every"] as? [Double], ev.count == 2, ev[0] > 0, ev[1] >= ev[0] { an.every = (ev[0], ev[1]) }
            return an
        }
        for (k, v) in (j["animations"] as? [String: Any]) ?? [:] {
            if let a = v as? [String: Any], let an = try parse(k, a, loop: k != "done") { anims[k] = an }
        }
        let scale = CGFloat((scaleOverride ?? (j["scale"] as? Double) ?? 3) * size)
        return Character(name: name, frames: frames, frameSize: CGSize(width: fw, height: fh),
                         scale: scale, pixelated: (j["pixelated"] as? Bool) ?? true, anims: anims)
    }

    // 캐릭터 파일이 모두 깨졌어도 앱은 떠야 한다.
    static func fallback() -> Character {
        let s = 16
        let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 1, y: 0, width: 14, height: 12))
        ctx.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.5, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 2, y: 1, width: 12, height: 10))
        return Character(name: "fallback", frames: [ctx.makeImage()!], frameSize: CGSize(width: s, height: s),
                         scale: 3, pixelated: true, anims: [:])
    }
}

// MARK: - 스프라이트 시트 가져오기
//
// 이미지 생성 AI 가 준 시트는 흰 배경·압축 번짐·프레임마다 다른 크기가 흔하다.
// 배경을 지우고, 프레임을 찾아 줄 순서로 세우고, 픽셀아트면 원래 격자로 되돌린 뒤
// 발바닥을 맞춰 같은 칸에 담는다.

enum Importer {
    struct Options { var pixel: Double?; var align = "center"; var height = 72.0 }
    struct Box { var minX, minY, maxX, maxY: Int
        var w: Int { maxX - minX + 1 }; var h: Int { maxY - minY + 1 }
        var cx: Double { Double(minX + maxX) / 2 }; var cy: Double { Double(minY + maxY) / 2 }
        mutating func add(_ o: Box) { minX = min(minX, o.minX); minY = min(minY, o.minY); maxX = max(maxX, o.maxX); maxY = max(maxY, o.maxY) }
    }

    static func run(src: URL, name: String, opt: Options) throws -> String {
        guard let isrc = CGImageSourceCreateWithURL(src as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(isrc, 0, nil) else { throw BuddyError("이미지를 열 수 없음: \(src.path)") }
        let W = cg.width, H = cg.height, N = W * H
        var px = [UInt8](repeating: 0, count: N * 4)
        px.withUnsafeMutableBytes { p in
            let ctx = CGContext(data: p.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        }
        func rgb(_ i: Int) -> SIMD3<Float> { SIMD3(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2])) }
        func d2(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { let d = a - b; return (d * d).sum() }

        // 1) 배경
        var fg = [Bool](repeating: true, count: N)
        var transparent = 0
        for i in 0..<N where px[i * 4 + 3] < 128 { fg[i] = false; transparent += 1 }
        if transparent < N / 50 {
            // 투명 배경이 아니면 테두리에서 이어진 배경색만 지운다 — 캐릭터 안쪽의 흰색은 남긴다.
            let corners = [0, W - 1, (H - 1) * W, N - 1].map(rgb)
            let bg = corners.min { a, b in corners.map { d2(a, $0) }.reduce(0, +) < corners.map { d2(b, $0) }.reduce(0, +) }!
            var stack: [Int] = []
            for x in 0..<W { stack.append(x); stack.append((H - 1) * W + x) }
            for y in 0..<H { stack.append(y * W); stack.append(y * W + W - 1) }
            while let i = stack.popLast() {
                guard fg[i], d2(rgb(i), bg) < 60 * 60 else { continue }
                fg[i] = false
                let x = i % W, y = i / W
                if x > 0 { stack.append(i - 1) }; if x < W - 1 { stack.append(i + 1) }
                if y > 0 { stack.append(i - W) }; if y < H - 1 { stack.append(i + W) }
            }
        }

        // 2) 덩어리 → 프레임
        var label = [Int32](repeating: -1, count: N)
        var areas: [Int] = [], boxes: [Box] = []
        var stack: [Int] = []
        for s in 0..<N where fg[s] && label[s] < 0 {
            let id = Int32(areas.count)
            var area = 0, box = Box(minX: s % W, minY: s / W, maxX: s % W, maxY: s / W)
            label[s] = id; stack.append(s)
            while let i = stack.popLast() {
                area += 1
                let x = i % W, y = i / W
                box.add(Box(minX: x, minY: y, maxX: x, maxY: y))
                for (ok, j) in [(x > 0, i - 1), (x < W - 1, i + 1), (y > 0, i - W), (y < H - 1, i + W)] where ok && fg[j] && label[j] < 0 {
                    label[j] = id; stack.append(j)
                }
            }
            areas.append(area); boxes.append(box)
        }
        guard let maxArea = areas.max(), maxArea > 16 else { throw BuddyError("캐릭터를 찾지 못함 — 배경과 구분되는 그림이 있는지 확인") }
        var groupOf = [Int](repeating: -1, count: areas.count)
        var gbox: [Box] = []
        for c in areas.indices where areas[c] >= maxArea / 10 { groupOf[c] = gbox.count; gbox.append(boxes[c]) }
        let margin = max(W, H) / 30
        for c in areas.indices where groupOf[c] < 0 {
            // 떨어진 작은 조각(땀방울 등)은 가까운 프레임에 붙이고, 멀리 떨어진 잡티는 버린다.
            let b = boxes[c]
            let near = gbox.indices.filter {
                let g = gbox[$0]
                return b.cx >= Double(g.minX - margin) && b.cx <= Double(g.maxX + margin) && b.cy >= Double(g.minY - margin) && b.cy <= Double(g.maxY + margin)
            }.min { abs(gbox[$0].cx - b.cx) + abs(gbox[$0].cy - b.cy) < abs(gbox[$1].cx - b.cx) + abs(gbox[$1].cy - b.cy) }
            if let g = near { groupOf[c] = g; gbox[g].add(b) }
        }
        // 줄 단위로 위→아래, 줄 안에서 왼→오른
        let avgH = Double(gbox.map(\.h).reduce(0, +)) / Double(gbox.count)
        var order: [Int] = [], rowStart: Double? = nil, row: [Int] = []
        for g in gbox.indices.sorted(by: { gbox[$0].cy < gbox[$1].cy }) {
            if let r = rowStart, gbox[g].cy - r > avgH * 0.5 { order += row.sorted { gbox[$0].minX < gbox[$1].minX }; row = []; rowStart = nil }
            if rowStart == nil { rowStart = gbox[g].cy }
            row.append(g)
        }
        order += row.sorted { gbox[$0].minX < gbox[$1].minX }
        func member(_ i: Int, _ g: Int) -> Bool { label[i] >= 0 && groupOf[Int(label[i])] == g }

        // 3) 팔레트 — 압축 번짐으로 생긴 중간색은 가까운 대표색으로 흡수한다
        var samples: [SIMD3<Float>] = []
        let fgCount = fg.lazy.filter { $0 }.count
        let stride_ = max(1, fgCount / 60000)
        var k = 0
        for i in 0..<N where label[i] >= 0 && groupOf[Int(label[i])] >= 0 { if k % stride_ == 0 { samples.append(rgb(i)) }; k += 1 }
        let (pal, rare) = kmeans(samples, k: 8)
        var cls = [Int8](repeating: -1, count: N)
        for i in 0..<N where label[i] >= 0 && groupOf[Int(label[i])] >= 0 {
            var best = 0, bd = Float.greatestFiniteMagnitude, bestMajor = 0, bdMajor = Float.greatestFiniteMagnitude
            for (p, c) in pal.enumerated() {
                let d = d2(rgb(i), c)
                if d < bd { bd = d; best = p }
                if !rare[p] && d < bdMajor { bdMajor = d; bestMajor = p }
            }
            // 드문 색은 그 색에 정말 가까운 픽셀에만 쓴다 — 외곽선 번짐이 엉뚱하게 포인트색으로 칠해지지 않게
            cls[i] = Int8(rare[best] && bd > 40 * 40 ? bestMajor : best)
        }

        // 4) 픽셀 크기 — 같은 색이 이어지는 길이들이 모두 어떤 값의 배수에 가까우면 그게 한 칸
        var block = opt.pixel ?? 0
        if block == 0 {
            var hist = [Int](repeating: 0, count: 401)
            func runs(_ at: (Int) -> Int, _ len: Int, _ count: Int) {
                for line in 0..<count {
                    var run = 0, prev: Int8 = -2
                    for t in 0..<len {
                        let c = cls[at(line * 100000 + t)]
                        if c == prev { run += 1 } else { if prev >= 0 { hist[min(run, 400)] += 1 }; run = 1; prev = c }
                    }
                    if prev >= 0 { hist[min(run, 400)] += 1 }
                }
            }
            runs({ ($0 / 100000) * W + $0 % 100000 }, W, H)
            runs({ ($0 % 100000) * W + $0 / 100000 }, H, W)
            func fit(_ b: Double) -> Double {
                var ok = 0.0, all = 0.0
                for L in 1...400 where hist[L] > 0 {
                    all += Double(hist[L])
                    let m = (Double(L) / b).rounded()
                    if m >= 1 && abs(Double(L) - m * b) <= 0.2 * b { ok += Double(hist[L]) }
                }
                return all > 0 ? ok / all : 0
            }
            // 격자가 깨끗할 때만 되살린다. AI 가 그린 "픽셀아트"는 칸 크기가 들쭉날쭉해서(9~11px, 18~21px …)
            // 억지로 격자에 맞추면 외곽선이 뭉개진다 — 그때는 원본 해상도로 두고 색만 정리한다.
            let cands = stride(from: 2.0, through: 64.0, by: 0.25).map { ($0, fit($0)) }
            let top = cands.map(\.1).max() ?? 0
            if top >= 0.85, let b = cands.last(where: { $0.1 >= top * 0.95 }) { block = b.0 } else { block = 1 }
        }
        let isPixel = block >= 2

        // 5) 프레임마다 격자 위상을 맞춰 칸별 다수결로 원래 픽셀을 되살린다
        struct Frame { var w: Int; var h: Int; var px: [UInt8] }  // RGBA
        var frames: [Frame] = []
        for g in order {
            let b = gbox[g]
            if !isPixel {
                var out = [UInt8](repeating: 0, count: b.w * b.h * 4)
                for y in 0..<b.h { for x in 0..<b.w {
                    let i = (b.minY + y) * W + b.minX + x
                    guard member(i, g) else { continue }
                    let col = pal[Int(cls[i])], o = (y * b.w + x) * 4  // 대표색으로 맞춰 번짐을 없앤다
                    out[o] = UInt8(col.x.rounded()); out[o + 1] = UInt8(col.y.rounded()); out[o + 2] = UInt8(col.z.rounded()); out[o + 3] = 255
                } }
                frames.append(Frame(w: b.w, h: b.h, px: out)); continue
            }
            func phase(_ horizontal: Bool) -> Double {
                var sx = 0.0, sy = 0.0
                for y in b.minY...b.maxY { for x in b.minX...b.maxX {
                    let i = y * W + x
                    let j = horizontal ? (x > b.minX ? i - 1 : -1) : (y > b.minY ? i - W : -1)
                    guard j >= 0 else { continue }
                    let ci = member(i, g) ? cls[i] : -1, cj = member(j, g) ? cls[j] : -1
                    guard ci != cj else { continue }
                    let a = 2 * Double.pi * Double(horizontal ? x : y) / block
                    sx += cos(a); sy += sin(a)
                } }
                var p = atan2(sy, sx) / (2 * Double.pi) * block
                if p < 0 { p += block }
                return p
            }
            let px0 = phase(true), py0 = phase(false)
            let kx0 = Int(floor((Double(b.minX) - px0) / block)), kx1 = Int(ceil((Double(b.maxX + 1) - px0) / block))
            let ky0 = Int(floor((Double(b.minY) - py0) / block)), ky1 = Int(ceil((Double(b.maxY + 1) - py0) / block))
            let gw = kx1 - kx0, gh = ky1 - ky0
            var grid = [Int8](repeating: -1, count: gw * gh)
            for gy in 0..<gh { for gx in 0..<gw {
                let cx = px0 + (Double(kx0 + gx) + 0.5) * block, cy = py0 + (Double(ky0 + gy) + 0.5) * block
                let r = max(0.5, block * 0.3)
                var votes = [Int](repeating: 0, count: pal.count + 1)
                for y in Int((cy - r).rounded())...Int((cy + r).rounded()) { for x in Int((cx - r).rounded())...Int((cx + r).rounded()) {
                    guard x >= 0, y >= 0, x < W, y < H else { votes[0] += 1; continue }
                    let i = y * W + x
                    votes[member(i, g) ? Int(cls[i]) + 1 : 0] += 1
                } }
                let best = votes.indices.max { votes[$0] < votes[$1] }!
                grid[gy * gw + gx] = Int8(best - 1)
            } }
            // 빈 테두리 줄 잘라내기
            let filled = grid.indices.filter { grid[$0] >= 0 }
            guard !filled.isEmpty else { continue }
            let x0 = filled.map { $0 % gw }.min()!, x1 = filled.map { $0 % gw }.max()!
            let y0 = filled.map { $0 / gw }.min()!, y1 = filled.map { $0 / gw }.max()!
            let fw = x1 - x0 + 1, fh = y1 - y0 + 1
            var out = [UInt8](repeating: 0, count: fw * fh * 4)
            for y in 0..<fh { for x in 0..<fw {
                let c = grid[(y0 + y) * gw + x0 + x]
                guard c >= 0 else { continue }
                let col = pal[Int(c)], o = (y * fw + x) * 4
                out[o] = UInt8(col.x.rounded()); out[o + 1] = UInt8(col.y.rounded()); out[o + 2] = UInt8(col.z.rounded()); out[o + 3] = 255
            } }
            frames.append(Frame(w: fw, h: fh, px: out))
        }
        guard !frames.isEmpty else { throw BuddyError("프레임을 만들지 못함") }

        // 6) 같은 크기 칸에 발바닥(아래)을 맞춰 가로 한 줄로
        let cw = frames.map(\.w).max()!, ch = frames.map(\.h).max()!
        let sw = cw * frames.count
        var sheet = [UInt8](repeating: 0, count: sw * ch * 4)
        for (n, f) in frames.enumerated() {
            let ox = n * cw + (opt.align == "left" ? 0 : opt.align == "right" ? cw - f.w : (cw - f.w) / 2)
            let oy = ch - f.h
            for y in 0..<f.h { for x in 0..<f.w {
                let s = (y * f.w + x) * 4, d = ((oy + y) * sw + ox + x) * 4
                for c in 0..<4 { sheet[d + c] = f.px[s + c] }
            } }
        }
        let dir = Paths.characters.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writePNG(sheet, w: sw, h: ch, to: dir.appendingPathComponent("sheet.png"))
        let n = frames.count
        let scale = isPixel ? max(1, (opt.height / Double(ch)).rounded()) : opt.height / Double(ch)
        let anims: [String: Any] = [
            "working": ["frames": Array(0..<min(n, 4)), "fps": 4],
            "done": ["frames": [n - 1], "fps": 2, "loop": false],
            "failed": ["frames": [0], "fps": 1],
            "idle": ["frames": [0], "fps": 1],
        ]
        let json: [String: Any] = [
            "name": name, "sheet": "sheet.png", "frameWidth": cw, "frameHeight": ch, "frameCount": n,
            "scale": scale, "pixelated": isPixel, "animations": anims,
        ]
        let jd = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try jd.write(to: dir.appendingPathComponent("character.json"))
        let note = isPixel ? String(format: "한 칸 %.2fpx → ", block) : "격자 없음(원본 해상도 유지) · "
        return "프레임 \(n)개 · \(note)칸 크기 \(cw)×\(ch) · 팔레트 \(pal.count)색\n저장: \(dir.path)"
    }

    // 대표색과, 그중 드물게 쓰인 포인트색인지 여부
    static func kmeans(_ pts: [SIMD3<Float>], k: Int) -> ([SIMD3<Float>], [Bool]) {
        guard !pts.isEmpty else { return ([], []) }
        func d2(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { let d = a - b; return (d * d).sum() }
        // 가장 먼 점부터 고르는 초기화 — 적은 색 수의 그림에서 잘 맞는다
        var cs = [pts[0]]
        var near = pts.map { d2($0, pts[0]) }
        while cs.count < k, let far = near.indices.max(by: { near[$0] < near[$1] }), near[far] > 0 {
            cs.append(pts[far])
            for i in pts.indices { near[i] = min(near[i], d2(pts[i], pts[far])) }
        }
        var assign = [Int](repeating: 0, count: pts.count)
        for _ in 0..<12 {
            for (i, p) in pts.enumerated() { assign[i] = cs.indices.min { d2(p, cs[$0]) < d2(p, cs[$1]) }! }
            var sum = [SIMD3<Float>](repeating: .zero, count: cs.count), cnt = [Int](repeating: 0, count: cs.count)
            for (i, p) in pts.enumerated() { sum[assign[i]] += p; cnt[assign[i]] += 1 }
            for c in cs.indices where cnt[c] > 0 { cs[c] = sum[c] / Float(cnt[c]) }
        }
        var cnt = [Int](repeating: 0, count: cs.count)
        for a in assign { cnt[a] += 1 }
        // 드문 색(번짐)은 버리고, 비슷한 색은 합친다
        // 아주 드문 색(혀·볼터치 같은 작은 포인트)은 기존 대표색과 확실히 다를 때만 살린다 — 잡티는 대개 비슷한 색이다
        var keep = cs.indices.filter { cnt[$0] >= 8 && Double(cnt[$0]) >= Double(pts.count) * 0.0002 }.sorted { cnt[$0] > cnt[$1] }
        var out: [SIMD3<Float>] = [], major: [SIMD3<Float>] = [], isRare: [Bool] = []
        while let c = keep.first {
            keep.removeFirst()
            let p = cs[c]
            let rare = Double(cnt[c]) < Double(pts.count) * 0.003
            if rare ? major.contains(where: { d2($0, p) < 90 * 90 }) : out.contains(where: { d2($0, p) < 50 * 50 }) { continue }
            // 이미 고른 두 색을 섞은 중간색(외곽선 번짐)이면 버린다. 넓게 칠해진 색은 명암이므로 남긴다
            let blend = Double(cnt[c]) < Double(pts.count) * 0.05 && out.indices.contains { i in out.indices.contains { j in
                guard i < j else { return false }
                let a = out[i], ab = out[j] - a
                let t = ((p - a) * ab).sum() / max((ab * ab).sum(), 1)
                return t > 0.1 && t < 0.9 && d2(p, a + ab * t) < 22 * 22
            } }
            if !blend { out.append(p); isRare.append(rare); if !rare { major.append(p) } }
        }
        return out.isEmpty ? ([cs[0]], [false]) : (out, isRare)
    }

    static func writePNG(_ rgba: [UInt8], w: Int, h: Int, to url: URL) throws {
        var data = rgba
        let img: CGImage? = data.withUnsafeMutableBytes { p in
            CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image = img,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BuddyError("PNG 저장 실패: \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw BuddyError("PNG 저장 실패: \(url.path)") }
    }
}

// MARK: - 백그라운드 작업 추적

struct BgTask {
    let key: String          // tool_use id
    let taskId: String
    let kind: String         // bash / agent / monitor / …
    let label: String
    var sessionName: String
    let startedAt: Date
}

struct Finished {
    let label: String
    let kind: String
    let status: String       // completed / failed / killed …
    let sessionName: String
    let startedAt: Date?
    let at: Date
    var ok: Bool { status == "completed" }
    var failed: Bool { status.hasPrefix("fail") || status == "error" }
}

final class SessionWatch {
    let sessionId: String
    let url: URL
    var name: String
    var version: String
    var offset: UInt64 = 0
    var partial = Data()
    var primed = false               // 첫 읽기(과거 기록)가 끝났는지. 과거 알림으로는 말풍선을 띄우지 않는다
    var tools: [String: (name: String, label: String)] = [:]
    var running: [String: BgTask] = [:]
    var ended: Set<String> = []
    var history: [Finished] = []
    var starts = 0, notes = 0, unknownNotes = 0

    init(sessionId: String, url: URL, name: String, version: String) {
        self.sessionId = sessionId; self.url = url; self.name = name; self.version = version
    }

    func reset() {
        offset = 0; partial = Data(); primed = false
        tools = [:]; running = [:]; ended = []; history = []
    }
}

final class Tracker {
    var config: Config
    private(set) var watches: [String: SessionWatch] = [:]
    private(set) var liveSessions = 0
    private(set) var versions: [String] = []
    private var lastRegistryScan = Date.distantPast

    init(config: Config) { self.config = config }

    var running: [BgTask] {
        watches.values.flatMap { w in w.running.values.map { var t = $0; t.sessionName = w.name; return t } }
            .filter { !config.ignoreKinds.contains($0.kind) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    // 한 번 훑고, 지금 막 끝난 작업을 돌려준다.
    func poll() -> [Finished] {
        if Date().timeIntervalSince(lastRegistryScan) > 3 { scanRegistry() }
        var out: [Finished] = []
        for w in watches.values { out += read(w) }
        let cutoff = Date().addingTimeInterval(-config.maxTaskHours * 3600)
        for w in watches.values { w.running = w.running.filter { $0.value.startedAt > cutoff } }
        return out
    }

    // ~/.claude/sessions/<pid>.json 은 실행 중인 세션 레지스트리. 죽은 pid 는 걸러낸다.
    func scanRegistry() {
        lastRegistryScan = Date()
        let dir = config.claudeRoot.appendingPathComponent("sessions")
        var live: [String: (name: String, version: String)] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".json") {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(f)),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let pid = (j["pid"] as? NSNumber)?.int32Value, let sid = j["sessionId"] as? String,
                  kill(pid, 0) == 0 || errno == EPERM else { continue }
            let cwdName = (j["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? "세션"
            live[sid] = ((j["name"] as? String) ?? cwdName, (j["version"] as? String) ?? "")
        }
        liveSessions = live.count
        versions = Array(Set(live.values.map(\.version).filter { !$0.isEmpty })).sorted()
        // 세션이 끝나면 남은 작업도 조용히 치운다 — 결과를 받을 쪽이 없다
        for sid in Array(watches.keys) where live[sid] == nil { watches.removeValue(forKey: sid) }
        for (sid, info) in live {
            if let w = watches[sid] { w.name = info.name; continue }
            if let url = findTranscript(sid) {
                watches[sid] = SessionWatch(sessionId: sid, url: url, name: info.name, version: info.version)
            }
        }
    }

    private func findTranscript(_ sid: String) -> URL? {
        let projects = config.claudeRoot.appendingPathComponent("projects")
        for d in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let u = projects.appendingPathComponent("\(d)/\(sid).jsonl")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private func read(_ w: SessionWatch) -> [Finished] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: w.url.path))?[.size] as? NSNumber else { return [] }
        let total = size.uint64Value
        if total < w.offset { w.reset() }
        if total == w.offset { w.primed = true; return [] }
        guard let fh = try? FileHandle(forReadingFrom: w.url) else { return [] }
        defer { try? fh.close() }
        // 아주 긴 세션은 처음 읽을 때 끝부분만 본다
        var start = w.offset, skipFirst = false
        let cap: UInt64 = 64 << 20
        if !w.primed && total - start > cap { start = total - cap; skipFirst = true }
        do { try fh.seek(toOffset: start) } catch { return [] }
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return [] }
        w.offset = start + UInt64(data.count)
        var buf = w.partial
        buf.append(data)
        let live = w.primed
        var out: [Finished] = []
        var lineStart = buf.startIndex
        while let nl = buf[lineStart...].firstIndex(of: 0x0A) {
            let line = buf[lineStart..<nl]
            lineStart = buf.index(after: nl)
            if skipFirst { skipFirst = false; continue }
            out += process(Data(line), w, live: live)
        }
        w.partial = Data(buf[lineStart...])
        w.primed = true
        return out
    }

    private static let pNote = Data("<task-notification>".utf8)
    private static let pToolUse = Data("\"tool_use\"".utf8)
    private static let pResult = Data("\"toolUseResult\"".utf8)

    private func process(_ line: Data, _ w: SessionWatch, live: Bool) -> [Finished] {
        let hasNote = line.range(of: Self.pNote) != nil
        let hasUse = line.range(of: Self.pToolUse) != nil
        let hasResult = line.range(of: Self.pResult) != nil
        guard hasNote || hasUse || hasResult,
              let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        let ts = Self.date(j["timestamp"] as? String)
        var out: [Finished] = []

        if hasNote {
            // 알림은 큐에 들어갈 때(enqueue), 사용자 메시지로 전달될 때 두 번 이상 기록된다. 먼저 온 것을 쓴다.
            var texts: [String] = []
            if (j["type"] as? String) == "queue-operation" {
                if (j["operation"] as? String) == "enqueue", let s = j["content"] as? String { texts.append(s) }
            } else if let m = j["message"] as? [String: Any] {
                if let s = m["content"] as? String { texts.append(s) }
                for b in (m["content"] as? [[String: Any]]) ?? [] where (b["type"] as? String) == "text" {
                    if let s = b["text"] as? String { texts.append(s) }
                }
            } else if let a = j["attachment"] as? [String: Any], (a["type"] as? String) == "queued_command",
                      let s = a["prompt"] as? String {
                texts.append(s)
            }
            // 시스템 프롬프트 안의 설명문에도 이 태그 이름이 나오므로, 태그로 시작하는 본문만 알림으로 본다
            for t in texts where t.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<task-notification>") {
                for seg in t.components(separatedBy: "<task-notification>").dropFirst() {
                    if let f = notification(seg, ts: ts, w, live: live) { out.append(f) }
                }
            }
        }

        let blocks = ((j["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        for b in blocks {
            switch b["type"] as? String {
            case "tool_use": toolUse(b, w)
            case "tool_result":
                if let r = j["toolUseResult"] as? [String: Any] { toolResult(b, r, ts: ts, w) }
            default: break
            }
        }
        return out
    }

    private func toolUse(_ b: [String: Any], _ w: SessionWatch) {
        guard let id = b["id"] as? String, let name = b["name"] as? String else { return }
        let input = b["input"] as? [String: Any] ?? [:]
        if ["TaskStop", "KillShell", "KillBash"].contains(name) {
            // 사용자가 멈춘 작업 — 말풍선 없이 치운다
            if let t = (input["task_id"] ?? input["shell_id"] ?? input["bash_id"]) as? String {
                for (k, task) in w.running where task.taskId == t || k == t { w.running.removeValue(forKey: k); w.ended.insert(k) }
                w.ended.insert(t)
            }
            return
        }
        var label = (input["description"] as? String) ?? ""
        if label.isEmpty, let c = input["command"] as? String { label = String(c.prefix(40)) }
        w.tools[id] = (name, label.isEmpty ? name : label)
    }

    private func toolResult(_ b: [String: Any], _ r: [String: Any], ts: Date?, _ w: SessionWatch) {
        guard let id = b["tool_use_id"] as? String else { return }
        let tool = w.tools.removeValue(forKey: id)
        guard !w.ended.contains(id), w.running[id] == nil else { return }
        let name = tool?.name ?? ""
        var taskId: String?
        if let t = r["backgroundTaskId"] as? String { taskId = t }                                   // Bash
        else if (r["isAsync"] as? Bool) == true { taskId = (r["agentId"] as? String) ?? id }        // Agent
        else if let t = r["taskId"] as? String, !name.isEmpty, !name.hasPrefix("Task") { taskId = t } // Monitor 등
        guard let tid = taskId, !w.ended.contains(tid) else { return }
        let desc = (r["description"] as? String) ?? ""
        let label = desc.isEmpty ? (tool?.label ?? (name.isEmpty ? "작업" : name)) : desc
        w.running[id] = BgTask(key: id, taskId: tid, kind: name.isEmpty ? "task" : name.lowercased(),
                               label: label, sessionName: w.name, startedAt: ts ?? Date())
        w.starts += 1
    }

    private func notification(_ s: String, ts: Date?, _ w: SessionWatch, live: Bool) -> Finished? {
        guard let status = Self.tag(s, "status")?.lowercased() else {
            // Monitor 의 중간 이벤트(<event>) 등은 끝난 게 아니다
            if Self.tag(s, "event") == nil && Self.tag(s, "task-type") == nil { w.unknownNotes += 1 }
            return nil
        }
        let ids = [Self.tag(s, "tool-use-id"), Self.tag(s, "task-id")].compactMap { $0 }
        guard !ids.isEmpty, !ids.contains(where: w.ended.contains) else { return nil }
        ids.forEach { w.ended.insert($0) }
        w.notes += 1
        var task: BgTask?
        if let u = Self.tag(s, "tool-use-id"), let t = w.running.removeValue(forKey: u) { task = t }
        else if let tid = Self.tag(s, "task-id"), let k = w.running.first(where: { $0.value.taskId == tid })?.key {
            task = w.running.removeValue(forKey: k)
        }
        let summary = Self.tag(s, "summary") ?? ""
        let f = Finished(label: task?.label ?? Self.quoted(summary) ?? summary, kind: task?.kind ?? "",
                         status: status, sessionName: w.name, startedAt: task?.startedAt, at: ts ?? Date())
        w.history.append(f)
        if w.history.count > 20 { w.history.removeFirst() }
        guard live else { return nil }
        // 시작을 못 본 작업이라도 방금 온 알림이면 알린다 — 시작 기록 형식이 바뀌어도 완료 알림은 살린다
        if task == nil && Date().timeIntervalSince(f.at) > 120 { return nil }
        if config.ignoreKinds.contains(f.kind) { return nil }
        return f
    }

    static func tag(_ s: String, _ name: String) -> String? {
        guard let a = s.range(of: "<\(name)>"),
              let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func quoted(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "\""), let b = s.lastIndex(of: "\""), a < b else { return nil }
        return String(s[s.index(after: a)..<b])
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(max(0, t))
    if s < 60 { return "\(s)초" }
    if s < 3600 { return s % 60 == 0 ? "\(s / 60)분" : "\(s / 60)분 \(s % 60)초" }
    return "\(s / 3600)시간 \((s % 3600) / 60)분"
}

// MARK: - 화면

enum Mood: String { case idle, working, done, failed }

struct Bubble {
    var title: String
    var body: String
    var sub: String
    var failed = false
    var seconds: Double?     // nil 이면 설정값
}

final class BuddyView: NSView {
    static let bubbleArea: CGFloat = 92

    var character: Character
    var mood: Mood = .idle
    var moodStart = Date()
    var bubble: Bubble?
    var queued = 0
    var badge = 0
    private(set) var spriteRect = NSRect.zero
    private(set) var bubbleRect: NSRect?

    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onMoved: (() -> Void)?

    init(character: Character) {
        self.character = character
        super.init(frame: NSRect(origin: .zero, size: BuddyView.size(for: character)))
    }
    required init?(coder: NSCoder) { fatalError() }

    static func size(for c: Character) -> NSSize {
        let s = c.displaySize
        return NSSize(width: max(260, ceil(s.width) + 24), height: ceil(s.height) + bubbleArea + 16)  // 16: 배지·bob 여유
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func layoutSprite() {
        let s = character.displaySize
        spriteRect = NSRect(x: ((bounds.width - s.width) / 2).rounded(), y: 2, width: s.width, height: s.height)
    }

    // 가끔 하는 동작이 재생 중이면 그것, 아니면 상태의 기본 동작
    private var extra: Anim?
    private var extraStart = Date()
    private var nextExtraAt: Date?

    func active() -> (anim: Anim, start: Date) {
        if let e = extra { return (e, extraStart) }
        return (character.anim(mood.rawValue), moodStart)
    }

    func resetExtras() { extra = nil; nextExtraAt = nil }

    // 기본 동작을 반복하다가 every 범위의 무작위 시점에 extras 중 하나를 한 번 재생한다
    func updateExtras(_ now: Date, force: Bool = false) {
        let base = character.anim(mood.rawValue)
        guard base.loop, !base.extras.isEmpty else { resetExtras(); return }
        if let e = extra {
            guard now.timeIntervalSince(extraStart) >= e.duration else { return }
            extra = nil; nextExtraAt = nil
        }
        if nextExtraAt == nil { nextExtraAt = now.addingTimeInterval(Double.random(in: base.every.min...base.every.max)) }
        if force || now >= nextExtraAt! { extra = base.extras.randomElement(); extraStart = now }
    }

    var hasExtras: Bool { !character.anim(mood.rawValue).extras.isEmpty }

    func currentFrame() -> Int {
        let (a, start) = active()
        var i = Int(Date().timeIntervalSince(start) * a.fps)
        i = a.loop ? i % a.frames.count : min(i, a.frames.count - 1)
        return a.frames[i]
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        layoutSprite()
        ctx.interpolationQuality = character.pixelated ? .none : .high
        let (a, start) = active()
        var r = spriteRect
        if a.bob > 0 {
            let phase = (Date().timeIntervalSince(start) * a.fps).truncatingRemainder(dividingBy: 1)
            r.origin.y += (CGFloat(a.bob) * CGFloat(sin(phase * .pi))).rounded()
        }
        ctx.draw(character.frames[currentFrame()], in: r)
        if badge > 1 { drawBadge() }
        bubbleRect = nil
        if let b = bubble { drawBubble(b) }
    }

    private func drawBadge() {
        let r = NSRect(x: spriteRect.maxX - 12, y: spriteRect.maxY - 12, width: 18, height: 18)
        NSColor(red: 1, green: 0.42, blue: 0.29, alpha: 1).setFill()
        NSBezierPath(ovalIn: r).fill()
        let s = NSAttributedString(string: "\(badge)", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white])
        let sz = s.size()
        s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }

    private func drawBubble(_ b: Bubble) {
        let ink = NSColor(white: 0.13, alpha: 1)
        let text = NSMutableAttributedString()
        let para = NSMutableParagraphStyle(); para.lineSpacing = 1; para.lineBreakMode = .byWordWrapping
        text.append(NSAttributedString(string: b.title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: ink, .paragraphStyle: para]))
        if !b.body.isEmpty {
            let body = b.body.count > 44 ? String(b.body.prefix(43)) + "…" : b.body
            text.append(NSAttributedString(string: "\n" + body, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink, .paragraphStyle: para]))
        }
        if !b.sub.isEmpty {
            text.append(NSAttributedString(string: "\n" + b.sub, attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor(white: 0.4, alpha: 1), .paragraphStyle: para]))
        }
        let maxW = bounds.width - 12
        let tr = text.boundingRect(with: NSSize(width: maxW - 22, height: 200), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let w = min(maxW, ceil(tr.width) + 22)
        let h = min(BuddyView.bubbleArea - 12, ceil(tr.height) + 14)
        let x = min(max(6, spriteRect.midX - w / 2), bounds.width - w - 6)
        let rect = NSRect(x: x, y: spriteRect.maxY + 10, width: w, height: h)
        bubbleRect = rect

        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        let tx = min(max(rect.minX + 14, spriteRect.midX), rect.maxX - 14)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: tx - 6, y: rect.minY + 1))
        tail.line(to: NSPoint(x: tx, y: rect.minY - 8))
        tail.line(to: NSPoint(x: tx + 6, y: rect.minY + 1))
        let fill = b.failed ? NSColor(red: 1, green: 0.92, blue: 0.91, alpha: 0.98) : NSColor(white: 1, alpha: 0.98)
        fill.setFill(); ink.setStroke()
        path.lineWidth = 1.5; tail.lineWidth = 1.5
        path.fill(); path.stroke()
        tail.fill(); tail.stroke()
        fill.setFill()
        NSBezierPath(rect: NSRect(x: tx - 5, y: rect.minY - 0.5, width: 10, height: 2.2)).fill()  // 꼬리와 몸통 사이 선 지우기
        text.draw(with: rect.insetBy(dx: 11, dy: 7), options: [.usesLineFragmentOrigin, .usesFontLeading])
        if queued > 0 {
            let q = NSAttributedString(string: "+\(queued)", attributes: [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor(white: 0.45, alpha: 1)])
            q.draw(at: NSPoint(x: rect.maxX - q.size().width - 7, y: rect.maxY - q.size().height - 4))
        }
    }

    func hit(_ p: NSPoint) -> Bool {
        spriteRect.insetBy(dx: -2, dy: -2).contains(p) || (bubbleRect?.insetBy(dx: -2, dy: -10).contains(p) ?? false)
    }

    // 직접 끌기 — 클릭과 드래그를 구분해야 해서 performDrag 대신 쓴다
    private var dragStart: NSPoint?, originStart: NSPoint?, dragged = false
    override func mouseDown(with e: NSEvent) {
        dragStart = NSEvent.mouseLocation; originStart = window?.frame.origin; dragged = false
    }
    override func mouseDragged(with e: NSEvent) {
        guard let s = dragStart, let o = originStart, let win = window else { return }
        let p = NSEvent.mouseLocation
        if abs(p.x - s.x) + abs(p.y - s.y) > 3 { dragged = true }
        if dragged { win.setFrameOrigin(NSPoint(x: o.x + p.x - s.x, y: o.y + p.y - s.y)) }
    }
    override func mouseUp(with e: NSEvent) {
        if dragged { onMoved?() } else { onClick?() }
        dragStart = nil
    }
    override func rightMouseDown(with e: NSEvent) { onMenu?(e) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: NSPanel!
    var statusItem: NSStatusItem?
    var doneMarkUntil: Date?        // 메뉴 막대에 ✓ 를 띄워 둘 시각
    var statusShown = ""
    var view: BuddyView!
    var config = Config.load()
    var tracker: Tracker!
    let queue = DispatchQueue(label: "bgbuddy.tracker")
    var polling = false
    var tasks: [BgTask] = []
    var bubbles: [Bubble] = []
    var bubbleShownAt = Date()
    var demoUntil: Date?
    var lastFrame = -1

    func applicationDidFinishLaunching(_ n: Notification) {
        // 먼저 뜬 인스턴스가 있을 때만 양보한다 — 둘이 동시에 뜨면 서로 양보해 둘 다 꺼지는 일을 막는다
        let me = NSRunningApplication.current
        let older = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.bgbuddy")
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
            .contains { ($0.launchDate ?? .distantPast) < (me.launchDate ?? .distantFuture) }
        if older { NSApp.terminate(nil); return }
        tracker = Tracker(config: config)
        view = BuddyView(character: loadCharacter())
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: view.frame.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = view
        placeWindow(anchor: savedAnchor())
        panel.orderFrontRegardless()
        updateStatusItem()

        view.onClick = { [weak self] in self?.clicked() }
        view.onMenu = { [weak self] e in self?.showMenu(e) }
        view.onMoved = { [weak self] in self?.saveAnchor() }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("local.bgbuddy.poke"), object: nil, queue: .main) { [weak self] n in
            self?.poke(n.object as? String ?? "done")
        }
        dnc.addObserver(forName: Notification.Name("local.bgbuddy.reload"), object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] _ in self?.tick() }
        poll()
    }

    func loadCharacter() -> Character {
        do { return try Character.load(config.character, scaleOverride: config.scale, size: config.size) }
        catch {
            NSLog("BgBuddy: \(error)")
            return (try? Character.load("default", scaleOverride: config.scale, size: config.size)) ?? Character.fallback()
        }
    }

    // MARK: 위치 — 캐릭터 발밑 가운데를 기준점으로 저장해서 캐릭터를 바꿔도 제자리에 선다

    func savedAnchor() -> NSPoint {
        let d = UserDefaults.standard
        if d.object(forKey: "anchorX") != nil {
            let p = NSPoint(x: d.double(forKey: "anchorX"), y: d.double(forKey: "anchorY"))
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: 20, dy: 20).contains(p) }) { return p }
        }
        let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: v.maxX - 90, y: v.minY + 16)
    }

    func placeWindow(anchor: NSPoint) {
        let s = view.frame.size
        panel.setFrame(NSRect(x: (anchor.x - s.width / 2).rounded(), y: anchor.y - 2, width: s.width, height: s.height), display: true)
    }

    func saveAnchor() {
        let f = panel.frame
        UserDefaults.standard.set(f.midX, forKey: "anchorX")
        UserDefaults.standard.set(f.minY + 2, forKey: "anchorY")
    }

    func reload() {
        config = Config.load()
        let anchor = NSPoint(x: panel.frame.midX, y: panel.frame.minY + 2)
        view.character = loadCharacter()
        view.resetExtras()  // 이전 캐릭터의 프레임 번호가 남지 않게
        view.setFrameSize(BuddyView.size(for: view.character))
        placeWindow(anchor: anchor)
        let c = config
        queue.async { self.tracker.config = c }
        updateStatusItem(rebuildIcon: true)
        view.needsDisplay = true
    }

    // MARK: 추적

    func poll() {
        guard !polling else { return }
        polling = true
        queue.async {
            let events = self.tracker.poll()
            let running = self.tracker.running
            DispatchQueue.main.async { self.apply(running, events); self.polling = false }
        }
    }

    func apply(_ running: [BgTask], _ events: [Finished]) {
        tasks = running
        view.badge = running.count
        let shown = events.filter { $0.ok || $0.failed }
        guard !shown.isEmpty else { refreshStatusTitle(); return }
        doneMarkUntil = Date().addingTimeInterval(max(config.bubbleSeconds, 15))
        refreshStatusTitle()
        // 캐릭터를 꺼 두었으면 말풍선을 쌓지 않는다 — 다시 켰을 때 지난 알림이 몰려 뜨지 않게
        guard config.visible else { return }
        if shown.count >= 3 {
            let labels = shown.map(\.label).joined(separator: ", ")
            let sessions = Array(Set(shown.map(\.sessionName))).sorted().joined(separator: ", ")
            let fails = shown.filter(\.failed).count
            bubbles.append(Bubble(title: "\(shown.count)개 끝났어!" + (fails > 0 ? " (실패 \(fails))" : ""),
                                  body: labels, sub: sessions, failed: fails == shown.count))
        } else {
            for f in shown {
                var sub = f.sessionName
                if let s = f.startedAt { sub += " · " + formatDuration(f.at.timeIntervalSince(s)) }
                bubbles.append(Bubble(title: f.ok ? "끝났어!" : "실패했어…", body: f.label, sub: sub, failed: f.failed))
            }
        }
        setMood(shown.contains(where: \.ok) ? .done : .failed)
        if let s = config.sound { NSSound(named: NSSound.Name(s))?.play() }
    }

    var baseMood: Mood {
        if !tasks.isEmpty { return .working }
        if let d = demoUntil, d > Date() { return .working }
        return .idle
    }

    func setMood(_ m: Mood) { view.mood = m; view.moodStart = Date(); view.resetExtras() }

    func tick() {
        let now = Date()
        if view.mood == .done || view.mood == .failed {
            let a = view.character.anim(view.mood.rawValue)
            if now.timeIntervalSince(view.moodStart) > max(a.loop ? 2.5 : a.duration + 1, 2.0) { setMood(baseMood) }
        } else if view.mood != baseMood {
            setMood(baseMood)
        }
        if view.bubble == nil, !bubbles.isEmpty { view.bubble = bubbles.removeFirst(); bubbleShownAt = now }
        if let b = view.bubble {
            let limit = b.seconds ?? config.bubbleSeconds
            if limit > 0, now.timeIntervalSince(bubbleShownAt) > limit { view.bubble = nil }
        }
        view.queued = bubbles.count

        // 캐릭터·말풍선 위에서만 마우스를 받고, 나머지 투명한 곳은 아래 창으로 통과시킨다
        let m = NSEvent.mouseLocation
        let p = NSPoint(x: m.x - panel.frame.minX, y: m.y - panel.frame.minY)
        panel.ignoresMouseEvents = !view.hit(p)
        view.toolTip = tasks.isEmpty ? nil : tasks.map { "· \($0.label) — \($0.sessionName) · \(formatDuration(now.timeIntervalSince($0.startedAt)))" }.joined(separator: "\n")

        let hide = !config.visible || (config.hideWhenIdle && baseMood == .idle && view.mood == .idle && view.bubble == nil)
        if let d = doneMarkUntil, d <= now { doneMarkUntil = nil; refreshStatusTitle() }
        if hide && panel.isVisible { panel.orderOut(nil) }
        if !hide && !panel.isVisible { panel.orderFrontRegardless() }

        let f = view.currentFrame()
        view.updateExtras(now)
        let moving = view.active().anim.bob > 0
        if f != lastFrame || moving || view.bubble != nil || view.needsDisplay { lastFrame = f; view.needsDisplay = true }
    }

    func clicked() {
        if view.bubble != nil { view.bubble = nil; view.needsDisplay = true; return }
        let now = Date()
        if tasks.isEmpty {
            view.bubble = Bubble(title: "쉬는 중", body: "돌고 있는 백그라운드 작업이 없어요", sub: "", seconds: 3)
        } else {
            let list = tasks.prefix(2).map { "\($0.label) (\(formatDuration(now.timeIntervalSince($0.startedAt))))" }.joined(separator: ", ")
            view.bubble = Bubble(title: "작업 \(tasks.count)개 진행 중", body: list,
                                 sub: tasks.count > 2 ? "외 \(tasks.count - 2)개" : tasks[0].sessionName, seconds: 4)
        }
        bubbleShownAt = now
        view.needsDisplay = true
    }

    func poke(_ kind: String) {
        let now = Date()
        func fake(_ label: String, _ status: String, _ ago: Double) -> Finished {
            Finished(label: label, kind: "test", status: status, sessionName: "테스트", startedAt: now.addingTimeInterval(-ago), at: now)
        }
        switch kind {
        case "working": demoUntil = now.addingTimeInterval(8)
        case "extra":
            if view.hasExtras { view.updateExtras(now, force: true) }
            else { view.bubble = Bubble(title: "가끔 하는 동작 없음", body: "지금 상태(\(view.mood.rawValue))에 extras 가 없어요", sub: "", seconds: 4); bubbleShownAt = now }
        case "failed": apply(tasks, [fake("테스트 작업", "failed", 42)])
        case "many": apply(tasks, [fake("데이터 정리", "completed", 95), fake("로그 분석", "completed", 130), fake("빌드", "failed", 61)])
        default: apply(tasks, [fake("테스트 작업", "completed", 133)])
        }
    }

    // MARK: 메뉴

    func showMenu(_ e: NSEvent) {
        let menu = NSMenu()
        fillMenu(menu)
        NSMenu.popUpContextMenu(menu, with: e, for: view)
    }

    // 메뉴 막대 아이콘 메뉴는 열 때마다 새로 채운다
    func menuNeedsUpdate(_ menu: NSMenu) { menu.removeAllItems(); fillMenu(menu) }

    func fillMenu(_ menu: NSMenu) {
        let now = Date()
        let vis = NSMenuItem(title: "캐릭터 보이기", action: #selector(toggleVisible), keyEquivalent: "")
        vis.target = self; vis.state = config.visible ? .on : .off
        menu.addItem(vis)
        menu.addItem(.separator())
        let head = NSMenuItem(title: tasks.isEmpty ? "백그라운드 작업 없음" : "백그라운드 작업 \(tasks.count)개", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        for t in tasks.prefix(12) {
            let it = NSMenuItem(title: "  \(t.label) — \(t.sessionName) · \(formatDuration(now.timeIntervalSince(t.startedAt)))", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }
        menu.addItem(.separator())

        let chars = NSMenu()
        for name in Character.available() {
            let it = NSMenuItem(title: name, action: #selector(pickCharacter(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = name
            it.state = name == view.character.name ? .on : .off
            chars.addItem(it)
        }
        let ci = NSMenuItem(title: "캐릭터", action: nil, keyEquivalent: ""); ci.submenu = chars
        menu.addItem(ci)

        let sizes = NSMenu()
        for (title, v) in [("작게", 0.75), ("기본", 1.0), ("크게", 1.5), ("아주 크게", 2.0)] {
            let it = NSMenuItem(title: title, action: #selector(pickSize(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = v
            it.state = abs(config.size - v) < 0.01 ? .on : .off
            sizes.addItem(it)
        }
        let si = NSMenuItem(title: "크기", action: nil, keyEquivalent: ""); si.submenu = sizes
        menu.addItem(si)

        let hide = NSMenuItem(title: "쉴 때 숨기기", action: #selector(toggleHide), keyEquivalent: "")
        hide.target = self; hide.state = config.hideWhenIdle ? .on : .off
        menu.addItem(hide)
        let icon = NSMenuItem(title: "메뉴 막대 아이콘", action: #selector(toggleIcon), keyEquivalent: "")
        icon.target = self; icon.state = config.menuBarIcon ? .on : .off
        menu.addItem(icon)
        let test = NSMenuItem(title: "말풍선 테스트", action: #selector(testBubble), keyEquivalent: "")
        test.target = self; test.isEnabled = config.visible
        menu.addItem(test)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    // MARK: 메뉴 막대 아이콘

    func updateStatusItem(rebuildIcon: Bool = false) {
        if !config.menuBarIcon {
            if let s = statusItem { NSStatusBar.system.removeStatusItem(s); statusItem = nil }
            return
        }
        if statusItem == nil {
            let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let m = NSMenu(); m.delegate = self
            s.menu = m
            s.button?.imagePosition = .imageLeading
            statusItem = s
            statusShown = ""
            rebuildStatusIcon()
        } else if rebuildIcon {
            rebuildStatusIcon()
        }
        refreshStatusTitle()
    }

    // 캐릭터의 쉬는 프레임을 메뉴 막대 높이에 맞춰 줄인다
    func rebuildStatusIcon() {
        guard let button = statusItem?.button else { return }
        let c = view.character
        let frame = c.frames[c.anim("idle").frames[0]]
        let h: CGFloat = 18, w = min(28, h * CGFloat(frame.width) / CGFloat(frame.height))
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.interpolationQuality = c.pixelated ? .none : .high
            let fw = CGFloat(frame.width), fh = CGFloat(frame.height)
            let s = min(r.width / fw, r.height / fh)
            ctx.draw(frame, in: CGRect(x: (r.width - fw * s) / 2, y: (r.height - fh * s) / 2, width: fw * s, height: fh * s))
            return true
        }
        button.image = img
        button.toolTip = "BG Buddy"
    }

    // 작업 수 / 방금 끝남(✓) / 꺼져 있음 표시. 바뀔 때만 다시 그린다
    func refreshStatusTitle() {
        guard let button = statusItem?.button else { return }
        var t = ""
        if !tasks.isEmpty { t = " \(tasks.count)" }
        else if doneMarkUntil != nil { t = " ✓" }
        if t != statusShown { button.title = t; statusShown = t }
        button.appearsDisabled = !config.visible
    }

    @objc func pickCharacter(_ s: NSMenuItem) {
        guard let name = s.representedObject as? String else { return }
        do {
            _ = try Character.load(name)
            try Config.set("character", name)
            reload()
        } catch {
            view.bubble = Bubble(title: "캐릭터를 못 열었어", body: "\(error)", sub: "", failed: true, seconds: 6)
            bubbleShownAt = Date()
        }
    }
    @objc func pickSize(_ s: NSMenuItem) { try? Config.set("size", (s.representedObject as? Double) ?? 1); reload() }
    @objc func toggleVisible() {
        // 아이콘까지 꺼져 있으면 다시 켤 방법이 없어지므로 캐릭터를 끌 때 아이콘을 살린다
        if config.visible && !config.menuBarIcon { try? Config.set("menu_bar_icon", true) }
        try? Config.set("visible", !config.visible); reload()
    }
    @objc func toggleIcon() {
        if config.menuBarIcon && !config.visible { try? Config.set("visible", true) }
        try? Config.set("menu_bar_icon", !config.menuBarIcon); reload()
    }
    @objc func toggleHide() { try? Config.set("hide_when_idle", !config.hideWhenIdle); reload() }
    @objc func testBubble() { poke("done") }
}

// MARK: - 명령줄

enum CLI {
    static func run(_ args: [String]) -> Int32 {
        do {
            switch args[0] {
            case "--tasks": return tasks(debug: args.contains("--debug"))
            case "--doctor": return doctor()
            case "--characters":
                let cur = Config.load().character
                for n in Character.available() { print((n == cur ? "* " : "  ") + n) }
                return 0
            case "--check-character":
                guard args.count > 1 else { throw BuddyError("캐릭터 이름이 필요함") }
                let c = try Character.load(args[1])
                print("\(c.name): 프레임 \(c.frames.count)개 · \(Int(c.frameSize.width))×\(Int(c.frameSize.height)) × \(c.scale)")
                return 0
            case "--import":
                guard args.count > 2 else { throw BuddyError("사용법: --import <이미지> <이름> [--pixel N] [--align center|left|right] [--height PT]") }
                var opt = Importer.Options()
                if let i = args.firstIndex(of: "--pixel"), i + 1 < args.count { opt.pixel = Double(args[i + 1]) }
                if let i = args.firstIndex(of: "--align"), i + 1 < args.count { opt.align = args[i + 1] }
                if let i = args.firstIndex(of: "--height"), i + 1 < args.count, let h = Double(args[i + 1]) { opt.height = h }
                let src = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
                print(try Importer.run(src: src, name: args[2], opt: opt))
                print("animations 의 프레임 번호는 character.json 에서 직접 고르세요 (0부터, 왼쪽→오른쪽).")
                return 0
            case "--poke":
                post("local.bgbuddy.poke", args.count > 1 ? args[1] : "done"); return 0
            case "--reload":
                post("local.bgbuddy.reload", nil); return 0
            case "--set":
                guard args.count > 2 else { throw BuddyError("사용법: --set <키> <값>") }
                let v = args[2]
                let value: Any? = v == "null" ? nil : v == "true" ? true : v == "false" ? false : (Double(v) as Any?) ?? v
                try Config.set(args[1], value)
                post("local.bgbuddy.reload", nil)
                return 0
            default:
                print("사용법: BgBuddy [--tasks [--debug] | --doctor | --characters | --check-character 이름 | --import 이미지 이름 | --poke 종류 | --reload | --set 키 값]")
                return 2
            }
        } catch {
            FileHandle.standardError.write(Data("오류: \(error)\n".utf8))
            return 1
        }
    }

    static func post(_ name: String, _ object: String?) {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(name), object: object, userInfo: nil, deliverImmediately: true)
    }

    static func tasks(debug: Bool) -> Int32 {
        let t = Tracker(config: Config.load())
        _ = t.poll()
        let now = Date()
        let run = t.running
        print(run.isEmpty ? "돌고 있는 백그라운드 작업 없음" : "돌고 있는 백그라운드 작업 \(run.count)개")
        for r in run {
            print("  ● [\(r.kind)] \(r.label) — \(r.sessionName) · \(formatDuration(now.timeIntervalSince(r.startedAt)))")
        }
        let recent = t.watches.values.flatMap(\.history).sorted { $0.at > $1.at }.prefix(5)
        if !recent.isEmpty {
            print("\n최근 끝난 작업")
            for f in recent {
                let mark = f.ok ? "✓" : f.failed ? "✗" : "·"
                print("  \(mark) \(f.label) — \(f.sessionName) · \(formatDuration(now.timeIntervalSince(f.at))) 전" + (f.ok || f.failed ? "" : " (\(f.status))"))
            }
        }
        if debug {
            print("\n세션별")
            for w in t.watches.values.sorted(by: { $0.name < $1.name }) {
                print("  \(w.name) [\(w.version)] 시작 \(w.starts) · 완료 알림 \(w.notes) · 모르는 알림 \(w.unknownNotes)")
                print("    \(w.url.path)")
            }
        }
        return 0
    }

    static func doctor() -> Int32 {
        let c = Config.load()
        var bad = 0
        func line(_ ok: Bool, _ s: String) { print((ok ? "  ✓ " : "  ✗ ") + s); if !ok { bad += 1 } }
        print("Claude Code")
        let root = c.claudeRoot
        line(FileManager.default.fileExists(atPath: root.path), "설정 폴더 \(root.path)")
        let t = Tracker(config: c)
        _ = t.poll()
        line(t.liveSessions > 0, "실행 중인 세션 \(t.liveSessions)개")
        if t.liveSessions > 0 {
            line(t.watches.count == t.liveSessions, "트랜스크립트 연결 \(t.watches.count)/\(t.liveSessions)")
        }
        let newer = t.versions.filter { isNewer($0, than: testedClaudeVersion) }
        print("  · 확인한 버전 \(testedClaudeVersion), 실행 중 \(t.versions.isEmpty ? "-" : t.versions.joined(separator: ", "))")
        if !newer.isEmpty { print("    더 새 버전이 있습니다. 감지가 이상하면 기록 형식이 바뀌었을 수 있습니다.") }
        let starts = t.watches.values.map(\.starts).reduce(0, +)
        let notes = t.watches.values.map(\.notes).reduce(0, +)
        let unknown = t.watches.values.map(\.unknownNotes).reduce(0, +)
        print("  · 읽은 기록: 작업 시작 \(starts)건 · 완료 알림 \(notes)건")
        line(unknown == 0, "모르는 형식의 알림 \(unknown)건")

        print("\n캐릭터")
        do {
            let ch = try Character.load(c.character, scaleOverride: c.scale)
            line(true, "현재 '\(ch.name)' — 프레임 \(ch.frames.count)개, \(Int(ch.frameSize.width))×\(Int(ch.frameSize.height)) × \(ch.scale)")
        } catch { line(false, "현재 '\(c.character)': \(error)") }
        print("  · 설치됨: \(Character.available().joined(separator: ", "))")
        print(bad == 0 ? "\n문제 없음" : "\n확인할 항목 \(bad)개")
        return bad == 0 ? 0 : 1
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

// MARK: - 시작

let cliArgs = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn") }
if let first = cliArgs.first, first.hasPrefix("--") {
    exit(CLI.run(Array(cliArgs)))
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
