import AppKit

extension ViewerViewController {
    /// 文件 › 加水印导出…：打开平常的 ⌘S 导出面板，「水印」直接选上上次用的样式（没用过就是「证件用途」）
    @objc func exportWithWatermark(_ sender: Any?) {
        WatermarkMemory.forceNextExport = true
        defer { WatermarkMemory.forceNextExport = false }
        exportAs(nil)
    }
}
