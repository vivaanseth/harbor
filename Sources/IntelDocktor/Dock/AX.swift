import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin, forgiving wrappers around the Accessibility C API.
enum AX {
    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        value(el, attr) as? String
    }

    static func role(_ el: AXUIElement) -> String? { string(el, kAXRoleAttribute) }
    static func subrole(_ el: AXUIElement) -> String? { string(el, kAXSubroleAttribute) }
    static func title(_ el: AXUIElement) -> String? { string(el, kAXTitleAttribute) }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        if let n = value(el, attr) as? NSNumber { return n.boolValue }
        return nil
    }

    static func url(_ el: AXUIElement) -> URL? {
        let v = value(el, kAXURLAttribute)
        if let u = v as? URL { return u }
        if let s = v as? String { return URL(string: s) }
        return nil
    }

    static func position(_ el: AXUIElement) -> CGPoint? {
        guard let v = value(el, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement) -> CGSize? {
        guard let v = value(el, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Frame in CG global coordinates (top-left origin).
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = position(el), let s = size(el) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success && id != 0 ? id : nil
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        return (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ v: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, attr as CFString, v) == .success
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
}
