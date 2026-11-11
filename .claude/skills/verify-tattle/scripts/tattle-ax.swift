// Reads and presses the Tattle panel through the accessibility API, by label, never by
// screen position. Built by tattle-verify into build/verify-tools/tattle-ax.
//
//   tattle-ax trusted
//   tattle-ax <pid> status | open | close | frame | dump | text
//   tattle-ax <pid> shot <file.png>
//   tattle-ax <pid> press [--prefix] <label>
//   tattle-ax <pid> wait <substring> [seconds]
//   tattle-ax <pid> scroll up|down
import ApplicationServices
import Foundation

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func string(_ e: AXUIElement, _ name: String) -> String? {
    guard let v = attr(e, name) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, "AXChildren") as? [AXUIElement] ?? [] }

func actions(_ e: AXUIElement) -> [String] {
    var names: CFArray?
    AXUIElementCopyActionNames(e, &names)
    return names as? [String] ?? []
}

/// What a person reads on the element: SwiftUI puts a row's or a button's words in its
/// description and a text's words in its value.
func labels(_ e: AXUIElement) -> [String] {
    ["AXDescription", "AXTitle", "AXValue"].compactMap { string(e, $0) }
}

func walk(_ e: AXUIElement, depth: Int = 0, _ visit: (AXUIElement, Int) -> Bool) -> Bool {
    if visit(e, depth) { return true }
    for c in children(e) where walk(c, depth: depth + 1, visit) { return true }
    return false
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "trusted" {
    print(AXIsProcessTrusted() ? "trusted" : "not trusted")
    exit(AXIsProcessTrusted() ? 0 : 1)
}
guard args.count >= 2, let pid = pid_t(args[0]) else { fail("usage: tattle-ax <pid> open|close|status|frame|dump|text|press|wait|scroll|shot ...") }
guard AXIsProcessTrusted() else { fail("this terminal has no Accessibility permission (System Settings, Privacy & Security, Accessibility)") }
let app = AXUIElementCreateApplication(pid)

/// The panel MenuBarExtra drops down; the Settings window is a standard window instead.
func panel() -> AXUIElement? {
    let windows = attr(app, "AXWindows") as? [AXUIElement] ?? []
    return windows.first { string($0, "AXSubrole") == "AXSystemDialog" }
}

func statusItem() -> AXUIElement {
    guard let bar = attr(app, "AXExtrasMenuBar"), let item = children(bar as! AXUIElement).first else {
        fail("pid \(pid) has no menu bar item")
    }
    return item
}

func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        usleep(200_000)
    }
    return condition()
}

func requirePanel() -> AXUIElement {
    guard let p = panel() else { fail("the panel is not open; run: tattle-ax \(pid) open") }
    return p
}

switch args[1] {
case "status":
    _ = statusItem()
    print(panel() == nil ? "panel closed" : "panel open")
case "shot":
    guard args.count >= 3 else { fail("usage: tattle-ax <pid> shot <file.png>") }
    let p = requirePanel()
    var size = CGSize.zero
    AXValueGetValue(attr(p, "AXSize") as! AXValue, .cgSize, &size)
    let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let info = infos.first(where: {
        ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
            && CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary)?.size == size
    }), let number = info[kCGWindowNumber as String] as? Int,
          let bounds = CGRect(dictionaryRepresentation: info[kCGWindowBounds as String] as! CFDictionary) else {
        fail("no window of pid \(pid) has the panel's size")
    }
    // When the menu bar is too full to show Tattle's item, macOS places the item, and the
    // panel under it, off every display, where screencapture gets no image. Moving the
    // panel onto the main display changes where it is, not what it shows.
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &displays, &count)
    if !displays.contains(where: { CGDisplayBounds($0).contains(bounds) }) {
        let main = CGDisplayBounds(CGMainDisplayID())
        var origin = CGPoint(x: main.maxX - size.width - 8, y: main.minY + 32)
        AXUIElementSetAttributeValue(p, "AXPosition" as CFString, AXValueCreate(.cgPoint, &origin)!)
        usleep(300_000)
        print("moved the panel onto the main display for the capture")
    }
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(number), args[2]]
    try capture.run()
    capture.waitUntilExit()
    guard capture.terminationStatus == 0 else { fail("screencapture failed; this terminal may lack Screen Recording permission") }
    print(args[2])
case "open":
    if panel() == nil { AXUIElementPerformAction(statusItem(), "AXPress" as CFString) }
    guard waitFor(5, { panel() != nil }) else { fail("the panel did not open") }
    print("open")
case "close":
    if panel() != nil { AXUIElementPerformAction(statusItem(), "AXPress" as CFString) }
    guard waitFor(5, { panel() == nil }) else { fail("the panel did not close") }
    print("closed")
case "frame":
    let p = requirePanel()
    var origin = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(attr(p, "AXPosition") as! AXValue, .cgPoint, &origin)
    AXValueGetValue(attr(p, "AXSize") as! AXValue, .cgSize, &size)
    print("\(Int(origin.x)),\(Int(origin.y)),\(Int(size.width)),\(Int(size.height))")
case "dump":
    _ = walk(requirePanel()) { e, depth in
        var parts = [string(e, "AXRole") ?? "?"]
        for key in ["AXSubrole", "AXIdentifier"] { if let v = string(e, key) { parts.append(v) } }
        parts += labels(e).map { "\"\($0)\"" }
        if actions(e).contains("AXPress") { parts.append("[press]") }
        print(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
        return false
    }
case "text":
    _ = walk(requirePanel()) { e, _ in
        for l in labels(e) { print(l) }
        return false
    }
case "press":
    let prefix = args.count > 3 && args[2] == "--prefix"
    guard let wanted = args.last, args.count >= 3 else { fail("usage: tattle-ax <pid> press [--prefix] <label>") }
    var target: AXUIElement?
    _ = walk(requirePanel()) { e, _ in
        guard actions(e).contains("AXPress") else { return false }
        if labels(e).contains(where: { prefix ? $0.hasPrefix(wanted) : $0 == wanted }) { target = e; return true }
        return false
    }
    guard let target else { fail("nothing pressable labelled \(prefix ? "starting with " : "")\"\(wanted)\"; run dump to see the labels") }
    // SwiftUI segments report an error and switch anyway, so the result is not checked;
    // the caller proves the press by what the panel shows next.
    AXUIElementPerformAction(target, "AXPress" as CFString)
    print("pressed: \(labels(target).first ?? wanted)")
case "wait":
    guard args.count >= 3 else { fail("usage: tattle-ax <pid> wait <substring> [seconds]") }
    let seconds = args.count > 3 ? Double(args[3]) ?? 10 : 10
    var found: String?
    let ok = waitFor(seconds) {
        guard let p = panel() else { return false }
        return walk(p) { e, _ in
            if let l = labels(e).first(where: { $0.contains(args[2]) }) { found = l; return true }
            return false
        }
    }
    guard ok, let found else { fail("no \"\(args[2])\" in the panel after \(Int(seconds)) s") }
    print(found)
case "scroll":
    // The scroll bar's page button, as a click in the track would: SwiftUI's scroll views
    // accept AXScrollDownByPage and do not move.
    let page = args.count > 2 && args[2] == "up" ? "AXDecrementPage" : "AXIncrementPage"
    var button: AXUIElement?
    var bar: AXUIElement?
    _ = walk(requirePanel()) { e, _ in
        if string(e, "AXRole") == "AXScrollBar" { bar = e }
        if string(e, "AXSubrole") == page { button = e; return true }
        return false
    }
    guard let button, let bar else { fail("no scroll bar in the panel: everything is already on screen") }
    let before = string(bar, "AXValue")
    AXUIElementPerformAction(button, "AXPress" as CFString)
    usleep(300_000)
    let after = string(bar, "AXValue")
    print(before == after ? "at the end" : "scrolled")
default:
    fail("unknown command \(args[1])")
}
