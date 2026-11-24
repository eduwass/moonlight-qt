// sofa-hub's receiver on the Mac. Dials the hub on omarchypc over Tailscale, tells it when this
// Mac's Sunshine is streaming, and replays the keys and trackpad input it gets as real Mac input.
// Every 5 s it also sends this Mac's stats for the Sofa app's list of computers; asked, a preview of the
// screen (needs Screen Recording), a test tone, or it restarts the Mac (fdesetup authrestart, setup-mac-restart.sh).
// Needs Accessibility permission. Build: swiftc -O mac-receiver.swift -o ~/.local/bin/sofa-receiver
import AppKit
import CoreWLAN
import Foundation
import ImageIO
import Network
import SystemConfiguration

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

// MARK: - Instant cursor
// The Apple TV draws the cursor itself as the hub's moves arrive, and corrects it from these: where the
// cursor will be once everything up to move `lastSeq` is applied (pending smoothing included), in points
// from the main display's top left, with its size. Sent at most 60 times a second, only when it changes and
// only while streamed; it changes by itself too (Mission Control, warps), which this also catches.
var lastSeq = 0
var lastCursorReport = ""
Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
  guard streaming else { return }
  let c = cursor()
  let at = clamp(CGPoint(x: c.x + pending.x, y: c.y + pending.y))
  let b = CGDisplayBounds(CGMainDisplayID())
  let report = String(format: "cursor %d %.1f %.1f %d %d", lastSeq, at.x - b.minX, at.y - b.minY, Int(b.width), Int(b.height))
  if report != lastCursorReport { lastCursorReport = report; say(report) }
}

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

// Four fingers up hides the menu bar, and once it is hidden opens Mission Control; down closes Mission
// Control if it is open, else shows the bar. Opening it again is what closes it.
func missionControlOpen() -> Bool {
  // Mission Control puts screen-sized Dock windows above the normal layers (18 and 20); closed, the Dock
  // shows only its wallpaper, far below.
  let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  return windows.contains { ($0["kCGWindowOwnerName"] as? String) == "Dock" && ($0["kCGWindowLayer"] as? Int ?? 0) > 0 }
}

func fourFingers(up: Bool) {
  if missionControlOpen() {
    if up { return } // already open: another up would close it
    print("mission control closed")
    try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Mission Control"])
    return
  }
  let hidden = CFPreferencesCopyAppValue("_HIHideMenuBar" as CFString, kCFPreferencesAnyApplication) as? Bool ?? false
  if up && hidden {
    print("mission control")
    try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Mission Control"])
    return
  }
  menuBar(hidden: up)
}

// The menu bar hides the way System Settings > Control Center > "Automatically hide and show the menu
// bar" does: WindowServer's flag (which dinky reads), the setting, then the notice every app acts on;
// without the last two, apps keep their windows below where the bar was.
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
func menuBar(hidden: Bool) {
  print("menu bar \(hidden ? "hidden" : "shown")")
  typealias Connection = @convention(c) () -> Int32
  typealias SetAutohide = @convention(c) (Int32, Bool) -> Int32
  if let conn = dlsym(skyLight, "SLSMainConnectionID"), let set = dlsym(skyLight, "SLSSetMenuBarAutohideEnabled") {
    _ = unsafeBitCast(set, to: SetAutohide.self)(unsafeBitCast(conn, to: Connection.self)(), hidden)
  }
  CFPreferencesSetValue("_HIHideMenuBar" as CFString, hidden as CFBoolean, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
  CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
  DistributedNotificationCenter.default().postNotificationName(.init("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
  // Once the apps have caught up, dinky lays the windows out again over the new area.
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
  case "move": queueMove(d("dx"), d("dy")); if let seq = m["seq"] as? Int { lastSeq = seq }
  case "button": flushMoves(); button(m["b"] as? String ?? "left", m["down"] as? Bool ?? false)
  case "scroll": scroll(d("dx"), d("dy"), phase: Int64(d("phase")), momentum: Int64(d("momentum")))
  case "magnify": magnify(d("m"), phase: Int64(d("phase")))
  case "smartzoom": smartZoom()
  case "menubar": fourFingers(up: m["hide"] as? Bool ?? false)
  case "dock": dockSwipe(d("d"), vertical: (m["axis"] as? String) == "v", phase: Int64(d("phase")))
  case "raw": raw(m)
  case "reset": resetAll()
  case "preview": statsQueue.async { preview() }
  case "restart": DispatchQueue.global().async { restart() }
  case "ping": say("pong \(m["id"] as? Int ?? 0)") // the hub times the input path with these
  case "tone": tone(seconds: min(max(d("seconds"), 1), 30))
  case "speed": speedTest(to: m["addr"] as? String ?? "", port: Int(d("port")), seconds: min(max(d("seconds"), 1), 10))
  case "instantCursor": pictureCursor(client: m["client"] as? String ?? "", inPicture: !(m["on"] as? Bool ?? true))
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

// MARK: - Stats for the Sofa app's list of computers (the same shape as the hub's Host, stats.ts)

let statsQueue = DispatchQueue(label: "stats")
var lastTicks = cpuTicks()

/// Busy and total CPU ticks since boot, all cores.
func cpuTicks() -> (busy: UInt64, total: UInt64) {
  var info = host_cpu_load_info()
  var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
  let ok = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
  } == KERN_SUCCESS
  guard ok else { return (0, 0) }
  let (user, system, idle, nice) = (UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3))
  return (user + system + nice, user + system + idle + nice)
}

/// Used memory as Activity Monitor counts it: active, wired and compressed pages.
func memoryUsed() -> UInt64 {
  var vm = vm_statistics64()
  var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
  let ok = withUnsafeMutablePointer(to: &vm) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
  } == KERN_SUCCESS
  return ok ? (UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * UInt64(vm_kernel_page_size) : 0
}

func swapUsage() -> (used: UInt64, total: UInt64) {
  var usage = xsw_usage()
  var size = MemoryLayout<xsw_usage>.size
  return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? (usage.xsu_used, usage.xsu_total) : (0, 0)
}

func uptime() -> Int {
  var boot = timeval()
  var size = MemoryLayout<timeval>.size
  return sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 ? Int(Date().timeIntervalSince1970) - boot.tv_sec : 0
}

/// The LAN and Tailscale IPv4 addresses.
func ipv4Addresses() -> [String] {
  var out: [String] = []
  var first: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&first) == 0 else { return [] }
  defer { freeifaddrs(first) }
  var next = first
  while let i = next {
    next = i.pointee.ifa_next
    let flags = Int32(i.pointee.ifa_flags)
    guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
    let address = String(cString: host)
    if !address.hasPrefix("169.254.") && !out.contains(address) { out.append(address) }
  }
  return out
}

/// The title of an app's front window, through Accessibility; a hung app gets a quarter of a second.
func frontWindowTitle(_ pid: pid_t) -> String? {
  let app = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app, 0.25)
  var window: CFTypeRef?
  guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success
    || AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &window) == .success,
    let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
  var title: CFTypeRef?
  guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
    let text = title as? String, !text.isEmpty else { return nil }
  // "<tab> - Helium", or "<tab> - Helium - <profile>"
  return text.range(of: " - Helium", options: .backwards).map { String(text[..<$0.lowerBound]) } ?? text
}

/// The apps with a window on screen, the frontmost first, then front to back; Helium with its tab.
func screenApps(max: Int = 5) -> [String] {
  var pids: [pid_t] = []
  if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier { pids.append(front) }
  let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
  for w in windows where (w[kCGWindowLayer as String] as? Int) == 0 {
    if let pid = w[kCGWindowOwnerPID as String] as? Int { pids.append(pid_t(pid)) }
  }
  var seen = Set<pid_t>()
  var out: [String] = []
  for pid in pids where !seen.contains(pid) && out.count < max {
    seen.insert(pid)
    guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular, !app.isHidden,
      let name = app.localizedName else { continue }
    out.append(name == "Helium" ? frontWindowTitle(pid).map { "Helium — \($0)" } ?? name : name)
  }
  return out
}

func stats() -> [String: Any] {
  let ticks = cpuTicks()
  let busy = ticks.total > lastTicks.total ? Double(ticks.busy - lastTicks.busy) / Double(ticks.total - lastTicks.total) : 0
  lastTicks = ticks
  let disk = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
  let diskTotal = Int64(disk?.volumeTotalCapacity ?? 0)
  var name = [CChar](repeating: 0, count: 256)
  gethostname(&name, name.count)
  let swap = swapUsage()
  return [
    "name": SCDynamicStoreCopyLocalHostName(nil) as String? ?? "Mac",
    "hostname": String(cString: name),
    "addresses": ipv4Addresses(),
    "cpu": NSDecimalNumber(string: String(format: "%.1f", busy * 100)), // one decimal in the JSON too
    "memUsed": memoryUsed(),
    "memTotal": ProcessInfo.processInfo.physicalMemory,
    "swapUsed": swap.used,
    "swapTotal": swap.total,
    "diskUsed": diskTotal - (disk?.volumeAvailableCapacityForImportantUsage ?? 0),
    "diskTotal": diskTotal,
    "uptime": uptime(),
    "apps": screenApps(),
    "os": "macos",
    "pressure": memoryPressure(),
    "display": displayFacts(),
    "link": linkFacts() ?? NSNull(),
  ]
}

/// How this Mac reaches the network: the primary interface, Wi-Fi with band, signal and rate, or a cable with
/// its speed. Nil when there is no route.
func linkFacts() -> [String: Any]? {
  guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
        let name = global["PrimaryInterface"] as? String else { return nil }
  if let wifi = CWWiFiClient.shared().interface(withName: name), wifi.powerOn() {
    var link: [String: Any] = ["kind": "wifi", "rssi": wifi.rssiValue(), "rateMbps": Int(wifi.transmitRate())]
    switch wifi.wlanChannel()?.channelBand {
    case .band2GHz?: link["band"] = "2.4 GHz"
    case .band5GHz?: link["band"] = "5 GHz"
    case .band6GHz?: link["band"] = "6 GHz"
    default: break
    }
    return link
  }
  // "media: autoselect (1000baseT <full-duplex>)"
  let media = run("/sbin/ifconfig", [name]) ?? ""
  let rate = media.range(of: #"\((\d+)base"#, options: .regularExpression).map { Int(media[$0].dropFirst().prefix { $0.isNumber }) ?? 0 } ?? 0
  return ["kind": "ethernet", "rateMbps": rate]
}

// MARK: - Speed test: the Apple TV listens, this Mac sends it bytes for a few seconds, so the measure is
// this Mac's own path to the TV (its Wi-Fi included) and the firewall here is not in the way.

let speedQueue = DispatchQueue(label: "speed")

func speedTest(to address: String, port: Int, seconds: Double) {
  guard address.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil, (1...65535).contains(port),
        let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return say("speed-failed bad address") }
  let conn = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: .tcp)
  let chunk = Data(count: 256 * 1024)
  var sent = 0
  var done = false
  let finish = { (word: String) in
    guard !done else { return }
    done = true
    conn.cancel()
    say(word)
  }
  var end = Date()
  func pump() {
    if Date() >= end { return finish("speed-done \(sent)") }
    conn.send(content: chunk, completion: .contentProcessed { error in
      if let error { return finish("speed-failed \(error)") }
      sent += chunk.count
      pump()
    })
  }
  conn.stateUpdateHandler = { state in
    switch state {
    case .ready: end = Date().addingTimeInterval(seconds); pump()
    case .failed(let error): finish("speed-failed \(error)")
    default: break
    }
  }
  conn.start(queue: speedQueue)
  speedQueue.asyncAfter(deadline: .now() + seconds + 5) { finish("speed-failed timed out") }
}

// MARK: - Instant cursor on or off: Sunshine's prep command (sunshine-display.sh) leaves the cursor in the
// picture for the clients listed in picture-cursor-clients and sends the others its shapes instead.

func pictureCursor(client: String, inPicture: Bool) {
  guard client.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil else { return }
  let path = NSHomeDirectory() + "/.config/sunshine/picture-cursor-clients"
  let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty && $0 != client }
  let next = (inPicture ? lines + [client] : lines).map { $0 + "\n" }.joined()
  try? next.write(toFile: path, atomically: true, encoding: .utf8)
}

/// The main display's pixels, the scale it is drawn at and the size it looks (points), for the Sofa app.
func displayFacts() -> [String: Any] {
  guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0 else { return [:] }
  let scale = (Double(mode.pixelWidth) / Double(mode.width) * 100).rounded() / 100
  return ["pixels": [mode.pixelWidth, mode.pixelHeight], "scale": scale, "looks": [mode.width, mode.height]]
}

/// The kernel's memory pressure, as Activity Monitor's graph colours it: 1 normal, 2 warn, 4 critical.
func memoryPressure() -> String {
  var level: Int32 = 0
  var size = MemoryLayout<Int32>.size
  guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return "normal" }
  return level >= 4 ? "critical" : level >= 2 ? "warn" : "normal"
}

// MARK: - Preview of the screen, for the Sofa app's list of computers

/// The main display as a JPEG about 640 px wide, base64, under 150 KB; or why there is none.
func preview() {
  guard CGPreflightScreenCaptureAccess() else {
    _ = CGRequestScreenCaptureAccess() // puts the receiver in System Settings' Screen Recording list, to turn on
    say("preview-failed no-permission")
    return
  }
  let path = NSTemporaryDirectory() + "sofa-preview.jpg"
  defer { try? FileManager.default.removeItem(atPath: path) }
  guard run("/usr/sbin/screencapture", ["-x", "-m", "-t", "jpg", path]) != nil,
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640,
    ] as CFDictionary)
  else { return say("preview-failed capture") }
  // Without the permission, or with the display asleep, the picture comes back black.
  if isBlack(image) { return say("preview-failed no-permission") }
  for quality in [0.7, 0.5, 0.35] {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { break }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { break }
    let base64 = (data as Data).base64EncodedString()
    if base64.count <= 150_000 { return say("preview " + base64) }
  }
  say("preview-failed too-big")
}

func isBlack(_ image: CGImage) -> Bool {
  var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
  let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let ctx = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
    return true
  }
  return drawn && pixels.enumerated().allSatisfy { $0.offset % 4 == 3 || $0.element < 8 }
}

/// A program's output, or nil when it could not run or failed.
func run(_ path: String, _ args: [String], input: Data? = nil) -> String? {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: path)
  p.arguments = args
  let out = Pipe()
  let inPipe = Pipe()
  p.standardOutput = out
  p.standardError = FileHandle.nullDevice
  if input != nil { p.standardInput = inPipe }
  guard (try? p.run()) != nil else { return nil }
  if let input {
    inPipe.fileHandleForWriting.write(input)
    try? inPipe.fileHandleForWriting.close()
  }
  let data = out.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}

// MARK: - Test tone, asked from the Sofa app

var tonePlayer: Process?

/// A steady 440 Hz sine at -12 dBFS with 10 ms fades, 16-bit stereo, played with afplay on the default output.
func tone(seconds: Double) {
  let rate = 48_000, frames = Int(seconds * Double(rate)), fade = rate / 100
  let amp = 32767 * pow(10, -12.0 / 20)
  var data = Data()
  func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
  func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
  data.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames * 4)
  data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
  data.append(contentsOf: Array("data".utf8)); u32(frames * 4)
  var samples = [Int16](repeating: 0, count: frames * 2)
  for i in 0..<frames {
    let gain = min(1, Double(i) / Double(fade), Double(frames - 1 - i) / Double(fade))
    let s = Int16((amp * gain * sin(2 * Double.pi * 440 * Double(i) / Double(rate))).rounded())
    samples[2 * i] = s.littleEndian
    samples[2 * i + 1] = s.littleEndian
  }
  samples.withUnsafeBytes { data.append(contentsOf: $0) }
  let path = NSTemporaryDirectory() + "sofa-tone.wav"
  guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return say("tone-failed write") }
  tonePlayer?.terminate()
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
  p.arguments = [path]
  guard (try? p.run()) != nil else { return say("tone-failed afplay") }
  tonePlayer = p
  // Still running after a moment: playing.
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    say(p.isRunning || p.terminationStatus == 0 ? "tone-ok" : "tone-failed afplay exit \(p.terminationStatus)")
  }
}

// MARK: - Restart, asked from the Sofa app

/// Restarts through FileVault so the Mac comes back logged in: the login password is in the keychain
/// item "sofa-receiver-login", and sudo lets this user run `fdesetup authrestart -inputplist` (both
/// from setup-mac-restart.sh). The password never reaches the log.
func restart() {
  let user = NSUserName()
  guard var password = run("/usr/bin/security", ["find-generic-password", "-s", "sofa-receiver-login", "-a", user, "-w"]) else {
    return say("restart-failed no keychain item sofa-receiver-login; run setup-mac-restart.sh")
  }
  if password.hasSuffix("\n") { password.removeLast() }
  let command = ["/usr/bin/fdesetup", "authrestart", "-inputplist"]
  guard !password.isEmpty, run("/usr/bin/sudo", ["-n", "-l"] + command) != nil else {
    return say("restart-failed no sudo rule for fdesetup authrestart; run setup-mac-restart.sh")
  }
  guard let plist = try? PropertyListSerialization.data(fromPropertyList: ["Username": user, "Password": password], format: .xml, options: 0) else {
    return say("restart-failed plist")
  }
  print("restart: fdesetup authrestart, asked by the Sofa app")
  say("restarting")
  Thread.sleep(forTimeInterval: 0.3) // let the answer reach the hub
  if run("/usr/bin/sudo", ["-n"] + command, input: plist) == nil {
    print("restart: fdesetup authrestart failed")
    say("restart-failed fdesetup authrestart failed (is FileVault on?)")
  }
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
// Off the main thread, so a slow Accessibility answer never holds up input.
let statsTimer = DispatchSource.makeTimerSource(queue: statsQueue)
statsTimer.schedule(deadline: .now() + 5, repeating: 5)
statsTimer.setEventHandler {
  guard let json = try? JSONSerialization.data(withJSONObject: stats(), options: [.withoutEscapingSlashes]) else { return }
  say("stats " + String(decoding: json, as: UTF8.self))
}
statsTimer.resume()
RunLoop.main.run()
