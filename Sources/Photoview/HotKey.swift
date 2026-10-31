import AppKit
import Carbon.HIToolbox

/// 全局快捷键：在别的软件里按也能把 Flipic 叫到前面或收起来。
/// 用 Carbon 的 RegisterEventHotKey，不需要辅助功能权限，沙盒里也能用
enum HotKey {
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false
    static var onPress: (() -> Void)?

    /// 按设置里的组合重新注册；没设就注销
    static func update() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let combo = Shortcuts.combo(for: .toggleApp), combo.isMenuCombo else { return }
        installHandler()
        let m = combo.modifiers
        var carbon: UInt32 = 0
        if m.contains(.command) { carbon |= UInt32(cmdKey) }
        if m.contains(.option) { carbon |= UInt32(optionKey) }
        if m.contains(.control) { carbon |= UInt32(controlKey) }
        if m.contains(.shift) { carbon |= UInt32(shiftKey) }
        let id = EventHotKeyID(signature: OSType(0x464C5043), id: 1)   // 'FLPC'
        let status = RegisterEventHotKey(UInt32(combo.keyCode), carbon, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("HotKey register failed %d", status) }
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.onPress?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static var isRegistered: Bool { ref != nil }
}
