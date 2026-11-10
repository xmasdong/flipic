import AppKit

/// 「帮助 › 找回删掉的照片」：说清楚删除去了哪儿、怎么挪回来，并给出能直接点的入口。
/// 用户的机器上最常出现的误解是「外置盘删掉的东西应该在本机废纸篓里」，这里把位置直接列出来。
final class TrashHelpWindowController: NSWindowController {
    static let shared = TrashHelpWindowController()

    private let stack = NSStackView()
    private var volumes: [URL] = []

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 620),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L10n.t("trashhelp.title", "找回删掉的照片")
        w.isReleasedWhenClosed = false
        super.init(window: w)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
        ])
        w.contentView = container
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        volumes = Trash.mountedExternalVolumes
        rebuild()
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 内容

    private func rebuild() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }

        let body = NSTextField(labelWithAttributedString: guideText())
        body.preferredMaxLayoutWidth = 536
        body.isSelectable = true
        stack.addArrangedSubview(body)

        // 能直接点的一行：撤销、显示位置、好
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        if ViewerViewController.lastTrash != nil {
            row.addArrangedSubview(button(L10n.t("trashhelp.undo", "撤销最近一次删除"), #selector(restoreLastTrash(_:))))
            row.addArrangedSubview(button(L10n.t("trashhelp.reveal", "在 Finder 中显示"), #selector(revealLastTrash(_:))))
        }
        row.addArrangedSubview(button(L10n.t("trashhelp.openLocal", "打开本机废纸篓"), #selector(openLocalTrash(_:))))
        let ok = button(L10n.t("trashhelp.close", "好"), #selector(close(_:)))
        ok.keyEquivalent = "\r"
        row.addArrangedSubview(ok)
        stack.addArrangedSubview(row)

        // 挂着的外置盘：一条一个按钮，直接打开那块盘的废纸篓
        for (i, vol) in volumes.enumerated() {
            let name = vol.lastPathComponent
            let b = button(L10n.f("trashhelp.openVolume", "打开「%@」的废纸篓", name), #selector(openVolumeTrash(_:)))
            b.tag = i
            stack.addArrangedSubview(b)
        }
        let browse = button(L10n.t("trashhelp.browse", "看看废纸篓里最近的图片"), #selector(browseTrash(_:)))
        stack.addArrangedSubview(browse)

        if let w = window {
            w.setContentSize(NSSize(width: 580, height: stack.fittingSize.height + 40))
        }
    }

    /// 扫废纸篓里最近的图片：不依赖删除记录，老版本删掉的也能看见
    @objc private func browseTrash(_ sender: Any?) {
        TrashBrowserWindowController.shared.show()
        window?.close()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func guideText() -> NSAttributedString {
        let out = NSMutableAttributedString()
        func head(_ s: String) {
            out.append(NSAttributedString(string: s + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        func para(_ s: String) {
            out.append(NSAttributedString(string: s + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        head(L10n.t("trashhelp.intro", "Flipic 删照片是「移到废纸篓」，没有直接抹掉。"))
        para(L10n.t("trashhelp.introNote", "东西去哪了，取决于照片在哪个盘上："))

        head(L10n.t("trashhelp.localHead", "本机硬盘上的照片"))
        para(L10n.f("trashhelp.localBody", "进本机废纸篓（%@），访达侧边栏和程序坞都能看到。", Trash.localTrashFolder.path))

        head(L10n.t("trashhelp.externalHead", "外置盘上的照片"))
        para(L10n.t("trashhelp.externalBody", "进这块盘自己的废纸篓，位置是「盘名/.Trashes/你的用户编号」，不在本机废纸篓里。盘拔掉以后就看不到了，接上盘用下面的按钮能直接打开。"))
        para(L10n.t("trashhelp.externalWhy", "「废纸篓里找不到」最常见的就是这个原因：不是没删成功，是位置不一样。"))
        for vol in volumes {
            para("· " + Trash.existingVolumeTrashFolder(of: vol).path)
        }

        head(L10n.t("trashhelp.networkHead", "NAS、网络盘和只读的 NTFS 盘"))
        para(L10n.t("trashhelp.networkBody", "这类位置通常没有废纸篓，删不掉。Flipic 会提示「没能挪动成功，还在原处」，照片仍然留在原来的文件夹里，不会丢。"))

        head(L10n.t("trashhelp.restoreHead", "想挪回原处"))
        para(L10n.t("trashhelp.restore1", "· 在 Flipic 里按 ⌘Z，或者「文件 › 放回刚才删掉的照片」。外置盘也一样，只是要跨盘复制回来，会慢一点。"))
        para(L10n.t("trashhelp.restore2", "· 如果早就清空过废纸篓、或者换了电脑，就只能从时间机器等备份里找。"))

        head(L10n.t("trashhelp.settingHead", "想以后都放在本机废纸篓"))
        para(L10n.t("trashhelp.settingBody", "设置 › 通用 › 删除，打开「删除外置盘上的照片时，复制到本机废纸篓」。打开后删除会慢一些，也会临时占本机空间。"))
        return out
    }

    // MARK: - 动作

    @objc private func close(_ sender: Any?) { window?.close() }

    @objc private func revealLastTrash(_ sender: Any?) {
        guard let rec = ViewerViewController.lastTrash else { return }
        Trash.revealInFinder(rec.moved.values.sorted { $0.path < $1.path })
    }

    @objc private func openLocalTrash(_ sender: Any?) {
        Trash.openFolder(Trash.localTrashFolder)
    }

    @objc private func openVolumeTrash(_ sender: Any?) {
        guard let tag = (sender as? NSButton)?.tag, volumes.indices.contains(tag) else { return }
        Trash.openFolder(Trash.existingVolumeTrashFolder(of: volumes[tag]))
    }

    /// 把最近一次删除的文件挪回原处（跨卷也能挪，系统会复制回来）
    @objc private func restoreLastTrash(_ sender: Any?) {
        guard let rec = ViewerViewController.lastTrash else { return }
        let fm = FileManager.default
        var back = 0
        for (orig, trashed) in rec.moved where !fm.fileExists(atPath: orig.path) {
            if (try? fm.moveItem(at: trashed, to: orig)) != nil { back += 1 }
        }
        ViewerViewController.lastTrash = nil
        let alert = NSAlert()
        alert.messageText = L10n.f("trashhelp.restoredTitle", "已放回 %d 个文件", back)
        alert.informativeText = L10n.t("trashhelp.restoredBody", "回到 Flipic 就能看到；列表会自动刷新。")
        alert.addButton(withTitle: L10n.t("trashhelp.ok", "好"))
        alert.runModal()
        rebuild()
    }
}
