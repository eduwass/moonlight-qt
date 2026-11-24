// sofa-hub's receiver on the Mac. Dials the hub on omarchypc over Tailscale, tells it when this
// Mac's Sunshine is streaming, and replays the keys and trackpad input it gets as real Mac input.
// Needs Accessibility permission. Build: swiftc -O mac-receiver.swift -o ~/.local/bin/sofa-receiver
import AppKit
import Foundation
import Network

let hubHost = ProcessInfo.processInfo.environment["SOFA_HUB_HOST"] ?? "omarchypc"
let hubPort = NWEndpoint.Port(rawValue: UInt16(ProcessInfo.processInfo.environment["SOFA_HUB_PORT"] ?? "47901")!)!
let sunshineLog = NSHomeDirectory() + "/.config/sunshine/sunshine.log"
let source = CGEventSource(stateID: .hidSystemState)

// MARK: - Keys

// Linux key codes (by position) to Mac virtual key codes.
let macKey: [Int: CGKeyCode] = [
  1: 53, 2: 18, 3: 19, 4: 20, 5: 21, 6: 23, 7: 22, 8: 26, 9: 28, 10: 25, 11: 29, 12: 27, 13: 24, 14: 51,
  15: 48, 16: 12, 17: 13, 18: 14, 19: 15, 20: 17, 21: 16, 22: 32, 23: 34, 24: 31, 25: 35, 26: 33, 27: 30,
  28: 36, 29: 59, 30: 0, 31: 1, 32: 2, 33: 3, 34: 5, 35: 4, 36: 38, 37: 40, 38: 37, 39: 41, 40: 39,
  41: 50, 42: 56, 43: 42, 44: 6, 45: 7, 46: 8, 47: 9, 48: 11, 49: 45, 50: 46, 51: 43, 52: 47, 53: 44,
  54: 60, 56: 58, 57: 49, 58: 57, 59: 122, 60: 120, 61: 99, 62: 118, 63: 96, 64: 97, 65: 98, 66: 100,
  67: 101, 68: 109, 86: 10, 87: 103, 88: 111, 96: 76, 97: 62, 100: 61, 102: 115, 103: 126, 104: 116,
  105: 123, 106: 124, 107: 119, 108: 125, 109: 121, 111: 117, 120: 160, 125: 55, 126: 54,
]
let modifierFlag: [Int: CGEventFlags] = [
  29: .maskControl, 97: .maskControl, 42: .maskShift, 54: .maskShift,
  56: .maskAlternate, 100: .maskAlternate, 125: .maskCommand, 126: .maskCommand, 58: .maskAlphaShift,
]
// Media keys are "system defined" events on a Mac (NX_KEYTYPE_*).
let mediaKey: [Int: Int32] = [113: 7, 114: 1, 115: 0, 163: 17, 164: 16, 165: 18]

var flags: CGEventFlags = []
// Right cmd + 1-5 moves the window to that workspace, as Karabiner makes it do on a Mac's own keyboard;
// Karabiner never sees these synthetic keys, so dinky is asked straight.
var rightCmd = false
let workspaceDigits: Set<Int> = [2, 3, 4, 5, 6] // evdev KEY_1 to KEY_5
var repeatTimer: Timer?
let defaults = UserDefaults.standard
// The user's own key repeat (units of 15 ms), as macOS would apply to a real keyboard.
let initialRepeat = max(Double(defaults.integer(forKey: "InitialKeyRepeat")), 10) * 0.015
let repeatEvery = max(Double(defaults.integer(forKey: "KeyRepeat")), 1) * 0.015

func key(_ code: Int, _ down: Bool) {
  if let media = mediaKey[code] {
    let data1 = Int((media << 16) | ((down ? 0xA : 0xB) << 8))
    NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                       timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
    return
  }
  guard let mac = macKey[code] else { return }
  if let flag = modifierFlag[code] {
    if down { flags.insert(flag) } else { flags.remove(flag) }
    if code == 126 { rightCmd = down }
    let e = CGEvent(keyboardEventSource: source, virtualKey: mac, keyDown: down)
    e?.type = .flagsChanged
    e?.flags = flags
    e?.post(tap: .cghidEventTap)
    return
  }
  if rightCmd && workspaceDigits.contains(code) {
    if down {
      print("right cmd + \(code - 1): window to workspace \(code - 1)")
      dinky(["move-window-to-workspace", "\(code - 1)", "--follow"])
    }
    return
  }
  post(mac, down, repeating: false)
  repeatTimer?.invalidate()
  repeatTimer = nil
  // Synthetic key presses do not repeat on their own, so repeat held keys at the user's speed.
  if down {
    repeatTimer = Timer.scheduledTimer(withTimeInterval: initialRepeat, repeats: false) { _ in
      repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatEvery, repeats: true) { _ in post(mac, true, repeating: true) }
    }
  }
}

func post(_ mac: CGKeyCode, _ down: Bool, repeating: Bool) {
  let e = CGEvent(keyboardEventSource: source, virtualKey: mac, keyDown: down)
  e?.flags = flags
  if repeating { e?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
  e?.post(tap: .cghidEventTap)
}

// MARK: - Pointer

var leftDown = false
var rightDown = false
var lastClick = (at: Date.distantPast, point: CGPoint.zero, count: 0)

func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func clamp(_ p: CGPoint) -> CGPoint {
  var count: UInt32 = 0
  CGGetActiveDisplayList(0, nil, &count)
  var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
  CGGetActiveDisplayList(count, &ids, &count)
  let bounds = ids.map { CGDisplayBounds($0) }
  if bounds.contains(where: { $0.contains(p) }) { return p }
  // Off every screen: pull back onto the nearest one.
  let nearest = bounds.min { a, b in hypot(a.midX - p.x, a.midY - p.y) < hypot(b.midX - p.x, b.midY - p.y) } ?? .zero
  return CGPoint(x: min(max(p.x, nearest.minX), nearest.maxX - 1), y: min(max(p.y, nearest.minY), nearest.maxY - 1))
}

// Moves arrive in clumps over Wi-Fi, which makes the cursor jump. They are collected and let out
// at 120 Hz, a share of what is pending each tick, so the cursor glides; it adds about 10 ms.
var pending = (x: 0.0, y: 0.0)
let smoothing = Double(ProcessInfo.processInfo.environment["SOFA_SMOOTHING"] ?? "0.6")!
Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
  if pending.x == 0 && pending.y == 0 { return }
  let small = abs(pending.x) < 1 && abs(pending.y) < 1
  let step = small ? pending : (x: pending.x * smoothing, y: pending.y * smoothing)
  pending = small ? (0, 0) : (pending.x - step.x, pending.y - step.y)
  move(step.x, step.y)
}

func queueMove(_ dx: Double, _ dy: Double) { pending.x += dx; pending.y += dy }

/// A click lands where the cursor is shown, so pending movement is applied first.
func flushMoves() {
  if pending.x != 0 || pending.y != 0 { move(pending.x, pending.y) }
  pending = (0, 0)
}

func move(_ dx: Double, _ dy: Double) {
  let to = clamp(CGPoint(x: cursor().x + dx, y: cursor().y + dy))
  let type: CGEventType = leftDown ? .leftMouseDragged : rightDown ? .rightMouseDragged : .mouseMoved
  let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to, mouseButton: rightDown ? .right : .left)
  e?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
  e?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
  e?.flags = flags
  e?.post(tap: .cghidEventTap)
}

func button(_ which: String, _ down: Bool) {
  let right = which == "right"
  let at = cursor()
  if down {
    // Double and triple clicks: close in time and place to the last click.
    let near = Date().timeIntervalSince(lastClick.at) < NSEvent.doubleClickInterval && hypot(at.x - lastClick.point.x, at.y - lastClick.point.y) < 5
    lastClick = (Date(), at, near ? lastClick.count + 1 : 1)
  }
  if right { rightDown = down } else { leftDown = down }
  let type: CGEventType = right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .leftMouseDown : .leftMouseUp)
  let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: right ? .right : .left)
  e?.setIntegerValueField(.mouseEventClickState, value: Int64(lastClick.count))
  e?.flags = flags
  e?.post(tap: .cghidEventTap)
}

func scroll(_ dx: Double, _ dy: Double, phase: Int64, momentum: Int64) {
  let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                  wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)
  e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
  e?.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
  e?.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
  e?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
  e?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
  e?.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
  e?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
  e?.flags = flags
  e?.post(tap: .cghidEventTap)
}

// MARK: - Trackpad gestures
// Real gesture events, built from the undocumented CGEvent fields Mac Mouse Fix uses (TouchSimulator.m,
// macOS 15 path): field 55 = event type, 110 = IOHID event subtype, 132 = IOHIDEventPhaseBits.

func gestureEvent(type: Int64, subtype: Int64) -> CGEvent? {
  let e = CGEvent(source: nil)
  e?.setIntegerValueField(CGEventField(rawValue: 55)!, value: type)
  e?.setIntegerValueField(CGEventField(rawValue: 110)!, value: subtype)
  return e
}

/// Pinch: magnification is the relative change this step (0.1 = 10% bigger).
func magnify(_ amount: Double, phase: Int64) {
  let e = gestureEvent(type: 29, subtype: 8) // NSEventTypeGesture, kIOHIDEventTypeZoom
  e?.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
  e?.setDoubleValueField(CGEventField(rawValue: 113)!, value: amount)
  e?.post(tap: .cghidEventTap)
}

func smartZoom() { gestureEvent(type: 29, subtype: 22)?.post(tap: .cghidEventTap) } // kIOHIDEventTypeZoomToggle

func dinky(_ args: [String]) {
  try? Process.run(URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/dinky"), arguments: args)
}

// The menu bar hides the way System Settings > Control Center > "Automatically hide and show the menu
// bar" does: the setting, then the notice every app and the Dock act on.
func menuBar(hidden: Bool) {
  print("menu bar \(hidden ? "hidden" : "shown")")
  CFPreferencesSetValue("_HIHideMenuBar" as CFString, hidden as CFBoolean, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
  CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
  DistributedNotificationCenter.default().postNotificationName(.init("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
  // dinky does not notice the screen growing or shrinking by the menu bar, so it lays the windows out again.
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    dinky(["retile"])
  }
}

/// Three/four-finger swipe: Spaces (horizontal) or Mission Control / App Exposé (vertical).
/// delta is in "spaces": 1.0 is one full Space; the Dock animates along as it would under real fingers.
var dockOrigin = 0.0
var dockLast = 0.0
func dockSwipe(_ delta: Double, vertical: Bool, phase inPhase: Int64) {
  var phase = inPhase
  if phase == 1 { dockOrigin = delta } else if phase == 2 { if delta == 0 { return }; dockOrigin += delta }
  // Ending against the direction travelled cancels, so the Space springs back like with real fingers.
  if phase == 4 && (dockLast < 0) != (dockOrigin < 0) { phase = 8 }
  let e30 = CGEvent(source: nil)!
  let field = { (n: UInt32, v: Double) in e30.setDoubleValueField(CGEventField(rawValue: n)!, value: v) }
  field(55, 30)
  field(110, 23) // kIOHIDEventTypeDockSwipe
  field(132, Double(phase))
  field(134, Double(phase))
  field(124, dockOrigin)
  var f = Float32(dockOrigin)
  var bits: UInt32 = 0
  memcpy(&bits, &f, 4)
  e30.setIntegerValueField(CGEventField(rawValue: 135)!, value: Int64(bits))
  field(41, 33231)
  let kind: Double = vertical ? 2 : 1
  let encodedKind = vertical ? 2.802596928649634e-45 : 1.401298464324817e-45
  field(119, encodedKind)
  field(139, encodedKind)
  field(123, kind)
  field(165, kind)
  e30.setIntegerValueField(CGEventField(rawValue: 136)!, value: 1) // natural direction, like the trackpad
  if phase == 4 || phase == 8 {
    field(129, dockLast * 100) // exit speed
    field(130, dockLast * 100)
  }
  let e29 = CGEvent(source: nil)!
  e29.setDoubleValueField(CGEventField(rawValue: 55)!, value: 29)
  e29.setDoubleValueField(CGEventField(rawValue: 41)!, value: 33231)
  e30.post(tap: .cghidEventTap)
  e29.post(tap: .cghidEventTap)
  // The Dock drops end events under load, so the end is sent again, as Mac Mouse Fix does.
  if phase == 4 || phase == 8 {
    for delay in [0.2, 0.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { e30.post(tap: .cghidEventTap); e29.post(tap: .cghidEventTap) } }
  }
  if delta != 0 { dockLast = delta }
}

/// Any CGEvent from its raw fields, so new gestures can be tried without rebuilding this program.
func raw(_ m: [String: Any]) {
  guard let e = CGEvent(source: nil) else { return }
  for (k, v) in (m["ints"] as? [String: Int64]) ?? [:] { if let n = UInt32(k) { e.setIntegerValueField(CGEventField(rawValue: n)!, value: v) } }
  for (k, v) in (m["doubles"] as? [String: Double]) ?? [:] { if let n = UInt32(k) { e.setDoubleValueField(CGEventField(rawValue: n)!, value: v) } }
  e.post(tap: .cghidEventTap)
}

func resetAll() {
  repeatTimer?.invalidate()
  repeatTimer = nil
  if leftDown { button("left", false) }
  if rightDown { button("right", false) }
  if !flags.isEmpty {
    flags = []
    let e = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false)
    e?.type = .flagsChanged
    e?.flags = []
    e?.post(tap: .cghidEventTap)
  }
}

func handle(_ line: Substring) {
  guard let data = line.data(using: .utf8),
        let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = m["t"] as? String else { return }
  let d = { (k: String) in (m[k] as? Double) ?? 0 }
  switch t {
  case "key": key(m["code"] as? Int ?? 0, m["down"] as? Bool ?? false)
  case "move": queueMove(d("dx"), d("dy"))
  case "button": flushMoves(); button(m["b"] as? String ?? "left", m["down"] as? Bool ?? false)
  case "scroll": scroll(d("dx"), d("dy"), phase: Int64(d("phase")), momentum: Int64(d("momentum")))
  case "magnify": magnify(d("m"), phase: Int64(d("phase")))
  case "smartzoom": smartZoom()
  case "menubar": menuBar(hidden: m["hide"] as? Bool ?? false)
  case "dock": dockSwipe(d("d"), vertical: (m["axis"] as? String) == "v", phase: Int64(d("phase")))
  case "raw": raw(m)
  case "reset": resetAll()
  default: break
  }
}

// MARK: - Sunshine: is this Mac being streamed?

var streaming = false
var logOffset: UInt64 = 0

func streamState(_ text: Substring) -> Bool? {
  for line in text.split(separator: "\n").reversed() {
    // macOS can stop the screen capture under a stream (low disk, display changes) and Sunshine then
    // never logs the disconnect; the client is gone all the same.
    if line.contains("CLIENT DISCONNECTED") || line.contains("ScreenCaptureKit: stopped") { return false }
    if line.contains("CLIENT CONNECTED") { return true }
  }
  return nil
}

func readLog() -> Bool? {
  guard let handle = FileHandle(forReadingAtPath: sunshineLog) else { return nil }
  defer { try? handle.close() }
  let size = (try? handle.seekToEnd()) ?? 0
  if size < logOffset { logOffset = 0 } // the log was rotated
  try? handle.seek(toOffset: logOffset)
  let data = handle.readDataToEndOfFile()
  logOffset = size
  return streamState(Substring(String(decoding: data, as: UTF8.self)))
}

// MARK: - The hub connection

var connection: NWConnection?

func say(_ text: String) { connection?.send(content: (text + "\n").data(using: .utf8), completion: .contentProcessed { _ in }) }

func connect() {
  let tcp = NWProtocolTCP.Options()
  tcp.noDelay = true
  let c = NWConnection(host: NWEndpoint.Host(hubHost), port: hubPort, using: NWParameters(tls: nil, tcp: tcp))
  connection = c
  var buffer = ""
  func receive() {
    c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
      if let data { buffer += String(decoding: data, as: UTF8.self) }
      while let nl = buffer.firstIndex(of: "\n") {
        let line = buffer[..<nl]
        DispatchQueue.main.async { [line] in handle(line) }
        buffer = String(buffer[buffer.index(after: nl)...])
      }
      if done || error != nil { c.cancel() } else { receive() }
    }
  }
  c.stateUpdateHandler = { state in
    switch state {
    case .ready:
      print("connected to \(hubHost)")
      say(streaming ? "streaming" : "idle")
      receive()
    case .failed, .cancelled:
      DispatchQueue.main.async {
        resetAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if connection === c { connect() } }
      }
    default: break
    }
  }
  c.start(queue: .global(qos: .userInteractive))
}

if !AXIsProcessTrusted() {
  print("sofa-receiver: no Accessibility permission yet; input will be ignored until it is granted")
}
setvbuf(stdout, nil, _IOLBF, 0) // the log is a file: a line at a time, not when a buffer fills
streaming = readLog() ?? false
print("sofa-receiver: Sunshine \(streaming ? "streaming" : "idle"), dialing \(hubHost):\(hubPort)")
connect()
Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
  // Every new connection is said, not only changes: Sunshine does not always log the end of a
  // stream that dropped, and the hub decides afresh on each one whether the sofa is watching.
  if let now = readLog(), now || now != streaming {
    streaming = now
    print("Sunshine \(now ? "streaming" : "idle")")
    say(now ? "streaming" : "idle")
  }
}
RunLoop.main.run()
