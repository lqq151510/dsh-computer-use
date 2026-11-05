// dsh-cu-input — latency-critical input bridge for dsh-computer-use.
//
// The fat helper (dsh-cu) links AppKit + Vision for screen reading; this one
// links CoreGraphics only, so a cold spawn is a few milliseconds instead of
// ~40 ms. It implements exactly the primitives games need:
//
//     dsh-cu-input <command> ['{json}']      one-shot (fallback path)
//     dsh-cu-input serve ['{json}']          unix-socket daemon (fast path)
//
// Daemon protocol: one JSON object per line in, one JSON object per line out.
// Responses always carry `tookMs` (helper-internal cost). The socket path is
// hash-scoped by the caller, so a rebuilt binary never talks to a stale daemon.
//
// Coordinates are Quartz global display points, top-left origin — same as the
// fat helper, so callers never convert.

import Foundation
import CoreGraphics
import Darwin

let VERSION = "input-1"

struct InputError: Error { let message: String }
func fail(_ message: String) throws -> Never { throw InputError(message: message) }

// MARK: - Argument accessors (throwing; per-request dict)

func num(_ d: [String: Any], _ key: String, _ fallback: Double? = nil) throws -> Double {
  if let n = d[key] as? NSNumber { return n.doubleValue }
  if let n = d[key] as? Double { return n }
  if let n = d[key] as? Int { return Double(n) }
  if let s = d[key] as? String, let n = Double(s) { return n }
  if let fallback { return fallback }
  try fail("missing number argument: \(key)")
}

func int(_ d: [String: Any], _ key: String, _ fallback: Int? = nil) throws -> Int {
  Int(try num(d, key, fallback.map { Double($0) }))
}

func str(_ d: [String: Any], _ key: String, _ fallback: String? = nil) throws -> String {
  if let s = d[key] as? String { return s }
  if let fallback { return fallback }
  try fail("missing string argument: \(key)")
}

func bool(_ d: [String: Any], _ key: String, _ fallback: Bool = false) -> Bool {
  if let b = d[key] as? Bool { return b }
  if let n = d[key] as? NSNumber { return n.boolValue }
  return fallback
}

// MARK: - Timing

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

/// Sleep in <=1 s chunks so holds longer than usleep's 32-bit range work.
func nap(_ ms: Double) {
  var remaining = max(0, ms) * 1000
  while remaining > 0 {
    let chunk = min(remaining, 1_000_000)
    usleep(useconds_t(chunk))
    remaining -= chunk
  }
}

/// Inter-event gaps. `game` trims them to the minimum macOS reliably delivers.
struct Gaps { let downUp: Double; let clickPause: Double; let tail: Double }
func gaps(_ game: Bool) -> Gaps {
  game ? Gaps(downUp: 3, clickPause: 0, tail: 0)
       : Gaps(downUp: 12, clickPause: 60, tail: 20)
}

// MARK: - Event primitives (CoreGraphics only)

func eventSource() -> CGEventSource? { CGEventSource(stateID: .hidSystemState) }

func cursorPoint() -> CGPoint {
  if let event = CGEvent(source: nil) { return event.location }
  return CGPoint(x: 0, y: 0)
}

struct ButtonSpec {
  let button: CGMouseButton
  let down: CGEventType
  let up: CGEventType
  let dragged: CGEventType
}

func buttonSpec(_ name: String) -> ButtonSpec {
  switch name.lowercased() {
  case "right":
    return ButtonSpec(button: .right, down: .rightMouseDown, up: .rightMouseUp, dragged: .rightMouseDragged)
  case "middle", "center":
    return ButtonSpec(button: .center, down: .otherMouseDown, up: .otherMouseUp, dragged: .otherMouseDragged)
  default:
    return ButtonSpec(button: .left, down: .leftMouseDown, up: .leftMouseUp, dragged: .leftMouseDragged)
  }
}

func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
  guard let event = CGEvent(mouseEventSource: eventSource(), mouseType: type,
                            mouseCursorPosition: point, mouseButton: button) else { return }
  event.post(tap: .cghidEventTap)
}

// kCGMouseEventDeltaX = 4 / kCGMouseEventDeltaY = 5 in this SDK's CGEventField.
let deltaFieldX = CGEventField(rawValue: 4)!
let deltaFieldY = CGEventField(rawValue: 5)!

/// One relative-motion event: cursor moves by (dx, dy) AND the event carries
/// the delta fields, so games reading raw deltas see the motion too.
func postRelative(dx: Double, dy: Double) {
  let current = cursorPoint()
  let target = CGPoint(x: current.x + dx, y: current.y + dy)
  guard let event = CGEvent(mouseEventSource: eventSource(), mouseType: .mouseMoved,
                            mouseCursorPosition: target, mouseButton: .left) else { return }
  event.setIntegerValueField(deltaFieldX, value: Int64(dx.rounded()))
  event.setIntegerValueField(deltaFieldY, value: Int64(dy.rounded()))
  event.post(tap: .cghidEventTap)
}

/// Smooth relative sweep over `durationMs` (camera-style), ~8 ms per event.
func sweepRelative(dx: Double, dy: Double, durationMs: Double, game: Bool) {
  let steps = max(2, Int(durationMs / 8))
  let per = (durationMs / Double(steps)) / 1000
  for step in 1...steps {
    postRelative(dx: dx / Double(steps), dy: dy / Double(steps))
    if step < steps { usleep(useconds_t(max(per * 1_000_000, 500))) }
  }
  _ = game
}

/// Humanized absolute path: quadratic bezier + smoothstep easing + jitter.
/// Returns (points, per-step interval ms).
func humanPath(from: CGPoint, to: CGPoint) -> [(point: CGPoint, intervalMs: Double)] {
  let distance = hypot(to.x - from.x, to.y - from.y)
  let steps = max(8, min(64, Int(distance / 9) + 8))
  let bend = min(distance * 0.18, 60) * (Double.random(in: -1...1))
  let angle = atan2(to.y - from.y, to.x - from.x) + Double.pi / 2
  let control = CGPoint(x: (from.x + to.x) / 2 + cos(angle) * bend,
                        y: (from.y + to.y) / 2 + sin(angle) * bend)
  var out: [(CGPoint, Double)] = []
  for step in 1...steps {
    let t = Double(step) / Double(steps)
    let eased = t * t * (3 - 2 * t)
    let u = 1 - eased
    var point = CGPoint(
      x: u * u * from.x + 2 * u * eased * control.x + eased * eased * to.x,
      y: u * u * from.y + 2 * u * eased * control.y + eased * eased * to.y)
    if step < steps {
      point.x += Double.random(in: -0.7...0.7)
      point.y += Double.random(in: -0.7...0.7)
    }
    out.append((point, Double.random(in: 6...14)))
  }
  return out
}

func moveTo(_ target: CGPoint, durationMs: Double, humanize: Bool, game: Bool) {
  let start = cursorPoint()
  if humanize && !game && durationMs <= 0 {
    for (point, interval) in humanPath(from: start, to: target) {
      postMouse(.mouseMoved, at: point, button: .left)
      usleep(useconds_t(interval * 1000))
    }
    return
  }
  if durationMs <= 0 {
    postMouse(.mouseMoved, at: target, button: .left)
    return
  }
  let steps = max(2, Int(durationMs / 12))
  for step in 1...steps {
    let t = Double(step) / Double(steps)
    let point = CGPoint(x: start.x + (target.x - start.x) * t,
                        y: start.y + (target.y - start.y) * t)
    postMouse(.mouseMoved, at: point, button: .left)
    usleep(12_000)
  }
  _ = game
}

// MARK: - Keyboard

let keyCodes: [String: CGKeyCode] = [
  "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
  "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
  "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25,
  "7": 26, "minus": 27, "8": 28, "0": 29, "rightbracket": 30, "o": 31, "u": 32,
  "leftbracket": 33, "i": 34, "p": 35, "l": 37, "j": 38, "quote": 39, "k": 40,
  "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46,
  "period": 47, "tab": 48, "space": 49, "grave": 50,
  "return": 36, "enter": 76, "escape": 53, "esc": 53, "delete": 51, "backspace": 51,
  "forwarddelete": 117, "help": 114,
  "left": 123, "right": 124, "down": 125, "up": 126,
  "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
  "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
  "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
  "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79,
  "f19": 80, "f20": 90,
]

let modifierCodes: [String: CGKeyCode] = [
  "command": 55, "cmd": 55, "meta": 55, "super": 55,
  "shift": 56,
  "option": 58, "alt": 58,
  "control": 59, "ctrl": 59,
  "fn": 63,
]

func modifierFlags(_ names: [String]) -> CGEventFlags {
  var flags: CGEventFlags = []
  for raw in names {
    switch raw.lowercased() {
    case "command", "cmd", "meta", "super": flags.insert(.maskCommand)
    case "shift": flags.insert(.maskShift)
    case "option", "alt": flags.insert(.maskAlternate)
    case "control", "ctrl": flags.insert(.maskControl)
    case "fn": flags.insert(.maskSecondaryFn)
    default: break
    }
  }
  return flags
}

func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
  guard let event = CGEvent(keyboardEventSource: eventSource(), virtualKey: code, keyDown: down) else { return }
  event.flags = flags
  event.post(tap: .cghidEventTap)
}

func postUnicode(_ text: String, chunkLimit: Int = 16, gapMs: Int = 15) {
  guard !text.isEmpty else { return }
  let units = Array(text.utf16)
  var offset = 0
  while offset < units.count {
    let end = min(offset + chunkLimit, units.count)
    var slice = Array(units[offset..<end])
    let count = slice.count
    let source = eventSource()
    if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
      slice.withUnsafeMutableBufferPointer { buffer in
        down.keyboardSetUnicodeString(stringLength: count, unicodeString: buffer.baseAddress)
      }
      down.post(tap: .cghidEventTap)
    }
    if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
      slice.withUnsafeMutableBufferPointer { buffer in
        up.keyboardSetUnicodeString(stringLength: count, unicodeString: buffer.baseAddress)
      }
      up.post(tap: .cghidEventTap)
    }
    offset = end
    if offset < units.count { usleep(useconds_t(max(gapMs, 1)) * 1000) }
  }
  usleep(useconds_t(max(gapMs, 1)) * 1000)
}

// MARK: - Commands

func cmdCursor(_ d: [String: Any]) throws -> [String: Any] {
  let point = cursorPoint()
  return ["ok": true, "x": point.x, "y": point.y]
}

func cmdMove(_ d: [String: Any]) throws -> [String: Any] {
  let game = bool(d, "game")
  let humanize = bool(d, "humanize")
  let durationMs = try num(d, "durationMs", 0)
  if d["dx"] != nil || d["dy"] != nil {
    let dx = try num(d, "dx", 0)
    let dy = try num(d, "dy", 0)
    if durationMs > 0 {
      sweepRelative(dx: dx, dy: dy, durationMs: durationMs, game: game)
    } else {
      postRelative(dx: dx, dy: dy)
    }
    // Event delivery is async; give the window server a beat so the reported
    // cursor position reflects the move we just posted.
    nap(game ? 4 : 10)
    let point = cursorPoint()
    return ["ok": true, "x": point.x, "y": point.y, "relative": ["dx": dx, "dy": dy]]
  }
  let target = CGPoint(x: try num(d, "x"), y: try num(d, "y"))
  moveTo(target, durationMs: durationMs, humanize: humanize, game: game)
  let point = cursorPoint()
  return ["ok": true, "x": point.x, "y": point.y]
}

func cmdClick(_ d: [String: Any]) throws -> [String: Any] {
  let game = bool(d, "game")
  let humanize = bool(d, "humanize")
  let spec = buttonSpec(try str(d, "button", "left"))
  let gap = gaps(game)
  let hasPoint = d["x"] != nil || d["y"] != nil
  let point = CGPoint(x: try num(d, "x", cursorPoint().x), y: try num(d, "y", cursorPoint().y))
  if hasPoint { moveTo(point, durationMs: 0, humanize: humanize, game: game) }
  let downMs = try num(d, "downMs", game ? 4 : 14)
  let repeatShots = try int(d, "repeat", 0)
  let uiCount = try int(d, "count", 1)
  let intervalMs = try num(d, "intervalMs", game ? 40 : 80)
  let pauseMs = try num(d, "pauseMs", gap.clickPause)
  let shots = max(1, repeatShots > 0 ? repeatShots : uiCount)
  for shot in 0..<shots {
    // `repeat` fires independent single clicks (games); `count` is the UI
    // multi-click protocol where clickState increments 1..n.
    let clickState = repeatShots > 0 ? 1 : shot + 1
    guard let down = CGEvent(mouseEventSource: eventSource(), mouseType: spec.down,
                             mouseCursorPosition: point, mouseButton: spec.button) else { continue }
    down.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
    down.post(tap: .cghidEventTap)
    nap(downMs)
    guard let up = CGEvent(mouseEventSource: eventSource(), mouseType: spec.up,
                           mouseCursorPosition: point, mouseButton: spec.button) else { continue }
    up.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
    up.post(tap: .cghidEventTap)
    if shot < shots - 1 {
      nap(repeatShots > 0 ? intervalMs : pauseMs)
    }
  }
  nap(gap.tail)
  let now = cursorPoint()
  var result: [String: Any] = ["ok": true, "x": now.x, "y": now.y, "button": try str(d, "button", "left")]
  if repeatShots > 0 { result["repeat"] = repeatShots; result["intervalMs"] = intervalMs }
  else { result["count"] = uiCount }
  return result
}

func cmdHold(_ d: [String: Any]) throws -> [String: Any] {
  let spec = buttonSpec(try str(d, "button", "left"))
  let hasPoint = d["x"] != nil || d["y"] != nil
  let point = CGPoint(x: try num(d, "x", cursorPoint().x), y: try num(d, "y", cursorPoint().y))
  if hasPoint { postMouse(.mouseMoved, at: point, button: spec.button) }
  let holdMs = try num(d, "holdMs", 200)
  guard let down = CGEvent(mouseEventSource: eventSource(), mouseType: spec.down,
                           mouseCursorPosition: point, mouseButton: spec.button) else {
    try fail("could not create mouse-down event")
  }
  down.post(tap: .cghidEventTap)
  nap(holdMs)
  guard let up = CGEvent(mouseEventSource: eventSource(), mouseType: spec.up,
                         mouseCursorPosition: point, mouseButton: spec.button) else {
    try fail("could not create mouse-up event")
  }
  up.post(tap: .cghidEventTap)
  return ["ok": true, "button": try str(d, "button", "left"), "holdMs": holdMs]
}

func cmdDrag(_ d: [String: Any]) throws -> [String: Any] {
  let game = bool(d, "game")
  let humanize = bool(d, "humanize")
  let spec = buttonSpec(try str(d, "button", "left"))
  let from = CGPoint(x: try num(d, "fromX"), y: try num(d, "fromY"))
  let to = CGPoint(x: try num(d, "toX"), y: try num(d, "toY"))
  let durationMs = try num(d, "durationMs", 400)
  moveTo(from, durationMs: 0, humanize: false, game: game)
  nap(game ? 2 : 20)
  CGEvent(mouseEventSource: eventSource(), mouseType: spec.down,
          mouseCursorPosition: from, mouseButton: spec.button)?.post(tap: .cghidEventTap)
  nap(game ? 2 : 20)
  if humanize && !game {
    var previous = from
    for (point, interval) in humanPath(from: from, to: to) {
      CGEvent(mouseEventSource: eventSource(), mouseType: spec.dragged,
              mouseCursorPosition: point, mouseButton: spec.button)?.post(tap: .cghidEventTap)
      usleep(useconds_t(interval * 1000))
      previous = point
    }
    _ = previous
  } else {
    let steps = max(8, Int(max(durationMs, 200) / 12))
    for step in 1...steps {
      let t = Double(step) / Double(steps)
      let point = CGPoint(x: from.x + (to.x - from.x) * t,
                          y: from.y + (to.y - from.y) * t)
      CGEvent(mouseEventSource: eventSource(), mouseType: spec.dragged,
              mouseCursorPosition: point, mouseButton: spec.button)?.post(tap: .cghidEventTap)
      usleep(12_000)
    }
  }
  nap(game ? 2 : 20)
  CGEvent(mouseEventSource: eventSource(), mouseType: spec.up,
          mouseCursorPosition: to, mouseButton: spec.button)?.post(tap: .cghidEventTap)
  let now = cursorPoint()
  return ["ok": true, "x": now.x, "y": now.y]
}

func cmdScroll(_ d: [String: Any]) throws -> [String: Any] {
  let game = bool(d, "game")
  let point = CGPoint(x: try num(d, "x", cursorPoint().x), y: try num(d, "y", cursorPoint().y))
  let dy = try num(d, "dy", 0)
  let dx = try num(d, "dx", 0)
  postMouse(.mouseMoved, at: point, button: .left)
  nap(game ? 2 : 15)
  // wheel1 > 0 scrolls content up, so a caller's "dy > 0 = down" is negated.
  if let event = CGEvent(scrollWheelEvent2Source: eventSource(), units: .pixel,
                         wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) {
    event.post(tap: .cghidEventTap)
  }
  nap(game ? 2 : 20)
  return ["ok": true, "dy": dy, "dx": dx]
}

func cmdKey(_ d: [String: Any]) throws -> [String: Any] {
  let game = bool(d, "game")
  let name = try str(d, "key")
  guard let code = keyCodes[name.lowercased()] else { try fail("unknown key name: \(name)") }
  let modifiers = (d["modifiers"] as? [Any])?.compactMap { $0 as? String } ?? []
  let held = modifiers.compactMap { modifierCodes[$0.lowercased()] }
  var flags: CGEventFlags = []
  for modifier in modifiers {
    for (label, modifierCode) in modifierCodes where label == modifier.lowercased() {
      postKey(modifierCode, down: true, flags: flags)
      flags.formUnion(modifierFlags([modifier]))
      break
    }
  }
  nap(game ? 2 : 8)
  postKey(code, down: true, flags: flags)
  nap(try num(d, "holdMs", game ? 4 : 14))
  postKey(code, down: false, flags: flags)
  nap(game ? 2 : 8)
  for modifierCode in held.reversed() { postKey(modifierCode, down: false, flags: []) }
  return ["ok": true, "key": name, "modifiers": modifiers]
}

func cmdType(_ d: [String: Any]) throws -> [String: Any] {
  let text = try str(d, "text")
  let game = bool(d, "game")
  postUnicode(text, chunkLimit: 16, gapMs: game ? 3 : 15)
  return ["ok": true, "length": text.count]
}

func cmdWait(_ d: [String: Any]) throws -> [String: Any] {
  let ms = try num(d, "ms", 0)
  nap(ms)
  return ["ok": true, "waitedMs": ms]
}

/// Execute one sequence step. `do` names the primitive; step params are the
/// same as the standalone command's.
func runStep(_ step: [String: Any]) throws -> [String: Any] {
  let kind = try str(step, "do")
  switch kind {
  case "move": return try cmdMove(step)
  case "click": return try cmdClick(step)
  case "hold": return try cmdHold(step)
  case "drag": return try cmdDrag(step)
  case "scroll": return try cmdScroll(step)
  case "key": return try cmdKey(step)
  case "type": return try cmdType(step)
  case "wait": return try cmdWait(step)
  default: try fail("unknown step do: \(kind)")
  }
}

func cmdSequence(_ d: [String: Any]) throws -> [String: Any] {
  guard let rawSteps = d["steps"] as? [[String: Any]], !rawSteps.isEmpty else {
    try fail("sequence needs a non-empty steps array")
  }
  let gameDefault = bool(d, "game")
  var results: [[String: Any]] = []
  for (index, raw) in rawSteps.enumerated() {
    var step = raw
    if step["game"] == nil { step["game"] = gameDefault }
    let started = nowMs()
    do {
      var one = try runStep(step)
      one.removeValue(forKey: "ok")
      one["i"] = index
      one["tookMs"] = (nowMs() - started).rounded()
      results.append(one)
    } catch let error as InputError {
      results.append(["i": index, "ok": false, "error": error.message])
      if bool(step, "stopOnError", true) { break }
    }
    nap(try num(step, "afterMs", 0))
  }
  let point = cursorPoint()
  return ["ok": true, "steps": results, "x": point.x, "y": point.y]
}

// MARK: - Dispatch

func execute(_ request: [String: Any]) -> [String: Any] {
  let started = nowMs()
  let command = (request["command"] as? String) ?? ""
  do {
    var result: [String: Any]
    switch command {
    case "ping":
      result = ["ok": true, "name": "dsh-cu-input", "version": VERSION, "pid": Int(getpid())]
    case "cursor": result = try cmdCursor(request)
    case "move": result = try cmdMove(request)
    case "click": result = try cmdClick(request)
    case "hold": result = try cmdHold(request)
    case "drag": result = try cmdDrag(request)
    case "scroll": result = try cmdScroll(request)
    case "key": result = try cmdKey(request)
    case "type": result = try cmdType(request)
    case "sequence": result = try cmdSequence(request)
    case "stop":
      result = ["ok": true, "bye": true]
      if let path = servingSocketPath { unlink(path) }
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
    default:
      result = ["ok": false, "error": "unknown command: \(command)"]
    }
    result["tookMs"] = (nowMs() - started).rounded()
    return result
  } catch let error as InputError {
    return ["ok": false, "error": error.message, "tookMs": (nowMs() - started).rounded()]
  } catch {
    return ["ok": false, "error": "\(error)", "tookMs": (nowMs() - started).rounded()]
  }
}

// MARK: - JSON line IO

func encodeLine(_ object: [String: Any]) -> Data? {
  guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
  return data + Data([10])
}

func emit(_ object: [String: Any]) {
  if let data = encodeLine(object) { FileHandle.standardOutput.write(data) }
}

func writeLine(_ fd: Int32, _ object: [String: Any]) {
  guard let data = encodeLine(object) else { return }
  var offset = 0
  let bytes = [UInt8](data)
  while offset < bytes.count {
    let n = bytes.withUnsafeBufferPointer { buffer -> Int in
      write(fd, buffer.baseAddress! + offset, bytes.count - offset)
    }
    if n <= 0 { break }
    offset += n
  }
}

// MARK: - Daemon (unix socket)

let activityLock = NSLock()
var lastActivityMs: Double = 0
var servingSocketPath: String?
func touchActivity() {
  activityLock.lock(); lastActivityMs = nowMs(); activityLock.unlock()
}

func handleConnection(fd: Int32, workQueue: DispatchQueue) {
  touchActivity()
  var buffer = Data()
  let chunk = [UInt8](repeating: 0, count: 65_536)
  var chunkCopy = chunk
  while true {
    let n = chunkCopy.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
    if n <= 0 { break }
    touchActivity()
    buffer.append(contentsOf: chunkCopy[0..<n])
    while let range = buffer.firstRange(of: Data([10])) {
      let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
      buffer.removeSubrange(buffer.startIndex..<range.upperBound)
      guard !line.isEmpty,
            let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
        workQueue.async { writeLine(fd, ["ok": false, "error": "bad-json"]) }
        continue
      }
      workQueue.async { writeLine(fd, execute(request)) }
    }
  }
  workQueue.sync {}  // drain pending responses before closing the fd
  close(fd)
}

func quickPing(_ path: String) -> [String: Any]? {
  guard let fd = connectSocket(path) else { return nil }
  writeLine(fd, ["command": "ping"])
  let response = readOneLine(fd, timeoutMs: 1_000)
  close(fd)
  return response
}

func connectSocket(_ path: String) -> Int32? {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  guard bytes.count < 104 else { close(fd); return nil }
  withUnsafeMutablePointer(to: &addr.sun_path) { dest in
    dest.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { pointer in
      bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: pointer, count: bytes.count))
    }
  }
  let bound = withUnsafePointer(to: &addr) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
      connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  if bound != 0 { close(fd); return nil }
  return fd
}

func readOneLine(_ fd: Int32, timeoutMs: Double) -> [String: Any]? {
  var buffer = Data()
  let chunk = [UInt8](repeating: 0, count: 16_384)
  var chunkCopy = chunk
  let deadline = nowMs() + timeoutMs
  while nowMs() < deadline {
    let n = chunkCopy.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
    if n <= 0 { break }
    buffer.append(contentsOf: chunkCopy[0..<n])
    if let range = buffer.firstRange(of: Data([10])) {
      let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
      return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
  }
  return nil
}

func serve(_ d: [String: Any]) throws {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let socketPath = try str(d, "socket", home + "/.dsh/computer-use/cu-input.sock")
  let idleSec = try num(d, "idleSec", 900)

  if let pong = quickPing(socketPath) {
    emit(["ok": true, "alreadyRunning": true, "version": pong["version"] ?? "", "socket": socketPath])
    return
  }
  unlink(socketPath)

  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { try fail("socket() failed: \(errno)") }
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(socketPath.utf8)
  guard bytes.count < 104 else { try fail("socket path too long") }
  withUnsafeMutablePointer(to: &addr.sun_path) { dest in
    dest.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { pointer in
      bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: pointer, count: bytes.count))
    }
  }
  let bound = withUnsafePointer(to: &addr) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
      bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard bound == 0 else { try fail("bind(\(socketPath)) failed: \(errno)") }
  guard listen(fd, 32) == 0 else { try fail("listen failed: \(errno)") }
  chmod(socketPath, 0o600)
  servingSocketPath = socketPath
  touchActivity()

  let workQueue = DispatchQueue(label: "dsh-cu-input.work", qos: .userInteractive)
  DispatchQueue.global(qos: .userInitiated).async {
    while true {
      let client = accept(fd, nil, nil)
      if client < 0 { break }
      DispatchQueue.global(qos: .userInteractive).async {
        handleConnection(fd: client, workQueue: workQueue)
      }
    }
  }

  // Idle watchdog: exit when nothing has talked to us for `idleSec`.
  DispatchQueue.global(qos: .utility).async {
    while true {
      Thread.sleep(forTimeInterval: 15)
      activityLock.lock()
      let idle = nowMs() - lastActivityMs
      activityLock.unlock()
      if idle > idleSec * 1000 { exit(0) }
    }
  }

  emit(["ok": true, "serving": true, "socket": socketPath, "pid": Int(getpid()), "version": VERSION])
  dispatchMain()
}

// MARK: - Entry

let argv = CommandLine.arguments
guard argv.count >= 2 else {
  FileHandle.standardOutput.write(Data(#"{"ok":false,"error":"usage: dsh-cu-input <command> [json]"}"#.utf8))
  exit(2)
}

let command = argv[1]
var request: [String: Any] = ["command": command]
if argv.count >= 3, let data = argv[2].data(using: .utf8),
   let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
  for (key, value) in parsed where key != "command" { request[key] = value }
}

if command == "serve" {
  do { try serve(request) } catch let error as InputError {
    emit(["ok": false, "error": error.message]); exit(1)
  } catch {
    emit(["ok": false, "error": "\(error)"]); exit(1)
  }
}

let outcome = execute(request)
if let data = encodeLine(outcome) {
  FileHandle.standardOutput.write(data)
}
exit(outcome["ok"] as? Bool == true ? 0 : 1)
