import AppKit
import ApplicationServices
import ImageIO
import Darwin

// Only geometry and lifecycle AX attributes are read. No window titles or content.
let targetBundleID = "com.deepseek.dsh"
let targetAppPath = "/Applications/DeepSeek Harness.app"
let panelSize = CGSize(width: 110, height: 88)
let catBreeds = ["silver-siberian", "tuxedo", "sheltie"]
let colonySize = 3 // Permanent base pets and legacy v2 compatibility only.
let miniPanelSize = CGSize(width: 58, height: 56)
let maximumPacketBytes = 1_048_575 // JSON bytes; the terminating LF completes the1MiB pipe bound.

func emit(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    data.append(10)
    try? FileHandle.standardOutput.write(contentsOf: data)
}

enum CatMode: String { case idle, thinking, awaiting }
struct Assignment: Equatable {
    let mode: CatMode
    let epoch: Int
    static let idle = Assignment(mode: .idle, epoch: 0)
}
struct ColonyStatus: Equatable {
    let protocolVersion: Int
    let activeChats: Int
    let waitingChats: Int
    let overflow: Int
    let cats: [Assignment]
    static let idle = ColonyStatus(protocolVersion: 2, activeChats: 0, waitingChats: 0, overflow: 0, cats: Array(repeating: .idle, count: colonySize))
    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d <= 9_007_199_254_740_991, d.rounded() == d else { return nil }
        return Int(d)
    }
    static func decode(_ data: Data) -> ColonyStatus? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if value["version"] != nil {
            guard integer(value["version"]) == 2,
                  let active = integer(value["activeChats"]), let waiting = integer(value["waitingChats"]),
                  let overflow = integer(value["overflow"]), waiting <= active,
                  overflow == max(0, active - colonySize),
                  let slots = value["cats"] as? [[String: Any]], slots.count == colonySize else { return nil }
            var cats: [Assignment] = []
            for slot in slots {
                guard let name = slot["mode"] as? String, let mode = CatMode(rawValue: name),
                      let epoch = integer(slot["epoch"]) else { return nil }
                cats.append(Assignment(mode: mode, epoch: epoch))
            }
            return ColonyStatus(protocolVersion: 2, activeChats: active, waitingChats: waiting, overflow: overflow, cats: cats)
        }
        // Explicit migration only: old aggregate agent counts cannot preserve root ownership.
        guard let running = integer(value["running"]), let attention = integer(value["attention"]),
              integer(value["settled"]) != nil, integer(value["errors"]) != nil else { return nil }
        let active = max(running, attention)
        let occupied = min(colonySize, active), waiting = min(occupied, attention)
        let cats = (0..<colonySize).map { index in
            Assignment(mode: index < waiting ? .awaiting : (index < occupied ? .thinking : .idle), epoch: 0)
        }
        return ColonyStatus(protocolVersion: 1, activeChats: active, waitingChats: attention, overflow: max(0, active - colonySize), cats: cats)
    }
}

enum PetRole: String { case session, subagent, job }
struct PetSpec: Equatable {
    let id: String
    let role: PetRole
    let parent: String?
    let style: Int
    let assignment: Assignment
    var isMini: Bool { role != .session }
    var naturalSize: CGSize { isMini ? miniPanelSize : panelSize }
    static let bases = (0..<3).map { PetSpec(id: "s\($0)", role: .session, parent: nil, style: $0, assignment: .idle) }
    static func number(_ id: String, prefix: UInt8) -> Int? {
        let bytes = Array(id.utf8)
        guard bytes.count >= 2, bytes.count <= 17, bytes[0] == prefix,
              bytes.dropFirst().allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = Int(id.dropFirst()), number <= 9_007_199_254_740_991,
              id == String(UnicodeScalar(prefix)) + String(number) else { return nil }
        return number
    }
}
struct MenagerieStatus: Equatable {
    let protocolVersion: Int
    let activeChats: Int
    let waitingChats: Int
    let activeSubagents: Int
    let activeJobs: Int
    let pets: [PetSpec]
    static let idle = MenagerieStatus(protocolVersion: 3, activeChats: 0, waitingChats: 0, activeSubagents: 0, activeJobs: 0, pets: PetSpec.bases)
    static func decode(_ data: Data) -> MenagerieStatus? {
        guard data.count <= maximumPacketBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = ColonyStatus.integer(object["version"]) else { return nil }
        if version == 2 {
            guard let old = ColonyStatus.decode(data) else { return nil }
            let pets = old.cats.enumerated().map { PetSpec(id: "s\($0.offset)", role: .session, parent: nil, style: $0.offset, assignment: $0.element) }
            return MenagerieStatus(protocolVersion: 2, activeChats: old.activeChats, waitingChats: old.waitingChats, activeSubagents: 0, activeJobs: 0, pets: pets)
        }
        guard version == 3,
              let active = ColonyStatus.integer(object["activeChats"]), let waiting = ColonyStatus.integer(object["waitingChats"]),
              let subagents = ColonyStatus.integer(object["activeSubagents"]), let jobs = ColonyStatus.integer(object["activeJobs"]),
              let entries = object["pets"] as? [[String: Any]], entries.count >= 3 else { return nil }
        var pets: [PetSpec] = [], ids = Set<String>()
        for entry in entries {
            guard let id = entry["id"] as? String, ids.insert(id).inserted,
                  let roleName = entry["role"] as? String, let role = PetRole(rawValue: roleName),
                  let style = ColonyStatus.integer(entry["style"]), let epoch = ColonyStatus.integer(entry["epoch"]),
                  let modeName = entry["mode"] as? String, let mode = CatMode(rawValue: modeName), entry["parent"] != nil else { return nil }
            let prefix: UInt8 = role == .session ? 115 : (role == .subagent ? 97 : 106)
            guard let number = PetSpec.number(id, prefix: prefix) else { return nil }
            let parent: String?
            if entry["parent"] is NSNull { parent = nil }
            else if let value = entry["parent"] as? String, PetSpec.number(value, prefix: 115) != nil { parent = value }
            else { return nil }
            if role == .session {
                guard parent == nil, style == number, number < 3 || mode != .idle else { return nil }
            } else { guard mode == .thinking else { return nil } }
            pets.append(PetSpec(id: id, role: role, parent: parent, style: style, assignment: Assignment(mode: mode, epoch: epoch)))
        }
        let sessions = Dictionary(uniqueKeysWithValues: pets.filter { !$0.isMini }.map { ($0.id, $0) })
        guard ["s0", "s1", "s2"].allSatisfy({ sessions[$0] != nil }),
              pets.filter({ !$0.isMini && $0.assignment.mode != .idle }).count == active,
              pets.filter({ !$0.isMini && $0.assignment.mode == .awaiting }).count == waiting,
              pets.filter({ $0.role == .subagent }).count == subagents,
              pets.filter({ $0.role == .job }).count == jobs else { return nil }
        for pet in pets where pet.isMini {
            if let parent = pet.parent { guard let owner = sessions[parent], owner.style == pet.style else { return nil } }
        }
        return MenagerieStatus(protocolVersion: 3, activeChats: active, waitingChats: waiting, activeSubagents: subagents, activeJobs: jobs, pets: pets)
    }
}

// Pure deterministic behavior: no application state, window queries, or timers.
enum Pose: String { case rest, walk, lying, sleep, stretch, thinking, awaiting }
struct IdleBehavior {
    static let offsets: [TimeInterval] = [0, 12, 24]
    static let speeds: [CGFloat] = [18, 21, 16]
    static func sample(slot: Int, elapsed: TimeInterval) -> (pose: Pose, untilChange: TimeInterval) {
        let phase = (max(0, elapsed) + offsets[slot % colonySize]).truncatingRemainder(dividingBy: 40)
        let phases: [(TimeInterval, Pose)] = [(10, .walk), (14, .rest), (18, .lying), (38, .sleep), (40, .stretch)]
        for (end, pose) in phases {
            if phase < end { return (pose, end - phase) }
        }
        return (.walk, 10)
    }
}
struct CatState {
    var assignment = Assignment.idle
    var idleStarted: TimeInterval
    var modeStarted: TimeInterval
    var direction: CGFloat = 1
    var minX: CGFloat?
    var maxX: CGFloat?
    // NSWindow rounds origins to whole points. Never feed that rounded position
    // back into the integrator: a <1pt rightward step would be lost every tick.
    var logicalX: CGFloat?
    var walkDistance: CGFloat = 0
    var movementScale: CGFloat = 1
    var holdsGroup = false
    func speed(slot: Int) -> CGFloat { IdleBehavior.speeds[slot % colonySize] * movementScale }
    var travelBounds: (low: CGFloat, high: CGFloat)? {
        guard let low = minX, let high = maxX, low.isFinite, high.isFinite,
              floor(high) > ceil(low) else { return nil }
        return (ceil(low), floor(high))
    }
    mutating func advanceWalk(slot: Int, delta: TimeInterval, fallbackX: CGFloat) -> CGFloat? {
        guard let bounds = travelBounds, delta > 0 else { return nil }
        let next = Patrol.step(x: logicalX ?? fallbackX, low: bounds.low, high: bounds.high,
                               direction: direction, distance: speed(slot: slot) * CGFloat(delta))
        logicalX = next.x
        direction = next.direction
        return min(bounds.high, max(bounds.low, next.x.rounded()))
    }
    mutating func relocate(low: CGFloat, high: CGFloat, initial: CGFloat, fallbackX: CGFloat) -> CGFloat {
        var x = initial
        if let oldLow = minX, let oldHigh = maxX, oldHigh > oldLow {
            let progress = min(1, max(0, ((logicalX ?? fallbackX) - oldLow) / (oldHigh - oldLow)))
            x = low + progress * (high - low)
        }
        minX = low; maxX = high; logicalX = x
        return x
    }
    init(now: TimeInterval) { idleStarted = now; modeStarted = now }
    mutating func accept(_ next: Assignment, now: TimeInterval) {
        guard next != assignment else { return }
        if next.mode != assignment.mode || next.epoch != assignment.epoch {
            modeStarted = now
            if next.mode == .idle { idleStarted = now }
        }
        assignment = next
    }
    func pose(slot: Int, now: TimeInterval, reduceMotion: Bool) -> Pose {
        switch assignment.mode {
        case .thinking: return .thinking
        case .awaiting: return .awaiting
        case .idle:
            if reduceMotion { return slot % colonySize == 2 ? .sleep : .rest }
            if holdsGroup { return .rest }
            let requested = IdleBehavior.sample(slot: slot, elapsed: now - idleStarted).pose
            return requested == .walk && travelBounds == nil ? .rest : requested
        }
    }
}

enum ColonyAnimation {
    static func frameInterval(poses: [Pose]) -> TimeInterval {
        if poses.contains(.walk) { return 1.0 / 24.0 }
        if poses.contains(.thinking) { return 0.5 }
        return .infinity
    }
}
enum Patrol {
    static func step(x: CGFloat, low: CGFloat, high: CGFloat, direction: CGFloat, distance: CGFloat) -> (x: CGFloat, direction: CGFloat) {
        let span = high - low
        guard span > 0 else { return (low, direction) }
        let offset = min(span, max(0, x - low))
        let phase = direction >= 0 ? offset : 2 * span - offset
        let next = (phase + max(0, distance)).truncatingRemainder(dividingBy: 2 * span)
        return next <= span ? (low + next, 1) : (low + 2 * span - next, -1)
    }
}

struct Placement {
    // AX uses top-left origin in primary-display coordinates; AppKit uses bottom-left.
    struct Layout { let frame: CGRect; let minX: CGFloat; let maxX: CGFloat }
    static func layout(window: CGRect, primaryTop: CGFloat, screens: [CGRect]) -> [Layout]? {
        guard window.width >= panelSize.width * CGFloat(colonySize), window.height > 0,
              [window.minX, window.minY, window.width, window.height, primaryTop].allSatisfy({ $0.isFinite }) else { return nil }
        let cocoaWindow = CGRect(x: window.minX, y: primaryTop - window.maxY, width: window.width, height: window.height)
        guard let screen = screens.max(by: {
            let a = $0.intersection(cocoaWindow), b = $1.intersection(cocoaWindow)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }), !screen.intersection(cocoaWindow).isNull else { return nil }
        let top = primaryTop - window.minY
        let left = max(screen.minX, cocoaWindow.minX)
        let right = min(screen.maxX, cocoaWindow.maxX)
        guard right - left >= panelSize.width * CGFloat(colonySize), top >= screen.minY,
              top + panelSize.height <= screen.maxY else { return nil }
        let segmentWidth = (right - left) / CGFloat(colonySize)
        return (0..<colonySize).map { slot in
            let low = left + CGFloat(slot) * segmentWidth
            let high = left + CGFloat(slot + 1) * segmentWidth - panelSize.width
            return Layout(frame: CGRect(x: (low + high) / 2, y: top, width: panelSize.width, height: panelSize.height), minX: low, maxX: high)
        }
    }
}

struct PetLayout {
    let id: String
    let frame: CGRect
    let minX: CGFloat
    let maxX: CGFloat
    let scale: CGFloat
    let hasMinis: Bool
}
enum MenageriePlacement {
    static func ordered(_ pets: [PetSpec]) -> [PetSpec] {
        let mains = pets.filter { !$0.isMini }.sorted { $0.style < $1.style }
        var children: [String: [PetSpec]] = [:], unowned: [PetSpec] = []
        for pet in pets where pet.isMini {
            if let parent = pet.parent { children[parent, default: []].append(pet) }
            else { unowned.append(pet) }
        }
        return mains.flatMap { [$0] + (children[$0.id] ?? []).sorted { $0.id < $1.id } } + unowned.sorted { $0.id < $1.id }
    }
    static func layout(window: CGRect, primaryTop: CGFloat, screens: [CGRect], pets: [PetSpec]) -> [PetLayout]? {
        guard !pets.isEmpty, window.width > 0, window.height > 0,
              [window.minX, window.minY, window.width, window.height, primaryTop].allSatisfy({ $0.isFinite }) else { return nil }
        let cocoa = CGRect(x: window.minX, y: primaryTop - window.maxY, width: window.width, height: window.height)
        let candidates = screens.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        guard let screen = candidates.max(by: {
            let a = $0.intersection(cocoa), b = $1.intersection(cocoa)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }), !screen.intersection(cocoa).isNull else { return nil }
        let left = ceil(max(screen.minX, cocoa.minX)), right = floor(min(screen.maxX, cocoa.maxX))
        let width = right - left, top = primaryTop - window.minY
        // AppKit panel positions use whole points; fewer than one per pet cannot display all.
        guard width.isFinite, width >= CGFloat(pets.count), top >= screen.minY else { return nil }
        let orderedPets = ordered(pets)
        let naturalWidth = orderedPets.reduce(CGFloat(0)) { $0 + $1.naturalSize.width }
        var scale: CGFloat = 1
        if naturalWidth > width { scale = CGFloat(pow(2, floor(log2(Double(width / naturalWidth))))) }
        func footprint(_ scale: CGFloat) -> CGFloat { orderedPets.reduce(0) { $0 + ceil($1.naturalSize.width * scale) } }
        // At most32 halvings, independent of numeric IDs/style values; packet size bounds pet count.
        for _ in 0..<32 {
            if footprint(scale) <= width { break }
            scale /= 2
        }
        let used = footprint(scale)
        guard scale > 0, used <= width, top + ceil(panelSize.height * scale) <= screen.maxY else { return nil }
        var groups: [[PetSpec]] = []
        for pet in orderedPets {
            if pet.isMini, let parent = pet.parent, let last = groups.last, last.first?.id == parent {
                groups[groups.count - 1].append(pet)
            } else { groups.append([pet]) }
        }
        let slack = width - used, share = floor(slack / CGFloat(groups.count))
        let extras = Int(slack - share * CGFloat(groups.count))
        var x = left, layouts: [PetLayout] = []
        for (index, group) in groups.enumerated() {
            let extra = share + (index < extras ? 1 : 0)
            let first = group[0], mainWidth = ceil(first.naturalSize.width * scale)
            let hasMinis = !first.isMini && group.count > 1
            let minX = hasMinis || first.isMini ? x + floor(extra / 2) : x
            let maxX = hasMinis || first.isMini ? minX : x + extra
            let initialX = (minX + maxX) / 2
            layouts.append(PetLayout(id: first.id, frame: CGRect(x: initialX, y: top, width: mainWidth, height: ceil(first.naturalSize.height * scale)), minX: minX, maxX: maxX, scale: scale, hasMinis: hasMinis))
            var childX = initialX + mainWidth
            for child in group.dropFirst() {
                let childWidth = ceil(child.naturalSize.width * scale)
                layouts.append(PetLayout(id: child.id, frame: CGRect(x: childX, y: top, width: childWidth, height: ceil(child.naturalSize.height * scale)), minX: childX, maxX: childX, scale: scale, hasMinis: false))
                childX += childWidth
            }
            x += group.reduce(CGFloat(0)) { $0 + ceil($1.naturalSize.width * scale) } + extra
        }
        return layouts
    }
}

enum WindowMembership {
    // AX and CGWindow bounds both use top-left primary-display coordinates.
    static func matches(_ candidate: CGRect, _ target: CGRect, tolerance: CGFloat = 2) -> Bool {
        let values = [candidate.origin.x, candidate.origin.y, candidate.width, candidate.height,
                      target.origin.x, target.origin.y, target.width, target.height]
        guard values.allSatisfy({ $0.isFinite }), candidate.width > 0, candidate.height > 0,
              target.width > 0, target.height > 0 else { return false }
        return abs(candidate.origin.x - target.origin.x) <= tolerance &&
               abs(candidate.origin.y - target.origin.y) <= tolerance &&
               abs(candidate.width - target.width) <= tolerance &&
               abs(candidate.height - target.height) <= tolerance
    }
    struct Match { let onScreen: Bool; let windowNumber: Int? }
    static func onScreenWindow(pid: pid_t, frame: CGRect) -> Match? {
        // Metadata only: no image capture, titles, names, or Screen Recording requests.
        // Called only in event-driven updateTracking, never from an animation timer.
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var missingBounds = false
        for entry in entries {
            guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value == pid,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0 else { continue }
            guard let dictionary = entry[kCGWindowBounds as String] as? [String: Any],
                  let candidate = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else {
                missingBounds = true; continue
            }
            if matches(candidate, frame) {
                let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue
                return Match(onScreen: true, windowNumber: number.flatMap { $0 > 0 ? $0 : nil })
            }
        }
        return missingBounds ? nil : Match(onScreen: false, windowNumber: nil)
    }
}

struct SpriteAtlas {
    static let cellWidth = 96
    static let cellHeight = 80
    static let columns = 4
    static let rows = 3
    let frames: [CGImage]

    static func cellRect(_ index: Int) -> CGRect? {
        guard (0..<(columns * rows)).contains(index) else { return nil }
        // CGImage cropping uses source pixels; atlas rows are authored top-down.
        return CGRect(x: (index % columns) * cellWidth, y: (index / columns) * cellHeight,
                      width: cellWidth, height: cellHeight)
    }
    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == Self.columns * Self.cellWidth,
              image.height == Self.rows * Self.cellHeight,
              image.bitsPerComponent == 8,
              image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast else { return nil }
        var cells: [CGImage] = []
        for index in 0..<(Self.columns * Self.rows) {
            guard let rect = Self.cellRect(index), let frame = image.cropping(to: rect),
                  frame.width == Self.cellWidth, frame.height == Self.cellHeight else { return nil }
            cells.append(frame)
        }
        frames = cells
    }
    static func frameIndex(pose: Pose, elapsed: TimeInterval, reduceMotion: Bool) -> Int {
        let seconds = max(0, elapsed)
        switch pose {
        case .walk: return reduceMotion ? 0 : Int(floor(seconds * 6).truncatingRemainder(dividingBy: 4))
        case .rest: return 4
        case .sleep: return 5
        case .thinking: return reduceMotion ? 6 : 6 + Int(floor(seconds * 2).truncatingRemainder(dividingBy: 2))
        case .awaiting: return !reduceMotion && seconds.truncatingRemainder(dividingBy: 4.5) >= 4.36 ? 9 : 8
        case .lying: return 10
        case .stretch: return 11
        }
    }
    static func awaitingBoundary(elapsed: TimeInterval) -> TimeInterval {
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: 4.5)
        return phase < 4.36 ? 4.36 - phase : 4.5 - phase
    }
    static func groundOffset(pose: Pose) -> CGFloat {
        // Seat broad resting silhouettes against the ledge; panel geometry is unchanged.
        pose == .sleep || pose == .lying ? -2 : 0
    }
    static func shouldMirror(pose: Pose, facingRight: Bool) -> Bool {
        !facingRight && pose != .thinking && pose != .awaiting
    }
}

struct SpriteKey: Hashable {
    let style: Int
    let mini: Bool
}
enum PetTint {
    // Preserve luminance and alpha; add gentle midtone chroma so gray coats visibly vary.
    static func rgb(_ r: Double, _ g: Double, _ b: Double, variant: Int) -> (Double, Double, Double) {
        guard variant > 0 else { return (r, g, b) }
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard y > 0.04, y < 0.94 else { return (r, g, b) }
        let angle = Double((variant % 360) * 67 % 360) * .pi / 180
        let u = (b - y) / 1.8556, v = (r - y) / 1.5748
        let ru = u * cos(angle) - v * sin(angle), rv = u * sin(angle) + v * cos(angle)
        var dr = 1.5748 * rv, db = 1.8556 * ru
        var dg = -(0.2126 * dr + 0.0722 * db) / 0.7152
        let amount = 0.14 * sin(.pi * (y - 0.04) / 0.9)
        let tr = cos(angle), tb = cos(angle + 2 * .pi / 3)
        let tg = -(0.2126 * tr + 0.0722 * tb) / 0.7152
        dr += amount * tr; dg += amount * tg; db += amount * tb
        var compression = 1.0
        for delta in [dr, dg, db] {
            if delta > 0 { compression = min(compression, (1 - y) / delta) }
            else if delta < 0 { compression = min(compression, -y / delta) }
        }
        return (y + dr * compression, y + dg * compression, y + db * compression)
    }
    static func image(_ image: CGImage, variant: Int) -> CGImage? {
        if variant == 0 { return image }
        let width = image.width, height = image.height, rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = pixels.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0 else { continue }
            let (r, g, b) = rgb(Double(pixels[offset]) / 255 / alpha, Double(pixels[offset + 1]) / 255 / alpha, Double(pixels[offset + 2]) / 255 / alpha, variant: variant)
            for (channel, value) in [r, g, b].enumerated() { pixels[offset + channel] = UInt8(min(255, max(0, (value * alpha * 255).rounded()))) }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: bitmap), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
final class SpriteCache {
    private var bases: [String: [CGImage]] = [:]
    private var attempted = Set<String>()
    private var variants: [SpriteKey: [CGImage]] = [:]
    private var recent: [SpriteKey] = []
    let variantLimit = 64
    static func loadMini(_ url: URL) -> [CGImage]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == 96, image.height == 40, image.bitsPerComponent == 8,
              image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast,
              let first = image.cropping(to: CGRect(x: 0, y: 0, width: 48, height: 40)),
              let second = image.cropping(to: CGRect(x: 48, y: 0, width: 48, height: 40)) else { return nil }
        return [first, second]
    }
    func frames(_ key: SpriteKey) -> [CGImage]? {
        if let cached = variants[key] { touch(key); return cached }
        let breed = catBreeds[key.style % colonySize], name = "\(breed)-\(key.mini ? "mini" : "colony")"
        if !attempted.contains(name) {
            attempted.insert(name)
            if let url = Bundle.main.url(forResource: name, withExtension: "png") {
                bases[name] = key.mini ? Self.loadMini(url) : SpriteAtlas(url: url)?.frames
            }
            if let frames = bases[name] { emit(["type": "sprite-loaded", "breed": breed, "mini": key.mini, "frames": frames.count]) }
            else { emit(["type": "warning", "reason": "sprite-atlas-unavailable", "breed": breed, "mini": key.mini, "fallback": "vector"]) }
        }
        guard let base = bases[name] else { return nil }
        if key.style / colonySize == 0 { return base }
        var tinted: [CGImage] = []
        for frame in base { guard let image = PetTint.image(frame, variant: key.style / colonySize) else { return nil }; tinted.append(image) }
        variants[key] = tinted; touch(key)
        while recent.count > variantLimit { variants.removeValue(forKey: recent.removeFirst()) }
        return tinted
    }
    private func touch(_ key: SpriteKey) { recent.removeAll { $0 == key }; recent.append(key) }
    func prune(active: Set<SpriteKey>) {
        variants = variants.filter { active.contains($0.key) }
        recent.removeAll { !active.contains($0) }
    }
    var variantCount: Int { variants.count }
}

final class CatView: NSView {
    var pose: Pose = .rest
    var spriteIndex = 4
    var slot = 0
    var role: PetRole = .session
    var visualScale: CGFloat = 1
    var sprites: [CGImage]?
    func drawMiniBubble(_ c: CGContext) {
        // Pixel-grid UI glyphs, never a blurry font or mirrored punctuation.
        c.setFillColor(NSColor(calibratedWhite: 0.22, alpha: 1).cgColor)
        c.fill(CGRect(x: 24, y: 38, width: 18, height: 14)); c.fill(CGRect(x: 22, y: 40, width: 22, height: 10))
        c.setFillColor(NSColor.white.cgColor)
        c.fill(CGRect(x: 25, y: 39, width: 16, height: 12)); c.fill(CGRect(x: 23, y: 41, width: 20, height: 8))
        c.fill(CGRect(x: 30, y: 34, width: 3, height: 3)); c.fill(CGRect(x: 28, y: 30, width: 2, height: 2))
        c.setFillColor(NSColor(calibratedWhite: 0.18, alpha: 1).cgColor)
        if role == .job {
            let glyph = ["10101", "01110", "11111", "01110", "10101"]
            for (row, line) in glyph.enumerated() {
                for (col, pixel) in line.enumerated() where pixel == "1" { c.fill(CGRect(x: 31 + col, y: 47 - row, width: 1, height: 1)) }
            }
        } else {
            for x in [27, 32, 37] { c.fill(CGRect(x: x, y: 44, width: 2, height: 2)) }
        }
    }
    var phase: Double = 0
    var reduceMotion = false
    var facingRight = true
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.clear(bounds) // Explicitly erase the transparent backing before each puppet pose.
        c.saveGState(); defer { c.restoreGState() }
        c.scaleBy(x: visualScale, y: visualScale)
        if role != .session {
            c.interpolationQuality = .none; c.setShouldAntialias(false)
            if let sprites { c.draw(sprites[spriteIndex % 2], in: CGRect(x: 5, y: 0, width: 48, height: 40)) }
            else {
                c.setFillColor(NSColor(calibratedWhite: 0.5, alpha: 1).cgColor); c.fill(CGRect(x: 10, y: 0, width: 35, height: 25))
                c.fill(CGRect(x: 24, y: 18, width: 20, height: 20))
                c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x: 27, y: 4, width: 24, height: 12))
            }
            drawMiniBubble(c)
            return
        }
        if let sprites {
            let rect = backingAlignedRect(CGRect(x: 7, y: SpriteAtlas.groundOffset(pose: pose), width: 96, height: 80), options: [.alignAllEdgesNearest])
            c.saveGState()
            c.interpolationQuality = .none
            c.setShouldAntialias(false)
            if SpriteAtlas.shouldMirror(pose: pose, facingRight: facingRight) { c.translateBy(x: panelSize.width, y: 0); c.scaleBy(x: -1, y: 1) }
            c.draw(sprites[spriteIndex], in: rect)
            c.restoreGState()
            return
        }
        c.setAllowsAntialiasing(true)
        let coats = [NSColor(calibratedRed: 0.70, green: 0.48, blue: 0.29, alpha: 1), NSColor(calibratedWhite: 0.20, alpha: 1), NSColor(calibratedRed: 0.83, green: 0.76, blue: 0.61, alpha: 1)]
        let ginger = coats[slot].cgColor
        let light = NSColor(calibratedRed: 1, green: 0.88, blue: 0.73, alpha: 1).cgColor
        let dark = NSColor(calibratedRed: 0.36, green: 0.18, blue: 0.13, alpha: 1).cgColor
        let cream = NSColor(calibratedRed: 1, green: 0.88, blue: 0.66, alpha: 1).cgColor
        let pink = NSColor(calibratedRed: 0.89, green: 0.47, blue: 0.43, alpha: 1).cgColor
        func ellipse(_ rect: CGRect, _ color: CGColor) { c.setFillColor(color); c.fillEllipse(in: rect) }
        func line(_ points: [CGPoint], _ color: CGColor, _ width: CGFloat) {
            guard let first = points.first else { return }
            c.beginPath(); c.move(to: first)
            for p in points.dropFirst() { c.addLine(to: p) }
            c.setStrokeColor(color); c.setLineWidth(width); c.setLineCap(.round); c.setLineJoin(.round); c.strokePath()
        }
        func triangle(_ points: [CGPoint], _ color: CGColor) {
            c.beginPath(); c.move(to: points[0]); c.addLines(between: Array(points.dropFirst())); c.closePath(); c.setFillColor(color); c.fillPath()
        }
        let sleeping = pose == .sleep || pose == .lying
        let stretching = pose == .stretch
        let walking = pose == .walk && !reduceMotion
        let bob: CGFloat = walking ? CGFloat(sin(phase * 2)) * 1.4 : 0
        c.saveGState()
        if SpriteAtlas.shouldMirror(pose: pose, facingRight: facingRight) { c.translateBy(x: panelSize.width, y: 0); c.scaleBy(x: -1, y: 1) }
        // Tail is a thick, gently curled original vector stroke, not an image asset.
        c.beginPath(); c.move(to: CGPoint(x: 36, y: sleeping ? 11 : 19 + bob))
        c.addCurve(to: CGPoint(x: 18, y: sleeping ? 22 : 41 + bob), control1: CGPoint(x: 10, y: 5), control2: CGPoint(x: 5, y: 45))
        c.setStrokeColor(ginger); c.setLineWidth(9); c.setLineCap(.round); c.strokePath()
        line([CGPoint(x: 16, y: sleeping ? 21 : 38 + bob), CGPoint(x: 18, y: sleeping ? 22 : 41 + bob)], dark, 3)
        let body = CGRect(x: 26, y: sleeping ? 2 : 6 + bob, width: sleeping || stretching ? 58 : 49, height: sleeping ? 24 : (stretching ? 26 : 35))
        ellipse(body, ginger)
        ellipse(CGRect(x: 43, y: sleeping ? 3 : 8 + bob, width: 26, height: sleeping ? 13 : 22), light)
        for i in 0..<3 {
            let x = CGFloat(34 + i * 8)
            line([CGPoint(x: x, y: body.maxY - 3), CGPoint(x: x + 2, y: body.maxY - 10)], dark, 2.5)
        }
        let headX: CGFloat = sleeping ? 66 : (stretching ? 74 : 68)
        let headY: CGFloat = sleeping ? 18 : (stretching ? 27 : 38 + bob)
        triangle([CGPoint(x: headX - 15, y: headY + 6), CGPoint(x: headX - 16, y: headY + 25), CGPoint(x: headX - 2, y: headY + 15)], ginger)
        triangle([CGPoint(x: headX + 2, y: headY + 15), CGPoint(x: headX + 15, y: headY + 25), CGPoint(x: headX + 16, y: headY + 5)], ginger)
        triangle([CGPoint(x: headX - 12, y: headY + 12), CGPoint(x: headX - 13, y: headY + 20), CGPoint(x: headX - 5, y: headY + 14)], pink)
        triangle([CGPoint(x: headX + 5, y: headY + 14), CGPoint(x: headX + 12, y: headY + 20), CGPoint(x: headX + 12, y: headY + 10)], pink)
        ellipse(CGRect(x: headX - 18, y: headY - 9, width: 36, height: 31), ginger)
        ellipse(CGRect(x: headX - 11, y: headY - 7, width: 23, height: 14), cream)
        line([CGPoint(x: headX - 6, y: headY + 19), CGPoint(x: headX - 3, y: headY + 13)], dark, 2)
        line([CGPoint(x: headX + 4, y: headY + 20), CGPoint(x: headX + 3, y: headY + 13)], dark, 2)
        for side: CGFloat in [-1, 1] {
            let ex = headX + side * 8
            if sleeping || stretching {
                line([CGPoint(x: ex - 3, y: headY + 6), CGPoint(x: ex, y: headY + 4), CGPoint(x: ex + 3, y: headY + 6)], dark, 1.8)
            } else {
                ellipse(CGRect(x: ex - 2, y: headY + 3, width: 4, height: pose == .awaiting ? 7 : 5), dark)
                if pose == .thinking {
                    line([CGPoint(x: ex - 3, y: headY + 11 - side * 1.5), CGPoint(x: ex + 3, y: headY + 11 + side * 1.5)], dark, 1.5)
                }
            }
            line([CGPoint(x: headX + side * 10, y: headY), CGPoint(x: headX + side * 22, y: headY + 2)], dark, 0.8)
            line([CGPoint(x: headX + side * 10, y: headY - 3), CGPoint(x: headX + side * 21, y: headY - 5)], dark, 0.8)
        }
        triangle([CGPoint(x: headX - 3, y: headY + 1), CGPoint(x: headX + 3, y: headY + 1), CGPoint(x: headX, y: headY - 2)], pink)
        line([CGPoint(x: headX, y: headY - 2), CGPoint(x: headX, y: headY - 5)], dark, 1)
        // The front paws have bottom y=0, coinciding with the actual DSH window edge.
        for (i, x): (Int, CGFloat) in [CGFloat(42), CGFloat(stretching ? 83 : 70)].enumerated() {
            let lift = walking ? max(0, CGFloat(sin(phase + Double(i) * .pi))) * 5 : 0
            ellipse(CGRect(x: x - 6, y: lift, width: 15, height: sleeping ? 8 : 12), light)
            line([CGPoint(x: x, y: lift + 1), CGPoint(x: x, y: lift + 4)], dark, 0.8)
        }
        if pose == .thinking || pose == .awaiting {
            ellipse(CGRect(x: 76, y: 64, width: 30, height: 20), NSColor.white.cgColor)
            ellipse(CGRect(x: 78, y: 60, width: 5, height: 5), NSColor.white.cgColor)
            if pose == .awaiting {
                NSAttributedString(string: "?", attributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.darkGray]).draw(at: CGPoint(x: 87, y: 63))
            } else {
                for x in [84, 91, 98] { ellipse(CGRect(x: x, y: 72, width: 3, height: 3), dark) }
                c.setFillColor(NSColor(calibratedRed: 0.34, green: 0.51, blue: 0.57, alpha: 1).cgColor)
                c.fill(CGRect(x: 53, y: 5, width: 37, height: 20))
                c.setFillColor(cream); c.fill(CGRect(x: 56, y: 8, width: 31, height: 15))
                line([CGPoint(x: 71, y: 8), CGPoint(x: 71, y: 23)], dark, 1)
            }
        }
        c.restoreGState()
    }
}

final class CatPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PetNode {
    var spec: PetSpec
    var state: CatState
    let panel: CatPanel
    let view: CatView
    init(spec: PetSpec, now: TimeInterval) {
        self.spec = spec; state = CatState(now: now); state.accept(spec.assignment, now: now)
        let frame = CGRect(origin: .zero, size: spec.naturalSize)
        panel = CatPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = CatView(frame: frame)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false; panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isReleasedWhenClosed = false; panel.contentView = view
        view.slot = spec.style % colonySize; view.role = spec.role
        view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
enum Reconciliation {
    static func removed(existing: Set<String>, incoming: [PetSpec]) -> Set<String> {
        existing.subtracting(Set(incoming.map(\.id)))
    }
}

func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = axAttribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
func axBool(_ element: AXUIElement, _ name: String) -> Bool {
    (axAttribute(element, name) as? NSNumber)?.boolValue ?? false
}
func windowRect(_ window: AXUIElement) -> CGRect? {
    guard let position = axAttribute(window, kAXPositionAttribute), let size = axAttribute(window, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}

final class Controller: NSObject, NSApplicationDelegate {
    var nodes: [String: PetNode] = [:]
    var petOrder: [String] = []
    let spriteCache = SpriteCache()
    var statusItem: NSStatusItem?
    var target: NSRunningApplication?
    var trackedTargetPID: pid_t?
    var appAX: AXUIElement?
    var windowAX: AXUIElement?
    var observer: AXObserver?
    var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    var permissionTimer: Timer?
    var animationTimer: Timer?
    var inputSource: DispatchSourceRead?
    var signalSources: [DispatchSourceSignal] = []
    var inputBuffer = Data()
    let maxLineBytes = maximumPacketBytes
    var trusted = false
    var locked = false
    var visible = false
    var lastTracking = ""
    var activity: MenagerieStatus?
    var lastPoseSignature = ""
    var lastProtocolVersion: Int?
    var legacyWarned = false
    var lastTick = ProcessInfo.processInfo.systemUptime
    var targetWindowNumber: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let own = NSRunningApplication.current
        let duplicate = NSRunningApplication.runningApplications(withBundleIdentifier: "local.dsh.window-cat").contains {
            $0.processIdentifier != own.processIdentifier && !$0.isTerminated &&
            $0.executableURL?.standardizedFileURL == own.executableURL?.standardizedFileURL &&
            (($0.launchDate ?? .distantPast) < (own.launchDate ?? .distantFuture) ||
             ($0.launchDate == own.launchDate && $0.processIdentifier < own.processIdentifier))
        }
        if duplicate { emit(["type": "duplicate", "reason": "helper-already-running"]); Darwin.exit(0) }
        setupInput()
        setupSignals()
        setupNotifications()
        trusted = AXIsProcessTrusted()
        emit(["type": "ready", "pid": ProcessInfo.processInfo.processIdentifier, "accessibility": trusted])
        _ = reconcile(PetSpec.bases, now: ProcessInfo.processInfo.systemUptime)
        showPermissionMenu()
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options) // Exactly one prompt attempt per process.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkPermission() }
        }
        refreshTarget()
        updateAnimation()
    }

    @discardableResult func reconcile(_ specs: [PetSpec], now: TimeInterval) -> Bool {
        let ordered = MenageriePlacement.ordered(specs)
        var changed = petOrder != ordered.map(\.id)
        var shared: [SpriteKey: [CGImage]] = [:]
        for node in nodes.values {
            if let frames = node.view.sprites { shared[SpriteKey(style: node.spec.style, mini: node.spec.isMini)] = frames }
        }
        for id in Reconciliation.removed(existing: Set(nodes.keys), incoming: specs) {
            if let old = nodes.removeValue(forKey: id) { old.panel.orderOut(nil); old.panel.close() }
        }
        for spec in ordered {
            let existing = nodes[spec.id]
            let oldKey = existing.map { SpriteKey(style: $0.spec.style, mini: $0.spec.isMini) }
            let key = SpriteKey(style: spec.style, mini: spec.isMini)
            let node = existing ?? PetNode(spec: spec, now: now)
            if node.spec.parent != spec.parent || oldKey != key { changed = true }
            if existing == nil || oldKey != key {
                let frames = shared[key] ?? spriteCache.frames(key)
                node.view.sprites = frames
                if let frames { shared[key] = frames }
                node.view.slot = spec.style % colonySize; node.view.role = spec.role
                node.view.needsDisplay = true
            }
            node.state.accept(spec.assignment, now: now)
            node.spec = spec; nodes[spec.id] = node
        }
        petOrder = ordered.map(\.id)
        spriteCache.prune(active: Set(specs.map { SpriteKey(style: $0.style, mini: $0.isMini) }))
        return changed
    }

    func listen(_ center: NotificationCenter, _ name: Notification.Name, _ block: @escaping (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main, using: block)
        tokens.append((center, token))
    }
    func setupNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter
        listen(workspace, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            guard let self, let ended = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  ended.processIdentifier == self.trackedTargetPID else { return }
            emit(["type": "stopping", "reason": "target-terminated"]); self.shutdown(); Darwin.exit(0)
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            listen(workspace, name) { [weak self] _ in self?.refreshTarget() }
        }
        listen(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in self?.locked = true; self?.updateTracking() }
        listen(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in self?.locked = false; self?.refreshTarget() }
        listen(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.locked = true; self?.updateTracking() }
        listen(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] _ in self?.locked = false; self?.refreshTarget() }
        listen(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] _ in
            guard let self else { return }
            for node in self.nodes.values { node.view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
            self.updateAnimation()
        }
        listen(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.updateTracking() }
        let distributed = DistributedNotificationCenter.default()
        listen(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in self?.locked = true; self?.updateTracking() }
        listen(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in self?.locked = false; self?.refreshTarget() }
    }

    func setupInput() {
        _ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in self?.readInput() }
        inputSource = source; source.resume()
    }
    func readInput() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        if count == 0 { shutdown(); Darwin.exit(0) }
        if count < 0 {
            if errno != EAGAIN && errno != EINTR { emit(["type": "error", "reason": "stdin-read"]); shutdown(); Darwin.exit(1) }
            return
        }
        inputBuffer.append(contentsOf: bytes.prefix(count))
        while let newline = inputBuffer.firstIndex(of: 10) {
            let line = inputBuffer.prefix(upTo: newline)
            guard line.count <= maxLineBytes else { inputTooLong() }
            if !line.isEmpty {
                guard let next = MenagerieStatus.decode(Data(line)) else {
                    emit(["type": "error", "reason": "invalid-status"]); shutdown(); Darwin.exit(2)
                }
                accept(next)
            }
            inputBuffer.removeSubrange(...newline)
        }
        if inputBuffer.count > maxLineBytes { inputTooLong() }
    }
    func inputTooLong() -> Never { emit(["type": "error", "reason": "input-too-long"]); shutdown(); Darwin.exit(2) }
    func setupSignals() {
        signal(SIGPIPE, SIG_IGN)
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.shutdown(); Darwin.exit(0) }
            source.resume(); signalSources.append(source)
        }
    }

    @objc func checkPermission() {
        let now = AXIsProcessTrusted()
        if now != trusted { trusted = now; emit(["type": "accessibility", "trusted": now]) }
        if trusted {
            permissionTimer?.invalidate(); permissionTimer = nil
            statusItem?.button?.toolTip = "DSH Window Cat"
            statusItem?.menu?.items.first?.title = "DSH Window Cat — Accessibility allowed"
            refreshTarget()
        } else { updateTracking() }
    }
    func showPermissionMenu() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐈"; item.button?.toolTip = trusted ? "DSH Window Cat" : "DSH Window Cat — Accessibility permission needed"
        let menu = NSMenu()
        let title = NSMenuItem(title: trusted ? "DSH Window Cat — Accessibility allowed" : "Allow DSH Window Cat in Accessibility", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title); menu.addItem(.separator())
        for (label, action) in [("Open Accessibility Settings…", #selector(openSettings)), ("Retry Permission", #selector(checkPermission)), ("Quit", #selector(quit))] {
            let entry = NSMenuItem(title: label, action: action, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        item.menu = menu; statusItem = item
    }
    @objc func openSettings() { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) } }
    @objc func quit() { shutdown(); NSApp.terminate(nil) }

    func detachObserver() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; appAX = nil; windowAX = nil
    }
    func refreshTarget() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID)
        let next = apps.first(where: { $0.isActive }) ?? apps.first
        if let next { trackedTargetPID = next.processIdentifier }
        if next?.processIdentifier != target?.processIdentifier || (trusted && observer == nil) {
            detachObserver(); target = next
            if trusted, let next { attach(next.processIdentifier) }
        } else { target = next }
        updateTracking()
    }
    func attach(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        appAX = app
        var created: AXObserver?
        let result = AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            let owner = Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue()
            owner.updateTracking()
        }, &created)
        guard result == .success, let created else { emit(["type": "warning", "reason": "ax-observer-unavailable", "code": result.rawValue]); return }
        observer = created
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            let result = AXObserverAddNotification(created, app, name as CFString, context)
            if result != .success && result != .notificationAlreadyRegistered { emit(["type": "warning", "reason": "ax-notification-unavailable", "notification": name, "code": result.rawValue]) }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }
    let windowNotifications = [kAXMovedNotification, kAXResizedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification]
    func observeWindow(_ next: AXUIElement?) {
        if let old = windowAX, let next, CFEqual(old, next) { return }
        if let old = windowAX, let observer { for name in windowNotifications { AXObserverRemoveNotification(observer, old, name as CFString) } }
        windowAX = next
        if let next, let observer {
            AXUIElementSetMessagingTimeout(next, 0.25)
            for name in windowNotifications {
                let result = AXObserverAddNotification(observer, next, name as CFString, Unmanaged.passUnretained(self).toOpaque())
                if result != .success && result != .notificationAlreadyRegistered { emit(["type": "warning", "reason": "ax-notification-unavailable", "notification": name, "code": result.rawValue]) }
            }
        }
    }
    func updateTracking() {
        targetWindowNumber = nil
        guard trusted else { setTracking(nil, "accessibility-required"); return }
        guard !locked else { setTracking(nil, "session-inactive"); return }
        guard let target, !target.isTerminated else { setTracking(nil, "target-not-running"); return }
        guard !target.isHidden else { setTracking(nil, "target-hidden"); return }
        guard let appAX else { setTracking(nil, "ax-unavailable"); return }
        let next = axElement(appAX, kAXFocusedWindowAttribute) ?? axElement(appAX, kAXMainWindowAttribute)
        observeWindow(next)
        guard let next else { setTracking(nil, "no-window"); return }
        guard !axBool(next, kAXMinimizedAttribute) else { setTracking(nil, "minimized"); return }
        guard !axBool(next, "AXFullScreen") else { setTracking(nil, "fullscreen"); return }
        guard let rect = windowRect(next) else { setTracking(nil, "geometry-unavailable"); return }
        guard let match = WindowMembership.onScreenWindow(pid: target.processIdentifier, frame: rect) else {
            setTracking(nil, "screen-membership-unavailable"); return
        }
        guard match.onScreen else { setTracking(nil, "target-not-on-current-space"); return }
        targetWindowNumber = match.windowNumber
        let specs = petOrder.compactMap { nodes[$0]?.spec }
        guard let primary = NSScreen.screens.first,
              let layouts = MenageriePlacement.layout(window: rect, primaryTop: primary.frame.maxY, screens: NSScreen.screens.map(\.visibleFrame), pets: specs) else {
            setTracking(nil, "no-room-for-menagerie"); return
        }
        var frames: [String: CGRect] = [:]
        for layout in layouts {
            guard let node = nodes[layout.id] else { continue }
            var frame = layout.frame
            // Preserve full-precision progress, never feed rounded NSWindow x back.
            frame.origin.x = node.state.relocate(low: layout.minX, high: layout.maxX, initial: frame.origin.x, fallbackX: node.panel.frame.minX)
            node.state.movementScale = layout.scale
            node.state.holdsGroup = layout.hasMinis
            if node.view.visualScale != layout.scale { node.view.visualScale = layout.scale; node.view.needsDisplay = true }
            frames[layout.id] = frame
        }
        setTracking(frames, "tracking")
    }
    func setTracking(_ frames: [String: CGRect]?, _ reason: String) {
        let show = !petOrder.isEmpty && frames?.count == petOrder.count
        var ordering = "hidden"
        var verifiedTargetNumber = false
        if show, let frames {
            let availableNumbers = NSWindow.windowNumbers(options: [.allApplications])
            verifiedTargetNumber = targetWindowNumber.map { number in availableNumbers?.contains(where: { $0.intValue == number }) == true } ?? false
            for id in petOrder.reversed() {
                guard let node = nodes[id], let frame = frames[id] else { continue }
                let panel = node.panel
                if panel.frame != frame { panel.setFrame(frame, display: false) }
                if verifiedTargetNumber, let targetWindowNumber {
                    panel.order(.above, relativeTo: targetWindowNumber)
                    ordering = "above-target"
                } else if target?.isActive == true {
                    panel.orderFrontRegardless(); ordering = "active-target-front-fallback"
                } else {
                    panel.orderBack(nil); ordering = "inactive-target-back-fallback"
                }
            }
        } else { for node in nodes.values { node.panel.orderOut(nil) } }
        // A resize may create/remove walking room even while visibility is unchanged.
        visible = show
        updateAnimation()
        let numbers = show ? NSWindow.windowNumbers(options: [.allApplications]) : nil
        var panelEvents: [[String: Any]] = []
        for id in petOrder {
            guard let node = nodes[id] else { continue }
            let panel = node.panel
            var detail: [String: Any] = ["id": id, "role": node.spec.role.rawValue, "style": node.spec.style,
                "breed": catBreeds[node.spec.style % colonySize], "scale": node.view.visualScale,
                "panelWindowNumber": panel.windowNumber, "windowLevel": panel.level.rawValue]
            if let index = numbers?.firstIndex(where: { $0.intValue == panel.windowNumber }) { detail["panelZIndex"] = index }
            if show { detail["frame"] = ["x": panel.frame.minX, "y": panel.frame.minY, "width": panel.frame.width, "height": panel.frame.height] }
            panelEvents.append(detail)
        }
        var event: [String: Any] = ["type": "tracking", "visible": show, "reason": reason, "panels": panelEvents,
                                  "ordering": ordering, "targetWindowNumberVerified": verifiedTargetNumber]
        if let target { event["targetPid"] = target.processIdentifier; event["targetActive"] = target.isActive }
        if let targetWindowNumber {
            event["targetWindowNumber"] = targetWindowNumber
            if let index = numbers?.firstIndex(where: { $0.intValue == targetWindowNumber }) { event["targetZIndex"] = index }
        }
        // Event-only metadata; animation frames never query AX/CG/stacking or emit tracking.
        if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), let key = String(data: data, encoding: .utf8), key != lastTracking {
            lastTracking = key; emit(event)
        }
    }

    func accept(_ next: MenagerieStatus) {
        if next.protocolVersion == 2 && !legacyWarned {
            legacyWarned = true
            emit(["type": "warning", "reason": "legacy-v2-migration", "protocolVersion": 2])
        }
        if lastProtocolVersion != next.protocolVersion {
            lastProtocolVersion = next.protocolVersion
            emit(["type": "protocol", "protocolVersion": next.protocolVersion])
        }
        guard activity != next else { return }
        activity = next
        let changedLayout = reconcile(next.pets, now: ProcessInfo.processInfo.systemUptime)
        emit(["type": "group-state", "protocolVersion": next.protocolVersion, "activeChats": next.activeChats,
              "waitingChats": next.waitingChats, "activeSubagents": next.activeSubagents, "activeJobs": next.activeJobs,
              "pets": next.pets.map { ["id": $0.id, "role": $0.role.rawValue, "parent": $0.parent.map { $0 as Any } ?? NSNull(), "style": $0.style, "mode": $0.assignment.mode.rawValue, "epoch": $0.assignment.epoch] as [String: Any] }])
        if changedLayout { updateTracking() } else { updateAnimation() }
    }
    func renderColony(now: TimeInterval, moveDelta: TimeInterval) {
        var poses: [[String: String]] = [], signatureParts: [String] = []
        for id in petOrder {
            guard let node = nodes[id] else { continue }
            let cat = node.view, panel = node.panel, style = node.spec.style
            let pose = node.spec.isMini ? Pose.thinking : node.state.pose(slot: style, now: now, reduceMotion: cat.reduceMotion)
            let previousPose = cat.pose
            var redraw = previousPose != pose
            if pose == .walk && previousPose != .walk { node.state.walkDistance = 0 }
            if visible && !cat.reduceMotion && pose == .walk && previousPose == .walk && moveDelta > 0 {
                let oldX = panel.frame.minX
                if let x = node.state.advanceWalk(slot: style, delta: moveDelta, fallbackX: oldX) {
                    if cat.facingRight != (node.state.direction > 0) { redraw = true }
                    cat.facingRight = node.state.direction > 0
                    panel.setFrameOrigin(CGPoint(x: x, y: panel.frame.minY))
                    // Preserve the regression fix: gait advances only by actual displayed travel.
                    let moved = abs(panel.frame.minX - oldX)
                    node.state.walkDistance += moved
                    cat.phase = Double(node.state.walkDistance / node.state.speed(slot: style)) * 8
                    if cat.sprites == nil && moved > 0 { redraw = true }
                }
            }
            let elapsed = pose == .walk ? Double(node.state.walkDistance / node.state.speed(slot: style)) : now - node.state.modeStarted
            let index = node.spec.isMini ? (cat.reduceMotion ? 0 : Int(floor(max(0, elapsed) * 2).truncatingRemainder(dividingBy: 2))) : SpriteAtlas.frameIndex(pose: pose, elapsed: elapsed, reduceMotion: cat.reduceMotion)
            redraw = redraw || cat.spriteIndex != index
            cat.pose = pose; cat.spriteIndex = index
            if redraw { cat.needsDisplay = true }
            poses.append(["id": id, "pose": pose.rawValue]); signatureParts.append("\(id):\(pose.rawValue)")
        }
        let signature = signatureParts.joined(separator: ",")
        if signature != lastPoseSignature { lastPoseSignature = signature; emit(["type": "poses", "pets": poses]) }
    }
    func updateAnimation() {
        animationTimer?.invalidate(); animationTimer = nil
        let now = ProcessInfo.processInfo.systemUptime
        lastTick = now
        renderColony(now: now, moveDelta: 0)
        scheduleAnimation(now: now)
    }
    func scheduleAnimation(now: TimeInterval) {
        // Exactly one shared visual/phase timer. No AX, CG, or ordering queries here.
        guard visible, let firstID = petOrder.first, nodes[firstID]?.view.reduceMotion == false else { return }
        let poses = petOrder.compactMap { nodes[$0]?.view.pose }
        var delay = ColonyAnimation.frameInterval(poses: poses)
        for id in petOrder {
            guard let node = nodes[id], !node.spec.isMini else { continue }
            if node.state.assignment.mode == .idle && !node.state.holdsGroup {
                delay = min(delay, IdleBehavior.sample(slot: node.spec.style, elapsed: now - node.state.idleStarted).untilChange)
            } else if node.state.assignment.mode == .awaiting {
                delay = min(delay, SpriteAtlas.awaitingBoundary(elapsed: now - node.state.modeStarted))
            }
        }
        guard delay.isFinite else { return }
        // Sleeping/static cats wake only once at their next phase boundary, not at frame rate.
        animationTimer = Timer.scheduledTimer(withTimeInterval: max(1.0 / 24.0, delay), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.animationTimer = nil
            let now = ProcessInfo.processInfo.systemUptime
            let delta = min(max(0, now - self.lastTick), 0.1)
            self.lastTick = now
            self.renderColony(now: now, moveDelta: delta)
            self.scheduleAnimation(now: now)
        }
        animationTimer?.tolerance = min(0.01, delay * 0.05)
    }
    func shutdown() {
        inputSource?.cancel(); inputSource = nil
        permissionTimer?.invalidate(); animationTimer?.invalidate()
        detachObserver()
        for (center, token) in tokens { center.removeObserver(token) }; tokens.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil
        for node in nodes.values { node.panel.orderOut(nil); node.panel.close() }
        nodes.removeAll(); petOrder.removeAll(); spriteCache.prune(active: [])
    }
    func applicationWillTerminate(_ notification: Notification) { shutdown() }
}

func selfTest() -> Never {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { emit(["type": "self-test", "ok": false, "failed": label]); Darwin.exit(1) }
        checks += 1
    }
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let patrol = Placement.layout(window: CGRect(x: 100, y: 150, width: 990, height: 600), primaryTop: 900, screens: [screen])
    check(patrol?.count == 3, "exactly three panels")
    check(patrol?.map(\.minX) == [100, 430, 760] && patrol?.map(\.maxX) == [320, 650, 980], "disjoint thirds")
    check(patrol?.map(\.frame.minY) == [750, 750, 750], "all paws on actual top border")
    check(patrol?.allSatisfy { $0.frame.width == 110 && $0.frame.height == 88 } == true, "colony panel dimensions")
    let narrow = Placement.layout(window: CGRect(x: 100, y: 150, width: 330, height: 500), primaryTop: 900, screens: [screen])
    check(narrow?.map(\.minX) == narrow?.map(\.maxX) && narrow?.count == 3, "exact330 width fits without overlap")
    check(Placement.layout(window: CGRect(x: 100, y: 150, width: 329, height: 500), primaryTop: 900, screens: [screen]) == nil, "below330 hides colony")
    let clipped = Placement.layout(window: CGRect(x: -100, y: 150, width: 1000, height: 600), primaryTop: 900, screens: [screen])
    check(clipped?.first?.minX == 0 && clipped?.last?.maxX == 790, "patrol clips to screen")
    check(Placement.layout(window: CGRect(x: 0, y: 25, width: 1440, height: 875), primaryTop: 900, screens: [screen]) == nil, "maximized hides")
    check(Placement.layout(window: CGRect(x: 0, y: 0, width: 1440, height: 900), primaryTop: 900, screens: [screen]) == nil, "fullscreen hides")
    check(Placement.layout(window: CGRect(x: -2000, y: 150, width: 600, height: 500), primaryTop: 900, screens: [screen]) == nil, "offscreen hides")
    check(Placement.layout(window: CGRect(x: 0, y: 100, width: 900, height: 600), primaryTop: 900, screens: [screen]) == nil, "less88pt above hides")
    let secondary = CGRect(x: -1280, y: -200, width: 1280, height: 1000)
    check(Placement.layout(window: CGRect(x: -1200, y: 200, width: 1000, height: 650), primaryTop: 900, screens: [screen, secondary])?.first?.frame.minY == 700, "negative-origin screen")
    let axFrame = CGRect(x: -300, y: 150, width: 1000, height: 600)
    check(WindowMembership.matches(axFrame, axFrame), "on-screen exact geometry")
    check(WindowMembership.matches(CGRect(x: -299, y: 148, width: 1001, height: 599), axFrame), "on-screen rounding tolerance")
    check(!WindowMembership.matches(CGRect(x: -297, y: 150, width: 1000, height: 600), axFrame), "different position rejected")
    check(!WindowMembership.matches(CGRect(x: -300, y: 150, width: 1010, height: 600), axFrame), "different window size rejected")
    check(!WindowMembership.matches(CGRect(x: -300, y: 150, width: 0, height: 600), axFrame), "empty geometry rejected")
    check(!WindowMembership.matches(CGRect(x: CGFloat.nan, y: 150, width: 1000, height: 600), axFrame), "nonfinite geometry rejected")
    func decodeV2(active: Int, waiting: Int, modes: [String], epochs: [Int] = [7, 8, 9]) -> ColonyStatus? {
        let object: [String: Any] = ["version": 2, "activeChats": active, "waitingChats": waiting, "overflow": max(0, active - 3),
            "cats": modes.enumerated().map { ["mode": $0.element, "epoch": epochs[$0.offset]] as [String: Any] }]
        return ColonyStatus.decode(try! JSONSerialization.data(withJSONObject: object))
    }
    for count in 0...3 {
        let modes = (0..<3).map { $0 < count ? "thinking" : "idle" }
        let status = decodeV2(active: count, waiting: 0, modes: modes)
        check(status?.cats.filter { $0.mode == .thinking }.count == count, "zero-to-three busy slots")
        check(status?.cats.count == 3 && status?.protocolVersion == 2, "three permanent slots andv2")
    }
    let waiting = decodeV2(active: 3, waiting: 2, modes: ["awaiting", "thinking", "awaiting"])
    check(waiting?.cats.map(\.mode) == [.awaiting, .thinking, .awaiting], "awaiting preserves exact host slots")
    check(waiting?.cats.map(\.epoch) == [7, 8, 9], "epochs preserve host ownership")
    let capped = decodeV2(active: 8, waiting: 5, modes: ["awaiting", "awaiting", "thinking"])
    check(capped?.cats.count == 3 && capped?.overflow == 5, "overflow never creates extra cats")
    check(decodeV2(active: 1, waiting: 2, modes: ["awaiting", "idle", "idle"]) == nil, "invalid totals rejected")
    check(decodeV2(active: 1, waiting: 0, modes: ["broken", "idle", "idle"]) == nil, "invalid mode rejected")
    check(decodeV2(active: 0, waiting: 0, modes: ["idle", "idle"]) == nil, "wrong slot count rejected")
    check(decodeV2(active: 0, waiting: 0, modes: ["idle", "idle", "idle"], epochs: [0, -1, 0]) == nil, "negative epoch rejected")
    let legacy = ColonyStatus.decode(Data("{\"running\":9,\"attention\":1,\"settled\":0,\"errors\":0}".utf8))
    check(legacy?.protocolVersion == 1 && legacy?.cats.count == 3 && legacy?.overflow == 6, "legacy fallback explicitly distinguished")
    check(ColonyStatus.integer(true) == nil && ColonyStatus.integer(0.5) == nil, "booleans and fractions rejected")
    check((0..<3).map { IdleBehavior.sample(slot: $0, elapsed: 0).pose } == [.walk, .rest, .sleep], "idle startup independently staggered")
    check(IdleBehavior.sample(slot: 0, elapsed: 20).pose == .sleep, "wanderer eventually sleeps")
    check(IdleBehavior.sample(slot: 2, elapsed: 16).pose == .walk, "sleeper eventually wanders")
    var state = CatState(now: 100)
    state.accept(Assignment(mode: .thinking, epoch: 4), now: 110)
    state.accept(Assignment(mode: .thinking, epoch: 4), now: 120)
    check(state.modeStarted == 110, "stable ownership does not reset animation")
    check(state.pose(slot: 0, now: 120, reduceMotion: false) == .thinking, "busy never wanders")
    state.accept(Assignment(mode: .awaiting, epoch: 4), now: 130)
    check(state.assignment.epoch == 4 && state.pose(slot: 0, now: 135, reduceMotion: false) == .awaiting, "same owner awaiting transition")
    state.accept(Assignment(mode: .thinking, epoch: 5), now: 140)
    check(state.modeStarted == 140 && state.assignment.epoch == 5, "new ownership starts new activity clock")
    state.accept(Assignment(mode: .idle, epoch: 6), now: 150)
    check(state.idleStarted == 150, "release returns to independent idle phase")
    check(state.pose(slot: 0, now: 151, reduceMotion: true) == .rest, "reduced motion has static idle")
    check(ColonyAnimation.frameInterval(poses: [.walk, .sleep, .thinking]) == 1.0 / 24, "walk capped24fps")
    check(ColonyAnimation.frameInterval(poses: [.thinking, .sleep, .rest]) == 0.5, "book-only2fps")
    check(ColonyAnimation.frameInterval(poses: [.awaiting, .sleep, .rest]).isInfinite, "question uses blink boundaries not frame polling")
    check(ColonyAnimation.frameInterval(poses: [.sleep, .sleep, .rest]).isInfinite, "sleep has no frame timer")
    let reflected = Patrol.step(x: 9, low: 0, high: 10, direction: 1, distance: 3)
    check(reflected.x == 8 && reflected.direction == -1, "patrol reflects within assigned third")
    check(Patrol.step(x: 5, low: 0, high: 10, direction: -1, distance: 2).x == 3, "leftward patrol stays leftward")
    check(Patrol.step(x: 0, low: 0, high: 0.1, direction: 1, distance: 20).x <= 0.1, "tiny patrol range cannot escape")
    check(SpriteAtlas.cellRect(0) == CGRect(x: 0, y: 0, width: 96, height: 80), "atlas first cell")
    check(SpriteAtlas.cellRect(4) == CGRect(x: 0, y: 80, width: 96, height: 80), "atlas top-down row")
    check(SpriteAtlas.cellRect(11) == CGRect(x: 288, y: 160, width: 96, height: 80), "atlas last cell")
    check(SpriteAtlas.cellRect(-1) == nil && SpriteAtlas.cellRect(12) == nil, "invalid atlas cell")
    check((0..<4).map { SpriteAtlas.frameIndex(pose: .walk, elapsed: Double($0) / 6, reduceMotion: false) } == [0, 1, 2, 3], "four walk poses")
    check(SpriteAtlas.frameIndex(pose: .thinking, elapsed: 0.5, reduceMotion: false) == 7, "book second frame")
    check(SpriteAtlas.frameIndex(pose: .awaiting, elapsed: 4, reduceMotion: false) == 8, "question eyes usually open")
    check(SpriteAtlas.frameIndex(pose: .awaiting, elapsed: 4.37, reduceMotion: false) == 9, "brief awaiting blink")
    check(SpriteAtlas.frameIndex(pose: .awaiting, elapsed: 4.5, reduceMotion: false) == 8, "awaiting eyes reopen")
    check(abs(SpriteAtlas.awaitingBoundary(elapsed: 4.36) - 0.14) < 0.0001, "blink lasts140milliseconds")
    check(SpriteAtlas.frameIndex(pose: .thinking, elapsed: 0.5, reduceMotion: true) == 6, "book frozen for reduced motion")
    check(!SpriteAtlas.shouldMirror(pose: .thinking, facingRight: false) && !SpriteAtlas.shouldMirror(pose: .awaiting, facingRight: false), "book and question never mirrored")
    check(SpriteAtlas.shouldMirror(pose: .walk, facingRight: false), "walk may face left")
    check(SpriteAtlas.groundOffset(pose: .sleep) == -2 && SpriteAtlas.groundOffset(pose: .lying) == -2, "resting sprites sit two pixels lower")
    check([Pose.walk, .rest, .thinking, .awaiting, .stretch].allSatisfy { SpriteAtlas.groundOffset(pose: $0) == 0 }, "other poses retain original ground alignment")
    // Regression: AppKit floors requested origins. The old feedback loop stalled
    // rightward at every configured speed and accelerated leftward to24pt/sec.
    for slot in 0..<colonySize {
        for start: CGFloat in [300, -300] {
            for direction: CGFloat in [1, -1] {
                var walker = CatState(now: 0)
                walker.minX = start - 100; walker.maxX = start + 100
                walker.logicalX = start; walker.direction = direction
                var displayedX = start
                var heldFrame = true
                var sawRoundedPause = false
                for _ in 0..<24 {
                    let before = SpriteAtlas.frameIndex(pose: .walk, elapsed: Double(walker.walkDistance / IdleBehavior.speeds[slot]), reduceMotion: false)
                    let requested = walker.advanceWalk(slot: slot, delta: 1.0 / 24, fallbackX: displayedX)!
                    let actualX = floor(requested) // real AppKit behavior reproduced by motion-probe.swift
                    let moved = abs(actualX - displayedX)
                    walker.walkDistance += moved
                    let after = SpriteAtlas.frameIndex(pose: .walk, elapsed: Double(walker.walkDistance / IdleBehavior.speeds[slot]), reduceMotion: false)
                    if moved == 0 { sawRoundedPause = true; heldFrame = heldFrame && before == after }
                    displayedX = actualX
                }
                check(abs(displayedX - start - direction * IdleBehavior.speeds[slot]) < 0.001, "rounded display preserves configured speed both directions")
                check(abs(walker.logicalX! - start - direction * IdleBehavior.speeds[slot]) < 0.001, "fractional position survives all frame roundings")
                check(sawRoundedPause && heldFrame, "gait freezes on frames without displayed travel")
            }
        }
    }
    var constrained = CatState(now: 0)
    check(constrained.pose(slot: 0, now: 1, reduceMotion: false) == .rest, "missing lane cannot animate walking")
    constrained.minX = 10; constrained.maxX = 10
    check(constrained.pose(slot: 0, now: 1, reduceMotion: false) == .rest, "zero-width lane stands still")
    constrained.minX = 10.2; constrained.maxX = 11.8
    check(constrained.pose(slot: 0, now: 1, reduceMotion: false) == .rest, "single display position cannot animate walking")
    constrained.minX = 10; constrained.maxX = 11; constrained.logicalX = 10
    check(constrained.pose(slot: 0, now: 1, reduceMotion: false) == .walk, "expanded lane resumes wandering")
    var staysInLane = true
    for _ in 0..<100 {
        let x = constrained.advanceWalk(slot: 0, delta: 1.0 / 24, fallbackX: 10)!
        staysInLane = staysInLane && x >= 10 && x <= 11
    }
    check(staysInLane, "pixel-snapped reflections stay inside narrow lane")
    func petObject(_ pet: PetSpec) -> [String: Any] {
        ["id": pet.id, "role": pet.role.rawValue, "parent": pet.parent.map { $0 as Any } ?? NSNull(), "style": pet.style,
         "mode": pet.assignment.mode.rawValue, "epoch": pet.assignment.epoch]
    }
    func v3Object(_ pets: [PetSpec]) -> [String: Any] {
        ["version": 3, "activeChats": pets.filter { !$0.isMini && $0.assignment.mode != .idle }.count,
         "waitingChats": pets.filter { !$0.isMini && $0.assignment.mode == .awaiting }.count,
         "activeSubagents": pets.filter { $0.role == .subagent }.count, "activeJobs": pets.filter { $0.role == .job }.count,
         "pets": pets.map(petObject)]
    }
    func decodeObject(_ object: [String: Any]) -> MenagerieStatus? { MenagerieStatus.decode(try! JSONSerialization.data(withJSONObject: object)) }
    func mainPets(_ active: Int) -> [PetSpec] {
        (0..<max(3, active)).map { PetSpec(id: "s\($0)", role: .session, parent: nil, style: $0,
            assignment: Assignment(mode: $0 < active ? .thinking : .idle, epoch: $0)) }
    }
    for count in 0...10 {
        let pets = mainPets(count), decoded = decodeObject(v3Object(pets))
        check(decoded?.activeChats == count && decoded?.pets.count == max(3, count), "v3 zero-through-ten sessions without cap")
        let layouts = MenageriePlacement.layout(window: CGRect(x: 0, y: 150, width: 400, height: 500), primaryTop: 900, screens: [screen], pets: pets)
        check(layouts?.count == pets.count, "all dynamic pets packed")
        check(layouts?.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 400 && $0.frame.minY == 750 } == true, "packed bounds stay on original ledge")
        check(layouts?.allSatisfy { log2($0.scale).rounded() == log2($0.scale) } == true, "common crisp power-of-two scale")
        if let layouts {
            check(zip(layouts, layouts.dropFirst()).allSatisfy { pair in pair.0.frame.maxX <= pair.1.frame.minX }, "dynamic panels never overlap")
        }
    }
    var mixed = mainPets(4)
    mixed.append(PetSpec(id: "a0", role: .subagent, parent: "s0", style: 0, assignment: Assignment(mode: .thinking, epoch: 7)))
    mixed.append(PetSpec(id: "j0", role: .job, parent: "s0", style: 0, assignment: Assignment(mode: .thinking, epoch: 8)))
    mixed.append(PetSpec(id: "a1", role: .subagent, parent: nil, style: 4, assignment: Assignment(mode: .thinking, epoch: 9)))
    check(decodeObject(v3Object(mixed))?.activeSubagents == 2 && decodeObject(v3Object(mixed))?.activeJobs == 1, "mixed mini counts exact")
    check(MenageriePlacement.ordered(mixed).map(\.id) == ["s0", "a0", "j0", "s1", "s2", "s3", "a1"], "owned minis grouped and unowned minis last")
    let packed = MenageriePlacement.layout(window: CGRect(x: 0, y: 150, width: 1100, height: 500), primaryTop: 900, screens: [screen], pets: mixed)!
    check(packed[0].frame.maxX == packed[1].frame.minX && packed[1].frame.maxX == packed[2].frame.minX, "mini cluster sits directly beside parent")
    check(packed[0].minX == packed[0].maxX && packed[0].hasMinis, "parent with minis stationary")
    check(packed[1].frame.size == miniPanelSize && packed[1].frame.minY == packed[0].frame.minY, "natural mini size shares parent platform")
    check(MenageriePlacement.layout(window: CGRect(x: 0, y: 150, width: 2, height: 500), primaryTop: 900, screens: [screen], pets: PetSpec.bases) == nil, "unrepresentable pixel ledge hides all rather than drops pets")
    check(MenageriePlacement.layout(window: CGRect(x: 0, y: 150, width: 0, height: 500), primaryTop: 900, screens: [.zero], pets: mixed) == nil, "zero-width geometry safely rejected")
    let hole = PetSpec.bases + [PetSpec(id: "s99", role: .session, parent: nil, style: 99, assignment: Assignment(mode: .awaiting, epoch: 1))]
    check(decodeObject(v3Object(hole))?.pets.count == 4, "sparse identities do not allocate numeric gap")
    check(IdleBehavior.sample(slot: 99, elapsed: 0).pose == IdleBehavior.sample(slot: 0, elapsed: 0).pose, "large style uses breed-index idle timing")
    var wrong = v3Object(mixed); wrong["activeJobs"] = 99
    check(decodeObject(wrong) == nil, "wrong role count rejected")
    wrong = v3Object(mixed); wrong["activeChats"] = 99
    check(decodeObject(wrong) == nil, "wrong session count rejected")
    wrong = v3Object(mixed); wrong["waitingChats"] = 1
    check(decodeObject(wrong) == nil, "waiting sessions deduplicated exactly")
    wrong = v3Object(mixed); wrong["version"] = 4
    check(decodeObject(wrong) == nil, "unknown protocol rejected")
    var duplicate = mixed; duplicate.append(mixed[0])
    check(decodeObject(v3Object(duplicate)) == nil, "duplicate anonymous identities rejected")
    let badParent = PetSpec.bases + [PetSpec(id: "a2", role: .subagent, parent: "s9", style: 9, assignment: Assignment(mode: .thinking, epoch: 0))]
    check(decodeObject(v3Object(badParent)) == nil, "missing parent rejected")
    let badStyle = PetSpec.bases + [PetSpec(id: "j2", role: .job, parent: "s0", style: 1, assignment: Assignment(mode: .thinking, epoch: 0))]
    check(decodeObject(v3Object(badStyle)) == nil, "mini must inherit parent style")
    let badMode = PetSpec.bases + [PetSpec(id: "a2", role: .subagent, parent: "s0", style: 0, assignment: Assignment(mode: .awaiting, epoch: 0))]
    check(decodeObject(v3Object(badMode)) == nil, "mini cannot inherit awaiting question")
    check(decodeObject(v3Object(Array(PetSpec.bases.dropLast()))) == nil, "permanent base identities required")
    check(PetSpec.number("private-chat-id", prefix: 115) == nil && PetSpec.number("s-1", prefix: 115) == nil, "real IDs and invalid namespace rejected")
    let extraIdle = PetSpec.bases + [PetSpec(id: "s8", role: .session, parent: nil, style: 8, assignment: .idle)]
    check(decodeObject(v3Object(extraIdle)) == nil, "extra sessions must be active")
    var exactPacket = try! JSONSerialization.data(withJSONObject: v3Object(PetSpec.bases))
    exactPacket.append(Data(repeating: 32, count: maximumPacketBytes - exactPacket.count))
    check(MenagerieStatus.decode(exactPacket) != nil, "oneMiB includingLF accepted")
    exactPacket.append(32)
    check(MenagerieStatus.decode(exactPacket) == nil, "over-oneMiB packet rejected before parse")
    check(Reconciliation.removed(existing: Set(mixed.map(\.id)), incoming: PetSpec.bases) == Set(["s3", "a0", "j0", "a1"]), "removed identities released without touching bases")
    var stable = CatState(now: 0)
    stable.minX = 10; stable.maxX = 100; stable.logicalX = 20.375; stable.walkDistance = 7
    stable.accept(Assignment(mode: .thinking, epoch: 9), now: 10)
    stable.accept(Assignment(mode: .thinking, epoch: 9), now: 20)
    check(stable.logicalX == 20.375 && stable.walkDistance == 7 && stable.modeStarted == 10, "unchanged identity preserves fractional position and timing")
    check(stable.relocate(low: 110, high: 290, initial: 200, fallbackX: 20) == 130.75, "resize preserves fractional progress rather than rounded window position")
    for scale: CGFloat in [1, 0.5, 0.25] {
        var scaled = CatState(now: 0); scaled.movementScale = scale; scaled.minX = -100; scaled.maxX = 100; scaled.logicalX = 0
        var display: CGFloat = 0
        for _ in 0..<48 { display = scaled.advanceWalk(slot: 3, delta: 1.0 / 24, fallbackX: display)! }
        check(abs(scaled.logicalX! - 36 * scale) < 0.0001, "scaled fullprecision walk never stalls")
    }
    let neutral = PetTint.rgb(0.5, 0.5, 0.5, variant: 1)
    check(abs(neutral.0 - neutral.2) > 0.04, "hue variants visibly tint neutral gray")
    check(abs(0.2126 * neutral.0 + 0.7152 * neutral.1 + 0.0722 * neutral.2 - 0.5) < 0.00001, "midtone tint preserves luminance")
    let pristine = PetTint.rgb(0.3, 0.4, 0.5, variant: 0), white = PetTint.rgb(0.98, 0.98, 0.98, variant: 4)
    check(pristine.0 == 0.3 && pristine.1 == 0.4 && pristine.2 == 0.5, "base style remains pristine")
    check(white.0 == 0.98 && white.1 == 0.98 && white.2 == 0.98, "nearwhite preserved")
    check(SpriteCache().variantLimit == 64, "variant cache is bounded")
    var atlasesTested = 0
    for breed in catBreeds {
        if let url = Bundle.main.url(forResource: "\(breed)-colony", withExtension: "png") {
            let atlas = SpriteAtlas(url: url)
            check(atlas != nil, "bundled colony atlas is384x240RGBA")
            check(atlas?.frames.count == 12, "colony atlas extracts twelve cells")
            check(atlas?.frames.allSatisfy { $0.width == 96 && $0.height == 80 } == true, "colony cell dimensions")
            atlasesTested += 1
        }
    }
    check(atlasesTested == 0 || atlasesTested == 3, "colony assets cannot be partially bundled")
    var minisTested = 0
    for breed in catBreeds {
        if let url = Bundle.main.url(forResource: "\(breed)-mini", withExtension: "png") {
            let frames = SpriteCache.loadMini(url)
            check(frames?.count == 2, "mini atlas has two reading-body frames")
            check(frames?.allSatisfy { $0.width == 48 && $0.height == 40 } == true, "mini frame dimensions exact")
            if let frame = frames?.first {
                let tinted = PetTint.image(frame, variant: 1)
                check(tinted?.width == 48 && tinted?.height == 40 && tinted?.alphaInfo == .premultipliedLast, "tinted mini retains dimensions and alpha")
            }
            minisTested += 1
        }
    }
    check((atlasesTested == 0 && minisTested == 0) || (atlasesTested == 3 && minisTested == 3), "all six main and mini atlases bundled together")
    emit(["type": "self-test", "ok": true, "checks": checks, "atlasesTested": atlasesTested, "minisTested": minisTested, "protocolVersion": 3]); Darwin.exit(0)
}

func validateFixtures(_ path: String) -> Never {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]), data.count <= 16 * 1_048_576,
          let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        emit(["type": "fixtures-validated", "ok": false, "reason": "invalid-fixture-file"]); Darwin.exit(2)
    }
    let widths: [CGFloat] = [360, 640, 1200]
    for (index, object) in objects.enumerated() {
        guard let encoded = try? JSONSerialization.data(withJSONObject: object), let status = MenagerieStatus.decode(encoded), status.protocolVersion == 3 else {
            emit(["type": "fixtures-validated", "ok": false, "index": index, "reason": "v3-codec"]); Darwin.exit(1)
        }
        for width in widths {
            guard let layouts = MenageriePlacement.layout(window: CGRect(x: 0, y: 150, width: width, height: 500), primaryTop: 900, screens: [CGRect(x: 0, y: 0, width: 1440, height: 875)], pets: status.pets),
                  layouts.count == status.pets.count,
                  layouts.allSatisfy({ $0.frame.minX >= 0 && $0.frame.maxX <= width && $0.frame.minY == 750 }),
                  zip(layouts, layouts.dropFirst()).allSatisfy({ pair in pair.0.frame.maxX <= pair.1.frame.minX }) else {
                emit(["type": "fixtures-validated", "ok": false, "index": index, "width": width, "reason": "packing"]); Darwin.exit(1)
            }
        }
    }
    emit(["type": "fixtures-validated", "ok": true, "fixtures": objects.count, "widths": widths, "protocolVersion": 3]); Darwin.exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--validate-fixtures") {
    guard index + 1 < CommandLine.arguments.count else { emit(["type": "error", "reason": "fixture-path-required"]); Darwin.exit(2) }
    validateFixtures(CommandLine.arguments[index + 1])
}
if CommandLine.arguments.contains("--self-test") { selfTest() }
if CommandLine.arguments.contains("--diagnose") {
    emit(["type": "diagnose", "accessibility": AXIsProcessTrusted(), "targetBundleID": targetBundleID,
          "targetAppExists": FileManager.default.fileExists(atPath: targetAppPath),
          "targetRunning": !NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).isEmpty])
    Darwin.exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.delegate = controller
app.run()
