import AppKit

/// 看图器里的摄影质检状态（直方图 H / 过曝死黑警示 J / 焦点峰值 K / 相机对焦框 A），挂在 ViewerViewController 上
final class ViewerInspectState {
    var showHistogram = false
    var showClipping = false
    var showPeaking = false
    var showAF = false
    let histogramView = ViewerHistogramView()
    var bottomConstraint: NSLayoutConstraint?
    let queue = DispatchQueue(label: "flipic.inspect", qos: .userInitiated)
    var token = 0
}

extension ViewerViewController {
    func setupInspectOverlay() {
        let hv = inspect.histogramView
        view.addSubview(hv)
        // 放左下角：和右上角的信息面板 / 胶片面板、右下角的胶片徽标、底部居中工具条互不遮挡
        let bottom = hv.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: -14)
        inspect.bottomConstraint = bottom
        NSLayoutConstraint.activate([
            hv.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 16),
            bottom,
        ])
    }

    func updateInspectLayout() {
        inspect.histogramView.isHidden = !inspect.showHistogram || folder.current == nil || cleanup != nil || currentIsVideo || border != nil || compareView != nil
    }

    @objc func toggleHistogram(_ sender: Any?) {
        guard folder.current != nil, cleanup == nil else { return }
        inspect.showHistogram.toggle()
        updateInspectLayout()
        refreshInspectOverlays()
        flash(inspect.showHistogram ? L10n.t("inspect.histOn", "直方图已开启") : L10n.t("inspect.histOff", "直方图已关闭"), seconds: 1.2)
    }

    @objc func toggleClipping(_ sender: Any?) {
        guard folder.current != nil, cleanup == nil else { return }
        inspect.showClipping.toggle()
        refreshInspectOverlays()
        flash(inspect.showClipping ? L10n.t("inspect.clipOn", "过曝与暗部警示已开启（红=过曝 · 蓝=死黑）")
                                   : L10n.t("inspect.clipOff", "过曝与暗部警示已关闭"), seconds: 1.6)
    }

    @objc func toggleFocusPeaking(_ sender: Any?) {
        guard folder.current != nil, cleanup == nil else { return }
        inspect.showPeaking.toggle()
        refreshInspectOverlays()
        flash(inspect.showPeaking ? L10n.t("inspect.peakOn", "焦点峰值已开启") : L10n.t("inspect.peakOff", "焦点峰值已关闭"), seconds: 1.2)
    }

    @objc func toggleAFPoint(_ sender: Any?) {
        guard folder.current != nil, cleanup == nil else { return }
        inspect.showAF.toggle()
        refreshInspectOverlays(notifyMissingAF: inspect.showAF)
        if !inspect.showAF { flash(L10n.t("inspect.afOff", "相机对焦框已关闭"), seconds: 1.2) }
    }

    /// 换图、清晰图到位、旋转或开关变化时刷新质检层（后台算，主线程贴图）
    func refreshInspectOverlays(notifyMissingAF: Bool = false) {
        inspect.token += 1
        let tok = inspect.token
        updateInspectLayout()
        guard let url = folder.current?.url, cleanup == nil, !currentIsVideo, border == nil, compareView == nil else {
            imageView.setInspectMask(nil)
            imageView.setAFBoxes([])
            inspect.histogramView.histogram = nil
            return
        }
        let wantHist = inspect.showHistogram
        let wantClip = inspect.showClipping
        let wantPeak = inspect.showPeaking
        let wantAF = inspect.showAF
        if !wantClip && !wantPeak { imageView.setInspectMask(nil) }
        if !wantAF { imageView.setAFBoxes([]) }
        if !wantHist { inspect.histogramView.histogram = nil }
        guard wantHist || wantClip || wantPeak || wantAF else { return }
        let displayed = imageView.currentImage

        inspect.queue.async { [weak self] in
            let hist = (wantHist && displayed != nil) ? PhotoHistogram.compute(displayed!) : nil
            let mask = ((wantClip || wantPeak) && displayed != nil)
                ? InspectMask.render(displayed!, clipping: wantClip, peaking: wantPeak) : nil
            let af = wantAF ? AFPointReader.read(url: url) : []
            DispatchQueue.main.async {
                guard let self, self.inspect.token == tok else { return }
                if wantHist { self.inspect.histogramView.histogram = hist }
                if wantClip || wantPeak { self.imageView.setInspectMask(mask) }
                if wantAF {
                    self.imageView.setAFBoxes(af)
                    if notifyMissingAF {
                        self.flash(af.isEmpty ? L10n.t("inspect.afNone", "这张照片没有记录对焦框")
                                              : L10n.t("inspect.afOn", "已显示相机对焦框"), seconds: 1.6)
                    }
                }
            }
        }
    }
}
