import AppKit
import NaturalLanguage
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 照片说明的翻译：只用系统自带的 Translation 框架，在这台 Mac 上完成。macOS 15 起才有，更早的系统上整个功能不出现。
/// 这里管语言判断、网址保护、缓存和取消；界面在 InfoPanelView 里
enum CaptionTranslation {
    static let didChange = Notification.Name("FlipicCaptionTranslationDidChange")

    /// 设置 › 看图 › 自动翻译照片说明。默认关
    static var autoTranslate: Bool {
        get { UserDefaults.standard.bool(forKey: "captionAutoTranslate") }
        set {
            UserDefaults.standard.set(newValue, forKey: "captionAutoTranslate")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// 系统有没有翻译框架
    static var isAvailable: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    /// 翻成什么语言：界面现在用的语言（系统设置里给这个 App 单独指定的语言、-AppleLanguages 都算）
    static var targetLanguage: String { Bundle.main.preferredLocalizations.first ?? "en" }

    // MARK: - 语言判断

    /// 这些文字是什么语言（BCP 47）；太短或者拿不准返回 nil。网址不算在内
    static func detectLanguage(_ texts: [String]) -> String? {
        var joined = texts.joined(separator: "\n")
        for (range, _) in InfoTextView.links(in: joined).reversed() {
            joined = (joined as NSString).replacingCharacters(in: range, with: " ")
        }
        func count(_ s: String) -> (letters: Int, wide: Int) {
            var letters = 0, wide = 0
            for u in s.unicodeScalars where CharacterSet.letters.contains(u) {
                letters += 1
                // 汉字、假名、谚文：一个字顶好几个字母
                if (0x2E80...0x9FFF).contains(u.value) || (0xAC00...0xD7AF).contains(u.value) || (0xF900...0xFAFF).contains(u.value) || u.value >= 0x20000 { wide += 1 }
            }
            return (letters, wide)
        }
        let all = count(joined)
        guard all.wide >= 6 || all.letters >= 24 else { return nil }
        // 图片社的说明常把国名地名全大写写在最前面（INDONESIA. BALI. The Hindu TAMPAK SIRING water temple…），
        // 整段拿去认会被地名带偏成印尼语：全大写的词先不看；整段都是大写的就改成小写再认
        let words = joined.components(separatedBy: .whitespacesAndNewlines)
        let mixed = words.filter { w in
            let l = w.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            return !(l.count >= 2 && l.allSatisfy { CharacterSet.uppercaseLetters.contains($0) })
        }.joined(separator: " ")
        let rest = count(mixed)
        let sample = rest.wide >= 6 || rest.letters >= 24 ? mixed : joined.lowercased()
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(3000)))
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.6, best.key != .undetermined else { return nil }
        return best.key.rawValue
    }

    /// 两个语言标识是不是同一种语言；中文要分简繁
    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        let la = Locale.Language(identifier: a), lb = Locale.Language(identifier: b)
        guard la.languageCode == lb.languageCode else { return false }
        guard la.languageCode?.identifier == "zh" else { return true }
        return Locale.Language(identifier: la.maximalIdentifier).script == Locale.Language(identifier: lb.maximalIdentifier).script
    }

    // MARK: - 网址保护

    /// 把一段文字拆开：要翻译的片段，和原样保留的片段（网址、换行、片段两头的空白、不含字母的标点数字）
    struct Segmented {
        /// (文字, 要不要翻译)
        var parts: [(text: String, translate: Bool)] = []

        init(_ text: String) {
            let ns = text as NSString
            var cursor = 0
            func addPlain(_ s: String) {
                // 一行一行翻：换行原样留着
                var first = true
                for line in s.components(separatedBy: "\n") {
                    if !first { parts.append(("\n", false)) }
                    first = false
                    let core = line.trimmingCharacters(in: .whitespaces)
                    guard !core.isEmpty, let r = line.range(of: core) else {
                        if !line.isEmpty { parts.append((line, false)) }
                        continue
                    }
                    let head = String(line[line.startIndex..<r.lowerBound]), tail = String(line[r.upperBound...])
                    if !head.isEmpty { parts.append((head, false)) }
                    parts.append((core, core.unicodeScalars.contains { CharacterSet.letters.contains($0) }))
                    if !tail.isEmpty { parts.append((tail, false)) }
                }
            }
            for (range, _) in InfoTextView.links(in: text) {
                if range.location > cursor { addPlain(ns.substring(with: NSRange(location: cursor, length: range.location - cursor))) }
                parts.append((ns.substring(with: range), false))
                cursor = NSMaxRange(range)
            }
            if cursor < ns.length { addPlain(ns.substring(from: cursor)) }
        }

        var pieces: [String] { parts.filter(\.translate).map(\.text) }

        /// 把翻好的片段放回去。网址和译文之间保证有空白：中文译文后面直接跟网址会连在一起，也点不准
        func assemble(_ translated: [String]) -> String {
            var out = "", index = 0
            var previousWasLink = false
            for p in parts {
                let isLink = !p.translate && p.text.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil
                let piece: String
                if p.translate {
                    piece = index < translated.count ? translated[index].trimmingCharacters(in: .whitespacesAndNewlines) : p.text
                    index += 1
                } else {
                    piece = p.text
                }
                if let last = out.unicodeScalars.last, let first = piece.unicodeScalars.first,
                   !CharacterSet.whitespacesAndNewlines.contains(last), !CharacterSet.whitespacesAndNewlines.contains(first),
                   isLink || (previousWasLink && p.translate) {
                    out += " "
                }
                out += piece
                previousWasLink = isLink
            }
            return out
        }
    }

    // MARK: - 缓存

    struct Key: Hashable {
        var texts: [String]
        var target: String
    }

    private static var cache: [Key: [String]] = [:]
    /// 用户点了「隐藏译文」的：再翻回来也先不显示
    private static var hidden: Set<Key> = []

    static func cached(_ key: Key) -> [String]? { cache[key] }
    static func isHidden(_ key: Key) -> Bool { hidden.contains(key) }
    static func setHidden(_ key: Key, _ on: Bool) {
        if on { hidden.insert(key) } else { hidden.remove(key) }
    }

    private static func store(_ key: Key, _ value: [String]) {
        if cache.count > 400 { cache.removeAll() }
        cache[key] = value
    }

    static func debugClearCache() {
        cache.removeAll()
        hidden.removeAll()
        readinessMemo.removeAll()
    }

    // MARK: - 能不能翻

    enum Readiness { case installed, needsDownload, unavailable }

    /// 已经装好和不支持的语言对记下来，不用每翻一张都问系统；要下载的每次都重新问（用户可能刚下完）
    private static var readinessMemo: [String: Readiness] = [:]

    /// 这一对语言现在能不能翻。completion 在主线程，可能是同步的
    static func readiness(from source: String, to target: String, completion: @escaping (Readiness) -> Void) {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let memoKey = source + ">" + target
            if let known = readinessMemo[memoKey] { completion(known); return }
            Task { @MainActor in
                let r: Readiness
                switch await TranslationEngine.shared.status(from: source, to: target) {
                case .installed: r = .installed
                case .supported: r = .needsDownload
                default: r = .unavailable
                }
                if r != .needsDownload { readinessMemo[memoKey] = r }
                completion(r)
            }
            return
        }
        #endif
        completion(.unavailable)
    }

    // MARK: - 翻译

    enum Outcome {
        case success([String])
        /// 用户没同意下载语言：安静地回到原样
        case declined
        case failed(String)
    }

    final class Job {
        fileprivate var task: Task<Void, Never>?
        func cancel() { task?.cancel() }
    }

    /// 翻译几段文字（标题、说明各一段，一批送进去）。installed = false 时会请系统弹出下载语言的询问。
    /// anchor 是窗口里的一个视图：macOS 15–25 要靠挂在它上面的一个看不见的 SwiftUI 视图拿到翻译会话，下载询问也从它所在的窗口弹出。
    /// 取消了的不回调；completion 在主线程
    static func translate(_ key: Key, from source: String, installed: Bool, delay: TimeInterval = 0, anchor: NSView,
                          completion: @escaping (Outcome) -> Void) -> Job {
        let job = Job()
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let segmented = key.texts.map(Segmented.init)
            let pieces = segmented.flatMap(\.pieces)
            job.task = Task { @MainActor in
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard !Task.isCancelled else { return }
                do {
                    let out = pieces.isEmpty ? [] : try await TranslationEngine.shared.translate(
                        pieces, from: source, to: key.target, installed: installed, host: TranslationHost.host(in: anchor))
                    guard !Task.isCancelled else { return }
                    var index = 0
                    let result: [String] = segmented.map { s in
                        let n = s.pieces.count
                        defer { index += n }
                        return s.assemble(Array(out[min(index, out.count)..<min(index + n, out.count)]))
                    }
                    store(key, result)
                    if !installed { readinessMemo.removeValue(forKey: source + ">" + key.target) }
                    completion(.success(result))
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    if CommandLine.arguments.contains("--translationtest") { NSLog("TRANSLATE error %@", "\(error)") }
                    // 要下载的语言：用户在系统的询问里点了不下载、或者关掉了下载进度，系统给的都是一个错误。
                    // 这时语言还没装上，当作用户不想下，不显示失败
                    if !installed, await TranslationEngine.shared.status(from: source, to: key.target) != .installed {
                        completion(.declined)
                        return
                    }
                    completion(.failed(failureText(error)))
                }
            }
            return job
        }
        #endif
        completion(.failed(L10n.t("info.translateNoResponse", "系统翻译没有响应")))
        return job
    }

    private static func failureText(_ error: Error) -> String {
        #if canImport(Translation)
        if #available(macOS 15.0, *), let e = error as? TranslationFailure {
            switch e {
            case .noSession: return L10n.t("info.translateNoResponse", "系统翻译没有响应")
            }
        }
        #endif
        let text = error.localizedDescription.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? L10n.t("info.translateNoResponse", "系统翻译没有响应") : text
    }

    /// 测试用：装好的语言也走 macOS 15–25 的那条路（SwiftUI 的 translationTask）
    static var debugForceHosted = false
    /// 测试用：上一次翻译走的哪条路
    static var debugLastRoute = "-"
}

#if canImport(Translation)

@available(macOS 15.0, *)
enum TranslationFailure: Error { case noSession }

@available(macOS 15.0, *)
@MainActor
final class TranslationEngine {
    static let shared = TranslationEngine()
    private let availability = LanguageAvailability()

    func status(from source: String, to target: String) async -> LanguageAvailability.Status {
        await availability.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
    }

    /// 一批片段翻成 target，顺序和送进去的一样
    func translate(_ pieces: [String], from source: String, to target: String, installed: Bool, host: TranslationHost?) async throws -> [String] {
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        let requests = pieces.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        // macOS 26 起，语言已经装好时可以直接建会话，不用经过界面
        if installed, !CaptionTranslation.debugForceHosted, #available(macOS 26.0, *) {
            CaptionTranslation.debugLastRoute = "installedSource"
            let session = TranslationSession(installedSource: from, target: to)
            let responses = try await withTaskCancellationHandler {
                try await session.translations(from: requests)
            } onCancel: {
                session.cancel()
            }
            return Self.ordered(responses, count: pieces.count)
        }
        // macOS 15–25，或者语言还没下载：会话只能从 SwiftUI 的 translationTask 里拿；语言没装时系统在这里弹出下载询问
        guard let host else { throw TranslationFailure.noSession }
        CaptionTranslation.debugLastRoute = "translationTask"
        return try await host.run(source: from, target: to) { session in
            try await session.prepareTranslation()
            return Self.ordered(try await session.translations(from: requests), count: pieces.count)
        }
    }

    /// 文档说结果和请求同序；这里还是按 clientIdentifier 对一遍
    private static func ordered(_ responses: [TranslationSession.Response], count: Int) -> [String] {
        var out = [String](repeating: "", count: count)
        for (i, r) in responses.enumerated() {
            let index = r.clientIdentifier.flatMap(Int.init) ?? i
            if out.indices.contains(index) { out[index] = r.targetText }
        }
        return out
    }
}

@available(macOS 15.0, *)
@MainActor
private final class TranslationHostModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var action: ((TranslationSession) async -> Void)?
}

@available(macOS 15.0, *)
private struct TranslationHostContent: View {
    @ObservedObject var model: TranslationHostModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(model.configuration) { session in
                await model.action?(session)
            }
    }
}

/// 挂在面板角上的一个 1×1、看不见的 SwiftUI 视图：AppKit 里拿翻译会话只有这一条路（macOS 26 之前）。
/// 一次只跑一个请求，后来的排队
@available(macOS 15.0, *)
@MainActor
final class TranslationHost {
    private static let hosts = NSMapTable<NSView, TranslationHost>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func host(in anchor: NSView) -> TranslationHost {
        if let h = hosts.object(forKey: anchor) { return h }
        let h = TranslationHost()
        h.view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        anchor.addSubview(h.view)
        hosts.setObject(h, forKey: anchor)
        return h
    }

    private let model = TranslationHostModel()
    private let view: NSView
    private var jobs: [Pending] = []
    private var busy = false

    private struct Pending {
        var source: Locale.Language
        var target: Locale.Language
        var body: (TranslationSession?) async -> Void
    }

    private init() {
        let v = NSHostingView(rootView: TranslationHostContent(model: model))
        v.setAccessibilityElement(false)
        view = v
    }

    func run<T>(source: Locale.Language, target: Locale.Language, _ body: @escaping (TranslationSession) async throws -> T) async throws -> T {
        let cancelled = Flag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                jobs.append(Pending(source: source, target: target) { session in
                    guard let session else { cont.resume(throwing: TranslationFailure.noSession); return }
                    // 排队的时候已经翻到别的照片了：不用翻了
                    if cancelled.on { cont.resume(throwing: CancellationError()); return }
                    do { cont.resume(returning: try await body(session)) } catch { cont.resume(throwing: error) }
                })
                pump()
            }
        } onCancel: {
            cancelled.on = true
        }
    }

    private final class Flag: @unchecked Sendable { var on = false }

    private func pump() {
        guard !busy, !jobs.isEmpty else { return }
        busy = true
        let job = jobs.removeFirst()
        let started = Flag()
        let finish: () -> Void = { [weak self] in
            self?.model.action = nil
            self?.busy = false
            self?.pump()
        }
        model.action = { session in
            guard !started.on else { return }
            started.on = true
            await job.body(session)
            finish()
        }
        // 语言对和上一次一样时，配置要作废一下，translationTask 才会再跑
        if var same = model.configuration, same.source == job.source, same.target == job.target {
            same.invalidate()
            model.configuration = same
        } else {
            model.configuration = TranslationSession.Configuration(source: job.source, target: job.target)
        }
        // 视图不在窗口里之类的情况下 translationTask 不会来：等几秒就算失败，不让后面的一直排着
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard !started.on else { return }
            started.on = true
            Task { @MainActor in
                await job.body(nil)
                finish()
            }
        }
    }
}

#endif
