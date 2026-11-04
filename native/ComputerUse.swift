// dsh-computer-use native helper.
//
// A tiny, dependency-free bridge from the DeepSeek Harness Host process to
// macOS CoreGraphics / AppKit so an Agent can actually move the pointer, click,
// drag, scroll and type. It speaks one JSON object per invocation:
//
//     dsh-cu <command> ['{"json":"args"}']
//
// Every command prints one JSON object on stdout. Failures print
// `{"ok":false,"error":"..."}` and exit non-zero.
//
// Coordinates are Quartz global display coordinates: origin at the top-left of
// the main display, +x right, +y down, unit = points (not pixels). This matches
// CGEvent, so callers never convert.

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Vision
import ImageIO

// MARK: - JSON plumbing

func emit(_ object: Any) {
  guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
    FileHandle.standardOutput.write(Data(#"{"ok":false,"error":"json-encode-failed"}"#.utf8) + Data([10]))
    exit(2)
  }
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([10]))
}

func fail(_ message: String) -> Never {
  emit(["ok": false, "error": message])
  exit(1)
}

let argv = CommandLine.arguments
guard argv.count >= 2 else { fail("usage: dsh-cu <command> [json]") }
let command = argv[1]

var input: [String: Any] = [:]
if argv.count >= 3, let data = argv[2].data(using: .utf8) {
  if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    input = parsed
  } else {
    fail("args must be a JSON object")
  }
}

func number(_ key: String, _ fallback: Double? = nil) -> Double {
  if let n = input[key] as? NSNumber { return n.doubleValue }
  if let n = input[key] as? Double { return n }
  if let n = input[key] as? Int { return Double(n) }
  if let string = input[key] as? String, let n = Double(string) { return n }
  if let fallback { return fallback }
  fail("missing number argument: \(key)")
}

func int(_ key: String, _ fallback: Int? = nil) -> Int {
  if let n = input[key] as? NSNumber { return n.intValue }
  if let n = input[key] as? Int { return n }
  if let string = input[key] as? String, let n = Int(string) { return n }
  if let fallback { return fallback }
  fail("missing integer argument: \(key)")
}

func string(_ key: String, _ fallback: String? = nil) -> String {
  if let s = input[key] as? String { return s }
  if let fallback { return fallback }
  fail("missing string argument: \(key)")
}

func stringList(_ key: String) -> [String] {
  if let list = input[key] as? [String] { return list }
  if let list = input[key] as? [Any] { return list.compactMap { $0 as? String } }
  return []
}

func bool(_ key: String, _ fallback: Bool = false) -> Bool {
  if let b = input[key] as? Bool { return b }
  if let n = input[key] as? NSNumber { return n.boolValue }
  if let s = input[key] as? String { return ["1", "true", "yes"].contains(s.lowercased()) }
  return fallback
}

// MARK: - Displays, cursor, process facts

func screenList() -> [[String: Any]] {
  var out: [[String: Any]] = []
  for (index, screen) in NSScreen.screens.enumerated() {
    var bounds = screen.frame
    if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
       let display = CGDirectDisplayID(exactly: screenNumber.uint32Value) {
      bounds = CGDisplayBounds(display)
    }
    out.append([
      "index": index + 1,
      "x": bounds.origin.x,
      "y": bounds.origin.y,
      "width": bounds.width,
      "height": bounds.height,
      "scale": screen.backingScaleFactor,
    ])
  }
  return out
}

func cursorPoint() -> CGPoint {
  if let event = CGEvent(source: nil) { return event.location }
  let point = NSEvent.mouseLocation
  let top = NSScreen.screens.first?.frame.height ?? 0
  return CGPoint(x: point.x, y: top - point.y)
}

func frontmost() -> [String: Any] {
  guard let app = NSWorkspace.shared.frontmostApplication else { return [:] }
  return [
    "name": app.localizedName ?? "",
    "bundleId": app.bundleIdentifier ?? "",
    "pid": Int(app.processIdentifier),
  ]
}

func permissionState() -> [String: Any] {
  let trusted = AXIsProcessTrusted()
  var screenCapture = true
  if #available(macOS 10.15, *) {
    screenCapture = CGPreflightScreenCaptureAccess()
  }
  return ["accessibility": trusted, "screenCapture": screenCapture]
}

// MARK: - Event primitives

func eventSource() -> CGEventSource? {
  CGEventSource(stateID: .hidSystemState)
}

func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
  guard let event = CGEvent(mouseEventSource: eventSource(), mouseType: type,
                            mouseCursorPosition: point, mouseButton: button) else { return }
  event.post(tap: .cghidEventTap)
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

func moveTo(_ target: CGPoint, durationMs: Double) {
  let start = cursorPoint()
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
}

func click(at point: CGPoint, button: String, count: Int, pauseMs: Double) {
  moveTo(point, durationMs: 0)
  let spec = buttonSpec(button)
  for index in 1...max(1, count) {
    let down = CGEvent(mouseEventSource: eventSource(), mouseType: spec.down,
                       mouseCursorPosition: point, mouseButton: spec.button)
    down?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
    down?.post(tap: .cghidEventTap)
    usleep(15_000)
    let up = CGEvent(mouseEventSource: eventSource(), mouseType: spec.up,
                     mouseCursorPosition: point, mouseButton: spec.button)
    up?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
    up?.post(tap: .cghidEventTap)
    if pauseMs > 0 { usleep(useconds_t(pauseMs * 1000)) }
  }
}

func drag(from: CGPoint, to: CGPoint, button: String, durationMs: Double) {
  let spec = buttonSpec(button)
  moveTo(from, durationMs: 0)
  usleep(20_000)
  CGEvent(mouseEventSource: eventSource(), mouseType: spec.down,
          mouseCursorPosition: from, mouseButton: spec.button)?.post(tap: .cghidEventTap)
  usleep(20_000)
  let steps = max(8, Int(max(durationMs, 200) / 12))
  for step in 1...steps {
    let t = Double(step) / Double(steps)
    let point = CGPoint(x: from.x + (to.x - from.x) * t,
                        y: from.y + (to.y - from.y) * t)
    CGEvent(mouseEventSource: eventSource(), mouseType: spec.dragged,
            mouseCursorPosition: point, mouseButton: spec.button)?.post(tap: .cghidEventTap)
    usleep(12_000)
  }
  usleep(20_000)
  CGEvent(mouseEventSource: eventSource(), mouseType: spec.up,
          mouseCursorPosition: to, mouseButton: spec.button)?.post(tap: .cghidEventTap)
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
  // A single event carries up to `chunkLimit` UTF-16 units; short strings go in
  // one event, longer ones are split with a gap so the target app can keep up.
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

// MARK: - Accessibility tree

let interactiveRoles: Set<String> = [
  "AXButton", "AXTextField", "AXTextArea", "AXLink", "AXCheckBox", "AXRadioButton",
  "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuItemCheckbox", "AXMenuItemRadio",
  "AXTabGroup", "AXRadioGroup", "AXSlider", "AXSearchField", "AXComboBox", "AXCell",
  "AXRow", "AXOutline", "AXList", "AXTable", "AXTree", "AXToggle", "AXIncrementor",
  "AXDisclosureTriangle", "AXPopUpButton", "AXToolbarButton", "AXColorWell",
]

func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
  var value: CFTypeRef?
  let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
  return status == .success ? value : nil
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
  if let text = axCopy(element, attribute) as? String, !text.isEmpty { return text }
  return nil
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
  if let list = axCopy(element, kAXChildrenAttribute) as? [AXUIElement] { return list }
  return []
}

func axFrame(_ element: AXUIElement) -> CGRect? {
  guard let positionValue = axCopy(element, kAXPositionAttribute),
        let sizeValue = axCopy(element, kAXSizeAttribute),
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
  var point = CGPoint.zero
  var size = CGSize.zero
  guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
  return CGRect(origin: point, size: size)
}

func axActions(_ element: AXUIElement) -> [String] {
  var names: CFArray?
  guard AXUIElementCopyActionNames(element, &names) == .success,
        let list = names as? [String] else { return [] }
  return list
}

func axSnapshot(root: AXUIElement, maxDepth: Int, maxNodes: Int, interactiveOnly: Bool) -> [[String: Any]] {
  var output: [[String: Any]] = []
  var stack: [(AXUIElement, [Int], Int)] = [(root, [], 0)]
  while let (element, path, depth) = stack.popLast() {
    if output.count >= maxNodes { break }
    var children = axChildren(element)
    if depth == 0 {
      // Keep the menu bar at the end so window content is listed first.
      let menuBar = children.filter { (axCopy($0, kAXRoleAttribute) as? String) == "AXMenuBar" }
      children = children.filter { (axCopy($0, kAXRoleAttribute) as? String) != "AXMenuBar" } + menuBar
    }
    if depth < maxDepth {
      for (offset, child) in children.enumerated().reversed() {
        stack.append((child, path + [offset], depth + 1))
      }
    }
    let role = (axCopy(element, kAXRoleAttribute) as? String) ?? ""
    if role == "AXApplication" || role == "AXWindow" && path.isEmpty { continue }
    let frame = axFrame(element)
    let actions = axActions(element)
    let title = axString(element, kAXTitleAttribute)
      ?? axString(element, kAXDescriptionAttribute)
      ?? axString(element, kAXPlaceholderValueAttribute)
    var value = ""
    if let raw = axCopy(element, kAXValueAttribute) as? String { value = raw }
    else if let raw = axCopy(element, kAXValueAttribute) as? NSNumber { value = raw.stringValue }
    if value.count > 240 { value = String(value.prefix(240)) }
    let isInteractive = interactiveRoles.contains(role) || !actions.isEmpty
    if interactiveOnly && !isInteractive { continue }
    if let frame, frame.width <= 1 || frame.height <= 1 { continue }
    var entry: [String: Any] = [
      "path": path,
      "role": role,
      "interactive": isInteractive,
    ]
    if !role.isEmpty { entry["roleDescription"] = axString(element, kAXRoleDescriptionAttribute) ?? role }
    if let subrole = axString(element, kAXSubroleAttribute) { entry["subrole"] = subrole }
    if let title { entry["title"] = title }
    if !value.isEmpty { entry["value"] = value }
    if !actions.isEmpty { entry["actions"] = actions }
    if let frame {
      entry["x"] = (frame.origin.x * 10).rounded() / 10
      entry["y"] = (frame.origin.y * 10).rounded() / 10
      entry["width"] = (frame.size.width * 10).rounded() / 10
      entry["height"] = (frame.size.height * 10).rounded() / 10
      entry["centerX"] = ((frame.origin.x + frame.size.width / 2) * 10).rounded() / 10
      entry["centerY"] = ((frame.origin.y + frame.size.height / 2) * 10).rounded() / 10
    }
    if let focused = axCopy(element, kAXFocusedAttribute) as? Bool, focused { entry["focused"] = true }
    if let enabled = axCopy(element, kAXEnabledAttribute) as? Bool, !enabled { entry["disabled"] = true }
    output.append(entry)
  }
  return output
}

func resolveApp(_ name: String) -> NSRunningApplication? {
  let wanted = name.lowercased()
  let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
  if let exact = apps.first(where: { ($0.localizedName ?? "").lowercased() == wanted
    || ($0.bundleIdentifier ?? "").lowercased() == wanted
    || ($0.executableURL?.lastPathComponent ?? "").lowercased() == wanted }) { return exact }
  return apps.first { ($0.localizedName ?? "").lowercased().contains(wanted) }
}


func axMatches(_ element: AXUIElement, fingerprint: [String: Any]) -> Bool {
  if let role = fingerprint["role"] as? String,
     (axCopy(element, kAXRoleAttribute) as? String) != role {
    return false
  }
  if let title = fingerprint["title"] as? String, !title.isEmpty {
    let candidates = [
      axString(element, kAXTitleAttribute),
      axString(element, kAXDescriptionAttribute),
      axString(element, kAXPlaceholderValueAttribute),
      axString(element, kAXValueAttribute),
    ].compactMap { $0 }
    if !candidates.contains(title) { return false }
  }
  if let x = fingerprint["x"] as? Double, let y = fingerprint["y"] as? Double,
     let frame = axFrame(element) {
    if abs(Double(frame.origin.x) - x) > 4 || abs(Double(frame.origin.y) - y) > 4 {
      return false
    }
  }
  return true
}

func axSearch(root: AXUIElement, fingerprint: [String: Any], maxNodes: Int) -> AXUIElement? {
  var queue: [AXUIElement] = [root]
  var visited = 0
  while !queue.isEmpty && visited < maxNodes {
    let element = queue.removeFirst()
    visited += 1
    if axMatches(element, fingerprint: fingerprint) { return element }
    queue.append(contentsOf: axChildren(element))
  }
  return nil
}

func axElement(at path: [Int], root: AXUIElement) -> AXUIElement? {
  var current = root
  for index in path {
    let children = axChildren(current)
    guard index >= 0 && index < children.count else { return nil }
    current = children[index]
  }
  return current
}

// MARK: - OCR (Vision)

func resizedImage(_ image: CGImage, maxDimension: Double) -> CGImage {
  let longest = Double(max(image.width, image.height))
  guard maxDimension > 0, longest > maxDimension else { return image }
  let factor = maxDimension / longest
  let width = max(1, Int(Double(image.width) * factor))
  let height = max(1, Int(Double(image.height) * factor))
  guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
  context.interpolationQuality = .high
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  return context.makeImage() ?? image
}

func runOCR(fileURL: URL, languages: [String], pointsWidth: Double, pointsHeight: Double,
            originX: Double, originY: Double, fast: Bool, maxDimension: Double) -> ([[String: Any]], String?) {
  guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    return ([], "cannot read image")
  }
  let scaled = resizedImage(image, maxDimension: maxDimension)
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = fast ? .fast : .accurate
  request.usesLanguageCorrection = true
  if !languages.isEmpty { request.recognitionLanguages = languages }
  let handler = VNImageRequestHandler(cgImage: scaled, options: [:])
  do { try handler.perform([request]) } catch {
    return ([], "vision failed: \(error.localizedDescription)")
  }
  let pixelWidth = Double(scaled.width)
  let pixelHeight = Double(scaled.height)
  let scaleX = pointsWidth > 0 ? pointsWidth / pixelWidth : 1
  let scaleY = pointsHeight > 0 ? pointsHeight / pixelHeight : 1
  var lines: [[String: Any]] = []
  for observation in request.results ?? [] {
    guard let candidate = observation.topCandidates(1).first else { continue }
    let box = observation.boundingBox
    let x = originX + Double(box.minX) * pixelWidth * scaleX
    let y = originY + (1 - Double(box.maxY)) * pixelHeight * scaleY
    let width = Double(box.width) * pixelWidth * scaleX
    let height = Double(box.height) * pixelHeight * scaleY
    lines.append([
      "text": candidate.string,
      "confidence": (Double(candidate.confidence) * 100).rounded() / 100,
      "x": (x * 10).rounded() / 10,
      "y": (y * 10).rounded() / 10,
      "width": (width * 10).rounded() / 10,
      "height": (height * 10).rounded() / 10,
      "centerX": ((x + width / 2) * 10).rounded() / 10,
      "centerY": ((y + height / 2) * 10).rounded() / 10,
    ])
  }
  // Reading order: top-to-bottom, then left-to-right.
  lines.sort { lhs, rhs in
    let ly = lhs["y"] as? Double ?? 0
    let ry = rhs["y"] as? Double ?? 0
    if abs(ly - ry) > 6 { return ly < ry }
    return (lhs["x"] as? Double ?? 0) < (rhs["x"] as? Double ?? 0)
  }
  return (lines, nil)
}

// MARK: - Commands

switch command {
case "permissions":
  emit(permissionState())

case "info":
  emit([
    "ok": true,
    "screens": screenList(),
    "cursor": ["x": cursorPoint().x, "y": cursorPoint().y],
    "frontmost": frontmost(),
    "permissions": permissionState(),
    "platform": "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
    "pythonFree": true,
  ])

case "cursor":
  let point = cursorPoint()
  emit(["ok": true, "x": point.x, "y": point.y])

case "windows":
  let option: CGWindowListOption = bool("all") ? .optionAll : [.optionOnScreenOnly, .excludeDesktopElements]
  let raw = (CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]]) ?? []
  var windows: [[String: Any]] = []
  for entry in raw {
    let layer = (entry[kCGWindowLayer as String] as? Int) ?? -1
    if layer != 0 { continue }
    let bounds = (entry[kCGWindowBounds as String] as? [String: Any]) ?? [:]
    let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
    let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
    if width < 40 || height < 40 { continue }
    let pid = (entry[kCGWindowOwnerPID as String] as? Int) ?? 0
    var appName = (entry[kCGWindowOwnerName as String] as? String) ?? ""
    if let running = NSRunningApplication(processIdentifier: pid_t(pid)), let name = running.localizedName, !name.isEmpty {
      appName = name
    }
    windows.append([
      "id": (entry[kCGWindowNumber as String] as? Int) ?? 0,
      "pid": pid,
      "app": appName,
      "title": (entry[kCGWindowName as String] as? String) ?? "",
      "x": (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
      "y": (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
      "width": width,
      "height": height,
    ])
  }
  emit(["ok": true, "windows": windows, "frontmost": frontmost()])

case "apps":
  // Running applications the caller can activate. `localizedName` is localized
  // (on a Chinese system TextEdit is 文本编辑), so the bundle id and the
  // executable name are the stable handles.
  var apps: [[String: Any]] = []
  for app in NSWorkspace.shared.runningApplications {
    if app.isTerminated || app.activationPolicy == .prohibited { continue }
    apps.append([
      "name": app.localizedName ?? "",
      "bundleId": app.bundleIdentifier ?? "",
      "exe": app.executableURL?.lastPathComponent ?? "",
      "pid": Int(app.processIdentifier),
      "active": app.isActive,
    ])
  }
  apps.sort { (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "") }
  emit(["ok": true, "apps": apps, "frontmost": frontmost()])

case "activate":
  let wanted = string("app").lowercased()
  let candidates = NSWorkspace.shared.runningApplications.filter {
    !$0.isTerminated && $0.activationPolicy != .prohibited
  }
  func fields(_ app: NSRunningApplication) -> [String] {
    [app.bundleIdentifier ?? "", app.localizedName ?? "", app.executableURL?.lastPathComponent ?? ""]
      .map { $0.lowercased() }
      .filter { !$0.isEmpty }
  }
  let match = candidates.first { fields($0).contains(wanted) }
    ?? candidates.first { app in fields(app).contains { $0.hasPrefix(wanted) } }
  guard let app = match else {
    let known = candidates.map { fields($0).first ?? "" }.filter { !$0.isEmpty }.sorted().prefix(40).joined(separator: ", ")
    fail("no running application matches \"\(wanted)\". running: \(known)")
  }
  if #available(macOS 14.0, *) {
    app.activate()
  } else {
    app.activate(options: [.activateAllWindows])
  }
  usleep(250_000)
  emit(["ok": true, "app": app.localizedName ?? "", "bundleId": app.bundleIdentifier ?? "", "frontmost": frontmost()])

case "move":
  let target = CGPoint(x: number("x"), y: number("y"))
  moveTo(target, durationMs: number("durationMs", 0))
  let point = cursorPoint()
  emit(["ok": true, "x": point.x, "y": point.y])

case "click":
  let point = CGPoint(x: number("x", cursorPoint().x), y: number("y", cursorPoint().y))
  let button = string("button", "left")
  let count = int("count", 1)
  click(at: point, button: button, count: count, pauseMs: number("pauseMs", 60))
  usleep(30_000)
  let now = cursorPoint()
  emit(["ok": true, "x": now.x, "y": now.y, "button": button, "count": count, "frontmost": frontmost()])

case "drag":
  let from = CGPoint(x: number("fromX"), y: number("fromY"))
  let to = CGPoint(x: number("toX"), y: number("toY"))
  drag(from: from, to: to, button: string("button", "left"), durationMs: number("durationMs", 400))
  let now = cursorPoint()
  emit(["ok": true, "x": now.x, "y": now.y, "frontmost": frontmost()])

case "scroll":
  let point = CGPoint(x: number("x", cursorPoint().x), y: number("y", cursorPoint().y))
  let dy = number("dy", 0)
  let dx = number("dx", 0)
  postMouse(.mouseMoved, at: point, button: .left)
  usleep(15_000)
  // wheel1 > 0 scrolls content up, so a caller's "dy > 0 = down" is negated.
  if let event = CGEvent(scrollWheelEvent2Source: eventSource(), units: .pixel,
                         wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) {
    event.post(tap: .cghidEventTap)
  }
  usleep(20_000)
  emit(["ok": true, "dy": dy, "dx": dx, "frontmost": frontmost()])

case "key":
  let name = string("key")
  guard let code = keyCodes[name.lowercased()] else { fail("unknown key name: \(name)") }
  let modifiers = stringList("modifiers")
  let held = modifiers.compactMap { modifierCodes[$0.lowercased()] }
  var flags: CGEventFlags = []
  for modifier in modifiers {
    for (label, modifierCode) in modifierCodes where label == modifier.lowercased() {
      postKey(modifierCode, down: true, flags: flags)
      flags.formUnion(modifierFlags([modifier]))
      break
    }
  }
  usleep(8_000)
  postKey(code, down: true, flags: flags)
  usleep(15_000)
  postKey(code, down: false, flags: flags)
  usleep(8_000)
  for modifierCode in held.reversed() { postKey(modifierCode, down: false, flags: []) }
  emit(["ok": true, "key": name, "modifiers": modifiers, "frontmost": frontmost()])

case "type":
  let text = string("text")
  postUnicode(text)
  emit(["ok": true, "length": text.count, "frontmost": frontmost()])

case "ax":do {
  let target = string("app", "")
  let running: NSRunningApplication?
  if target.isEmpty {
    guard let front = NSWorkspace.shared.frontmostApplication else { fail("no frontmost app") }
    running = front
  } else {
    running = resolveApp(target)
  }
  guard let app = running else { fail("app not running: \(target)") }
  let element = AXUIElementCreateApplication(app.processIdentifier)
  let nodes = axSnapshot(root: element,
                         maxDepth: int("maxDepth", 12),
                         maxNodes: int("maxNodes", 400),
                         interactiveOnly: bool("interactive", true))
  emit([
    "ok": true,
    "app": app.localizedName ?? target,
    "bundleId": app.bundleIdentifier ?? "",
    "pid": Int(app.processIdentifier),
    "nodes": nodes,
    "count": nodes.count,
  ])
}

case "axact":do {
  let target = string("app", "")
  let running: NSRunningApplication?
  if target.isEmpty {
    guard let front = NSWorkspace.shared.frontmostApplication else { fail("no frontmost app") }
    running = front
  } else {
    running = resolveApp(target)
  }
  guard let app = running else { fail("app not running: \(target)") }
  let root = AXUIElementCreateApplication(app.processIdentifier)
  let path: [Int]
  if let raw = input["path"] as? [Int] { path = raw }
  else if let raw = input["path"] as? [Any] { path = raw.compactMap { ($0 as? NSNumber)?.intValue } }
  else { fail("missing path") }
  var resolved = axElement(at: path, root: root)
  var resolution = "path"
  if let fingerprint = input["fingerprint"] as? [String: Any] {
    if resolved == nil || !axMatches(resolved!, fingerprint: fingerprint) {
      resolved = axSearch(root: root, fingerprint: fingerprint, maxNodes: 4000)
      resolution = resolved == nil ? "not-found" : "fingerprint"
    }
  }
  guard let element = resolved else { fail("element not found (path drifted and no fingerprint match)") }
  let action = string("action", "press")
  var result = "ok"
  switch action {
  case "press":
    if axActions(element).contains(kAXPressAction as String) {
      let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
      if status != .success { result = "press-failed:\(status.rawValue)" }
    } else {
      AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      result = "no-press-action-focused"
    }
  case "focus":
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
  case "set_value":
    let text = string("value", "")
    let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
    if status != .success { result = "set-value-failed:\(status.rawValue)" }
  case "raise":
    let status = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    if status != .success { result = "raise-failed:\(status.rawValue)" }
  default:
    fail("unknown action: \(action)")
  }
  emit(["ok": true, "action": action, "result": result, "app": app.localizedName ?? target,
        "path": path, "resolution": resolution, "actions": axActions(element)])
}

case "ocr":do {
  let file = string("file")
  let url = URL(fileURLWithPath: file)
  let (lines, error) = runOCR(fileURL: url,
                              languages: stringList("languages"),
                              pointsWidth: number("pointsWidth", 0),
                              pointsHeight: number("pointsHeight", 0),
                              originX: number("originX", 0),
                              originY: number("originY", 0),
                              fast: bool("fast", true),
                              maxDimension: number("maxDimension", 2000))
  if let error { fail(error) }
  emit(["ok": true, "lines": lines, "count": lines.count])
}

default:
  fail("unknown command: \(command)")
}
