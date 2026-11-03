import AppKit

/// 一个按键组合：按物理键位（keyCode）匹配，换输入法、开大写锁定都不影响；
/// chars 是不带修饰键时这个键打出的字符，用来生成菜单快捷键和显示
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var mods: UInt
    var chars: String

    static let relevantMods: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    init(keyCode: UInt16, mods: NSEvent.ModifierFlags = [], chars: String) {
        self.keyCode = keyCode
        self.mods = mods.intersection(Self.relevantMods).rawValue
        self.chars = chars
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let base = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        self.init(keyCode: event.keyCode, mods: event.modifierFlags, chars: base.lowercased())
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: mods) }

    /// 带 ⌘ / ⌥ / ⌃ 的组合挂到菜单上；单键和 ⇧+键只在看图界面里响应，避免在输入框里打字时被菜单抢走
    var isMenuCombo: Bool { !modifiers.intersection([.command, .option, .control]).isEmpty }

    private static let specialNames: [UInt16: String] = [
        123: "←", 124: "→", 125: "↓", 126: "↑", 36: "↩", 76: "⌤", 51: "⌫", 117: "⌦", 48: "⇥", 53: "Esc",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    var keyName: String {
        if keyCode == 49 { return L10n.t("key.space", "空格") }
        if let s = Self.specialNames[keyCode] { return s }
        return chars.uppercased()
    }

    var display: String {
        let m = modifiers
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + keyName
    }

    /// NSMenuItem.keyEquivalent 用的字符
    var menuKey: String {
        func fn(_ c: Int) -> String { String(Character(UnicodeScalar(UInt32(c))!)) }
        switch keyCode {
        case 123: return fn(NSLeftArrowFunctionKey)
        case 124: return fn(NSRightArrowFunctionKey)
        case 125: return fn(NSDownArrowFunctionKey)
        case 126: return fn(NSUpArrowFunctionKey)
        case 115: return fn(NSHomeFunctionKey)
        case 119: return fn(NSEndFunctionKey)
        case 116: return fn(NSPageUpFunctionKey)
        case 121: return fn(NSPageDownFunctionKey)
        case 36, 76: return "\r"
        case 51: return "\u{8}"
        case 117: return fn(NSDeleteFunctionKey)
        case 48: return "\t"
        case 49: return " "
        default: return chars
        }
    }
}

/// 可以在设置里改键的操作。Esc、⌘O、⌘W 这类系统惯例和固定菜单项不在这里
enum ShortcutAction: String, CaseIterable {
    case toggleApp
    case prev, next, first, last
    case zoomIn, zoomOut, zoomAtPointer, actualSize, peek, fullscreen
    case info, filmstrip, slideshow, rotateCW, rotateCCW
    case rename, trash, edit, reveal, exportAs, exportFolder, saveRotation
    case cleanup, batchConvert, batchRename, wallpaper
    case rate1, rate2, rate3, rate4, rate5, rate0
    case mark, markedOnly, compare, compare4, comparePane, compareSync
    case beforeAfter, splitByRating, switchPair
    case pinWindow, share, playLive, zoomEye, workbench

    /// Pro 功能；开源版里没有，不在快捷键设置里列出
    /// 快捷键页里 Pro 功能名后面的标；App Store 版全都包含，不加
    static var proSuffix: String {
        return " (Pro)"
    }

    var isPro: Bool { [.beforeAfter, .splitByRating, .switchPair, .zoomEye, .workbench].contains(self) }

    var isAvailable: Bool {
        #if FLIPIC_PRO
        if self == .workbench { return WorkbenchFeature.isEnabled }
        return true
        #else
        return !isPro
        #endif
    }

    /// 评分快捷键对应的星数
    var stars: Int? {
        switch self {
        case .rate0: return 0
        case .rate1: return 1
        case .rate2: return 2
        case .rate3: return 3
        case .rate4: return 4
        case .rate5: return 5
        default: return nil
        }
    }

    enum Group: CaseIterable {
        case global, browse, rating, pick, view, file, tools
        var title: String {
            switch self {
            case .global: return L10n.t("sc.group.global", "全局（在其他软件里也能用）")
            case .browse: return L10n.t("sc.group.browse", "浏览")
            case .rating: return L10n.t("sc.group.rating", "评分")
            case .pick: return L10n.t("sc.group.pick", "挑片")
            case .view: return L10n.t("sc.group.view", "显示")
            case .file: return L10n.t("sc.group.file", "文件")
            case .tools: return L10n.t("sc.group.tools", "工具")
            }
        }
        var actions: [ShortcutAction] { ShortcutAction.allCases.filter { $0.group == self && $0.isAvailable } }
    }

    var group: Group {
        switch self {
        case .toggleApp: return .global
        case .prev, .next, .first, .last, .zoomIn, .zoomOut, .zoomAtPointer, .actualSize, .peek, .zoomEye: return .browse
        case .fullscreen, .info, .filmstrip, .slideshow, .rotateCW, .rotateCCW: return .view
        case .rename, .trash, .edit, .reveal, .exportAs, .exportFolder, .saveRotation, .share: return .file
        case .pinWindow, .playLive: return .view
        case .cleanup, .batchConvert, .batchRename, .wallpaper, .workbench: return .tools
        case .rate1, .rate2, .rate3, .rate4, .rate5, .rate0: return .rating
        case .mark, .markedOnly, .compare, .compare4, .comparePane, .compareSync, .beforeAfter, .splitByRating, .switchPair: return .pick
        }
    }

    var title: String {
        func plain(_ s: String) -> String {
            s.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
        }
        switch self {
        case .toggleApp: return L10n.t("sc.a.toggleApp", "显示 / 隐藏 Flipic")
        case .prev: return L10n.t("menu.prev", "上一张")
        case .next: return L10n.t("menu.next", "下一张")
        case .first: return L10n.t("menu.first", "第一张")
        case .last: return L10n.t("menu.last", "最后一张")
        case .zoomIn: return L10n.t("menu.zoomIn", "放大")
        case .zoomOut: return L10n.t("menu.zoomOut", "缩小")
        case .zoomAtPointer: return L10n.t("sc.a.zoomAtPointer", "在鼠标处放大到 100%，再按恢复")
        case .actualSize: return L10n.t("menu.actualSize", "实际大小 (100%)")
        case .peek: return L10n.t("sc.a.peek", "贴合照片比例预览")
        case .fullscreen: return L10n.t("sc.a.fullscreen", "全屏")
        case .info: return L10n.t("menu.info", "照片信息")
        case .filmstrip: return L10n.t("menu.filmstrip", "缩略图栏")
        case .slideshow: return L10n.t("menu.slideshow", "幻灯片放映")
        case .rotateCW: return L10n.t("menu.rotateCW", "向右旋转 90°")
        case .rotateCCW: return L10n.t("menu.rotateCCW", "向左旋转 90°")
        case .rename: return plain(L10n.t("menu.rename", "重命名…"))
        case .trash: return L10n.t("menu.trash", "移到废纸篓")
        case .edit: return plain(L10n.t("menu.editChoose", "在后期软件中编辑…"))
        case .reveal: return L10n.t("menu.reveal", "在 Finder 中显示")
        case .exportAs: return plain(L10n.t("menu.exportAs", "导出为…"))
        case .exportFolder: return plain(L10n.t("menu.exportFolder", "导出到文件夹…"))
        case .saveRotation: return L10n.t("menu.saveRotation", "保存旋转")
        case .cleanup: return L10n.t("menu.cleanup", "清理模式")
        case .batchConvert: return plain(L10n.t("menu.batchConvert", "批量转换格式…"))
        case .batchRename: return plain(L10n.t("menu.batchRename", "批量重命名…"))
        case .wallpaper: return L10n.t("menu.wallpaper", "设为桌面壁纸")
        case .rate0: return L10n.t("rating.none", "未评分")
        case .rate1, .rate2, .rate3, .rate4, .rate5: return Rating.stars(stars ?? 0)
        case .mark: return L10n.t("sc.a.mark", "标记 / 取消标记")
        case .markedOnly: return L10n.t("menu.markedOnly", "只看已标记")
        case .compare: return L10n.t("menu.compare2", "并排对比 2 张")
        case .compare4: return L10n.t("menu.compare4", "并排对比 4 张")
        case .comparePane: return L10n.t("sc.a.comparePane", "对比时切换当前格")
        case .compareSync: return L10n.t("menu.compareSync", "对比时同步缩放和位置")
        case .beforeAfter: return L10n.t("menu.beforeAfter", "修图前后对比") + ShortcutAction.proSuffix
        case .splitByRating: return plain(L10n.t("menu.splitByRating", "按星级分到子文件夹…")) + ShortcutAction.proSuffix
        case .switchPair: return L10n.t("menu.switchPair", "切换看 JPG / RAW") + ShortcutAction.proSuffix
        case .pinWindow: return L10n.t("menu.pin", "窗口置顶")
        case .share: return plain(L10n.t("menu.share", "分享…"))
        case .playLive: return L10n.t("menu.playLive", "播放实况照片")
        case .zoomEye: return L10n.t("menu.zoomEye", "放大到眼睛") + ShortcutAction.proSuffix
        case .workbench: return L10n.t("menu.workbench", "工作台") + ShortcutAction.proSuffix
        }
    }

    /// 全局的显示 / 隐藏默认不设，免得和别的软件抢键
    var defaultCombo: KeyCombo? {
        switch self {
        case .toggleApp: return nil
        case .prev: return KeyCombo(keyCode: 123, chars: "")
        case .next: return KeyCombo(keyCode: 124, chars: "")
        case .first: return KeyCombo(keyCode: 115, chars: "")
        case .last: return KeyCombo(keyCode: 119, chars: "")
        case .zoomIn: return KeyCombo(keyCode: 126, chars: "")
        case .zoomOut: return KeyCombo(keyCode: 125, chars: "")
        case .zoomAtPointer: return KeyCombo(keyCode: 29, chars: "0")
        case .actualSize: return nil   // 1 留给 1 星，实际大小用 ⌘1
        case .peek: return KeyCombo(keyCode: 49, chars: " ")
        case .fullscreen: return KeyCombo(keyCode: 3, chars: "f")
        case .info: return KeyCombo(keyCode: 34, chars: "i")
        case .filmstrip: return KeyCombo(keyCode: 17, chars: "t")
        case .slideshow: return KeyCombo(keyCode: 1, chars: "s")
        case .rotateCW: return KeyCombo(keyCode: 15, chars: "r")
        case .rotateCCW: return KeyCombo(keyCode: 37, chars: "l")
        case .rename: return KeyCombo(keyCode: 36, chars: "\r")
        case .trash: return KeyCombo(keyCode: 51, mods: .command, chars: "\u{7F}")
        case .edit: return KeyCombo(keyCode: 14, mods: .command, chars: "e")
        case .reveal: return KeyCombo(keyCode: 15, mods: .command, chars: "r")
        case .exportAs: return KeyCombo(keyCode: 1, mods: .command, chars: "s")
        case .exportFolder: return KeyCombo(keyCode: 14, mods: [.command, .shift], chars: "e")
        case .saveRotation: return KeyCombo(keyCode: 1, mods: [.command, .option], chars: "s")
        case .cleanup: return KeyCombo(keyCode: 40, mods: [.command, .shift], chars: "k")
        case .batchConvert: return KeyCombo(keyCode: 8, mods: [.command, .shift], chars: "c")
        case .batchRename: return KeyCombo(keyCode: 11, mods: [.command, .shift], chars: "b")
        case .wallpaper: return KeyCombo(keyCode: 2, mods: [.command, .shift], chars: "d")
        case .rate1: return KeyCombo(keyCode: 18, chars: "1")
        case .rate2: return KeyCombo(keyCode: 19, chars: "2")
        case .rate3: return KeyCombo(keyCode: 20, chars: "3")
        case .rate4: return KeyCombo(keyCode: 21, chars: "4")
        case .rate5: return KeyCombo(keyCode: 23, chars: "5")
        case .rate0: return nil
        case .mark: return KeyCombo(keyCode: 35, chars: "p")
        case .markedOnly: return KeyCombo(keyCode: 35, mods: .shift, chars: "p")
        case .compare: return KeyCombo(keyCode: 8, chars: "c")
        case .compare4: return KeyCombo(keyCode: 8, mods: .shift, chars: "c")
        case .comparePane: return KeyCombo(keyCode: 48, chars: "\t")
        case .compareSync: return KeyCombo(keyCode: 37, mods: .shift, chars: "l")
        case .beforeAfter: return KeyCombo(keyCode: 11, chars: "b")
        case .splitByRating: return nil
        case .switchPair: return KeyCombo(keyCode: 9, chars: "v")
        case .pinWindow: return KeyCombo(keyCode: 17, mods: [.command, .option], chars: "t")
        case .share: return nil
        case .playLive: return KeyCombo(keyCode: 37, mods: .option, chars: "l")
        case .zoomEye: return KeyCombo(keyCode: 14, chars: "e")
        case .workbench: return KeyCombo(keyCode: 11, mods: [.command, .option], chars: "b")   // ⇧⌘B 已是批量重命名
        }
    }
}

enum Shortcuts {
    static let didChange = Notification.Name("FlipicShortcutsDidChange")
    private static let defaultsKey = "customShortcuts"
    /// 存成「没有快捷键」的占位
    private static let clearedCode = UInt16.max

    /// 只存改过的项；没改过的用默认值
    private static var overrides: [String: KeyCombo] = load()

    private static func load() -> [String: KeyCombo] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let dict = try? JSONDecoder().decode([String: KeyCombo].self, from: data) else { return [:] }
        return dict
    }

    private static func save() {
        if overrides.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func combo(for action: ShortcutAction) -> KeyCombo? {
        guard let c = overrides[action.rawValue] else { return action.defaultCombo }
        return c.keyCode == clearedCode ? nil : c
    }

    static func isCustomized(_ action: ShortcutAction) -> Bool { overrides[action.rawValue] != nil }

    static func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        let value = combo ?? KeyCombo(keyCode: clearedCode, chars: "")
        let isDefault = combo.map { c in action.defaultCombo.map { same($0, c) } ?? false } ?? (action.defaultCombo == nil)
        if isDefault {
            overrides.removeValue(forKey: action.rawValue)
        } else {
            overrides[action.rawValue] = value
        }
        save()
    }

    static func resetAll() {
        overrides = [:]
        save()
    }

    /// 已经被别的操作占用时返回那个操作
    static func owner(of combo: KeyCombo, excluding action: ShortcutAction? = nil) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && $0.isAvailable && same(Shortcuts.combo(for: $0), combo) }
    }

    private static func same(_ a: KeyCombo?, _ b: KeyCombo) -> Bool {
        guard let a else { return false }
        return a.keyCode == b.keyCode && a.mods == b.mods
    }

    /// 固定菜单项和系统惯例占用的组合，不允许分给别的操作
    static func isReserved(_ c: KeyCombo) -> Bool {
        if c.keyCode == 53 { return true }   // Esc
        let m = c.modifiers
        if m == .command {
            // ⌘Q ⌘W ⌘O ⌘N ⌘H ⌘M ⌘, ⌘/ ⌘= ⌘- ⌘0 ⌘1
            return [12, 13, 31, 45, 4, 46, 43, 44, 24, 27, 29, 18].contains(c.keyCode)
        }
        if m == [.command, .option] && c.keyCode == 4 { return true }   // ⌥⌘H
        if m == [.command, .control] && c.keyCode == 3 { return true }  // ⌃⌘F 全屏菜单
        return false
    }

    /// 看图界面按下的键对应哪个操作；没有完全匹配时，⇧+键 退回到不带 ⇧ 的那一项（大写 I、⇧= 这类）
    static func action(for event: NSEvent) -> ShortcutAction? {
        guard let c = KeyCombo(event: event) else { return nil }
        // 全局显示 / 隐藏由 HotKey 在系统层面处理，看图界面里不再响应一次
        if let a = owner(of: c) { return a == .toggleApp ? nil : a }
        if c.modifiers == .shift, let a = owner(of: KeyCombo(keyCode: c.keyCode, chars: c.chars)), a != .toggleApp {
            return a
        }
        return nil
    }

    /// 工具条按钮的提示文字：把翻译里写死的键换成当前设置的键
    static func tooltip(_ base: String, _ action: ShortcutAction) -> String {
        let stripped = base.replacingOccurrences(of: "\\s*[（(][^（()）]*[)）]\\s*$", with: "", options: .regularExpression)
        guard let c = combo(for: action) else { return stripped }
        return L10n.f("tip.format", "%1$@（%2$@）", stripped, c.display)
    }
}
