import AppKit
import Vision

/// --cleanup-report <文件夹>：不开界面，打印逐张指标与分类结果，用于调阈值与测速
enum CleanupDebug {
    static func report(folder: String) {
        let model = FolderModel()
        model.open(url: URL(fileURLWithPath: folder))
        let units = CleanupUnit.make(from: model.items)
        let scanner = CleanupScanner(folder: URL(fileURLWithPath: folder), units: units, useCache: false)
        scanner.onFinish = {
            var lines = ["file\tsharp\tfaceSharp\tfaces\topen\tclosed\tblurry"]
            for u in units {
                guard let m = scanner.metrics[u.primary] else { lines.append("\(u.primary.lastPathComponent)\tFAILED"); continue }
                lines.append([u.primary.lastPathComponent, String(format: "%.1f", m.sharpness),
                              m.faceSharpness.map { String(format: "%.1f", $0) } ?? "-", "\(m.faceCount)",
                              zip(m.eyeOpenness, m.eyeDarkness).map { String(format: "%.2f/%.2f", $0, $1) }.joined(separator: ","),
                              "\(m.closedFaces.count)", CleanupResult.isBlurry(m) ? "Y" : ""].joined(separator: "\t"))
            }
            lines.append("\n# faces (x,y,w,h openness)")
            for u in units {
                guard let fs = scanner.metrics[u.primary]?.faces, !fs.isEmpty else { continue }
                let parts: [String] = fs.map { (f: FaceEyes) -> String in
                    let r = f.rect
                    return String(format: "%.2f,%.2f,%.2f,%.2f %.2f/%.2f", Double(r.minX), Double(r.minY), Double(r.width), Double(r.height),
                                  Double(f.openness), Double(f.darkness))
                }
                lines.append(u.primary.lastPathComponent + "\t" + parts.joined(separator: " | "))
            }
            // 按拍摄时间相邻两张的特征距离
            let timed: [(CleanupUnit, CleanupMetrics)] = units.compactMap { u in scanner.metrics[u.primary].map { (u, $0) } }.sorted { a, b in
                if a.1.captureDate != b.1.captureDate { return a.1.captureDate < b.1.captureDate }
                return a.0.primary.lastPathComponent.localizedStandardCompare(b.0.primary.lastPathComponent) == .orderedAscending
            }
            lines.append("\n# adjacent distances")
            for (a, b) in zip(timed, timed.dropFirst()) {
                var d: Float = -1
                if let pa = scanner.featurePrint(for: a.0.primary), let pb = scanner.featurePrint(for: b.0.primary) {
                    try? pa.computeDistance(&d, to: pb)
                }
                lines.append(String(format: "%@ -> %@\t%.3f\tdt=%.0f", a.0.primary.lastPathComponent,
                                    b.0.primary.lastPathComponent, d, b.1.captureDate - a.1.captureDate))
            }
            let r = CleanupResult.build(units: units, scanner: scanner)
            lines.append("\n# categories")
            for c in CleanupCategory.allCases {
                for g in r.groups[c] ?? [] {
                    let names = g.units.map { u in
                        (r.suggested.contains(u.primary) ? "[x]" : "[ ]") + (g.keeper == u.primary ? "*" : "") + u.primary.lastPathComponent
                    }
                    lines.append("\(c)\t" + names.joined(separator: " "))
                }
            }
            lines.append(String(format: "\n# %d units, %.2fs, %.0f ms/unit (\(CleanupScanner.workers) workers)", units.count, scanner.elapsed,
                                scanner.elapsed * 1000 / Double(max(units.count, 1))))
            print(lines.joined(separator: "\n"))
            exit(0)
        }
        scanner.start()
    }
}
