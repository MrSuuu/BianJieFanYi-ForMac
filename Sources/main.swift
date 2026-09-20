import SwiftUI
import Translation
import AppKit
import Vision
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation
import Carbon
import ServiceManagement
import ApplicationServices   // 选区浮窗：AXUIElement 等 Accessibility API

// 从「服务」菜单进来的文本，靠这个通知传到界面
extension Notification.Name {
    static let incomingText = Notification.Name("com.zegeyoudaoli.translator.incomingText")
}

/// 设置窗口的 id。
///
/// ⚠️ 为什么不用标准 `Settings {}` scene + `showSettingsWindow:`：
/// LSUIElement 模式下 App 没有自己的菜单栏，而那个动作是靠菜单栏里的「设置…」菜单项
/// 响应的 —— 响应者不存在，点了没反应（⌘, 同理失效）。
/// 所以设置改成普通具名窗口，用 openWindow(id:) 显式打开。
let settingsWindowID = "translator-settings"

/// 打开设置窗口并把它拉到最前。
/// 拿到窗口要 async 一小会儿：openWindow 是异步的，紧接着查 NSApp.windows 还查不到。
func openSettingsWindow(openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: settingsWindowID)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "设置" }?.makeKeyAndOrderFront(nil)
    }
}

/// 开机启动（macOS 13+ 的 SMAppService，替代老的 LaunchServices 登录项 API）
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            let msg = error.localizedDescription
            return "开机启动设置失败：\(msg)（SMAppService 要求 App 放在「应用程序」目录里）"
        }
    }
}

// MARK: - 语种判定

/// 统计汉字与拉丁字母的数量。
private func charCounts(_ text: String) -> (cjk: Int, latin: Int) {
    var cjk = 0
    var latin = 0
    for scalar in text.unicodeScalars {
        let v = scalar.value
        if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v) {
            cjk += 1
        } else if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
            latin += 1
        }
    }
    return (cjk, latin)
}

/// 是否中文主导。数汉字 vs 拉丁字母，谁多用谁；全无字母时按中文处理。
private func isChinese(_ text: String) -> Bool {
    let (cjk, latin) = charCounts(text)
    if cjk == 0 && latin == 0 { return true }
    return cjk > 0 && cjk >= latin
}

private func languageName(_ code: String) -> String {
    switch code {
    case "zh", "zh-Hans": return "中文"
    case "cht", "zh-Hant": return "中文繁体"
    case "yue": return "粤语"
    case "en": return "英文"
    case "jp", "ja": return "日文"
    case "kor", "ko": return "韩文"
    default: return code.uppercased()
    }
}

/// 剪贴板监听时机。三档：关闭 / 一直监听 / 仅在窗口置顶时。
///
/// 「仅置顶时」这一档的用意：平时不常驻轮询剪贴板（省电、也避免莫名的截图串进来），
/// 只有你主动把窗口钉在顶上、明确处于「边看边翻」的工作状态时才自动接管截图。
enum ClipboardWatchMode: String, CaseIterable, Identifiable {
    case off, always, pinnedOnly

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:        return "关闭"
        case .always:     return "一直监听"
        case .pinnedOnly: return "仅在窗口置顶时"
        }
    }
}

/// 配色主题。玻璃质感 + 可选强调色；设置里可实时切换。
enum AccentTheme: String, CaseIterable, Identifiable {
    case glass, teal, violet, amber, system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glass:  return "液态玻璃"
        case .teal:   return "青绿"
        case .violet: return "暗夜紫"
        case .amber:  return "暖橙"
        case .system: return "系统原色"
        }
    }

    /// 强调色：用于胶囊描边、字、以及窗口控件 tint
    var accent: NSColor {
        switch self {
        case .glass:  return NSColor(srgbRed: 0.20, green: 0.60, blue: 1.00, alpha: 1)
        case .teal:   return NSColor(srgbRed: 0.05, green: 0.78, blue: 0.66, alpha: 1)
        case .violet: return NSColor(srgbRed: 0.55, green: 0.38, blue: 0.96, alpha: 1)
        case .amber:  return NSColor(srgbRed: 1.00, green: 0.62, blue: 0.10, alpha: 1)
        case .system: return NSColor.controlAccentColor
        }
    }

    /// 叠在毛玻璃上的淡淡染色（很淡，保持通透）
    var tint: NSColor { accent.withAlphaComponent(0.08) }

    static var current: AccentTheme {
        AccentTheme(rawValue: UserDefaults.standard.string(forKey: "accentTheme") ?? "glass") ?? .glass
    }
}

/// 通透度换算：四个窗口各有一个 0…1 的滑块（0 = 最实，1 = 最透），
/// 统一换算成"毛玻璃材质透明度 + 垫层透明度"两个旋钮。
/// 为什么是两个旋钮：材质档位定"背景被磨得多厉害"，垫层定"背景能不能透出来"，
/// 只调一个都会出现"要么看不清字、要么看不出透"的问题。
enum Clearness {
    /// 毛玻璃材质透明度：最实 1.0 → 最透 0.45
    static func material(_ t: Double) -> Double { 1.0 - 0.55 * t }
    /// 底下垫的那层窗口底色：最实 maxBacking → 最透 0（各窗口厚度需求不同，所以 max 可配）
    static func backing(_ t: Double, max maxBacking: Double) -> Double { maxBacking * (1 - t) }
}

/// 界面外观。默认跟随系统（深浅自适应），也允许手动钉死。
/// 实现方式：直接把 NSApp.appearance 设上 —— 原生 AppKit 控件（毛玻璃、按钮）
/// 和 SwiftUI 里的语义色（.primary/.secondary/windowBackgroundColor）都会一起跟着变。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }
    /// nil = 不受控（= 跟随系统），交给 AppKit 自己跟着系统走
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "system") ?? .system
    }
    /// 生效。切换后需要通知自绘视图（胶囊的高光层）重画。
    @MainActor static func apply(_ mode: AppearanceMode) {
        NSApp.appearance = mode.nsAppearance
        EdgeDockController.shared.refreshAppearance()
    }
}

/// 目标语种。留空 = 自动（不是中文就译中文，是中文才译英文）。
enum TargetChoice: String, CaseIterable, Identifiable {
    case auto, zh, cht, yue, en, jp, kor

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "自动（中文 ⇄ 英文）"
        case .zh:   return "简体中文"
        case .cht:  return "繁体中文"
        case .yue:  return "粤语"
        case .en:   return "英文"
        case .jp:   return "日文"
        case .kor:  return "韩文"
        }
    }
    var baiduCode: String {
        switch self {
        case .zh: return "zh"
        case .cht: return "cht"
        case .yue: return "yue"
        case .en: return "en"
        case .jp: return "jp"
        case .kor: return "kor"
        case .auto: return ""
        }
    }
    var appleCode: String {
        switch self {
        case .zh: return "zh-Hans"
        case .cht: return "zh-Hant"
        case .yue: return "yue"
        case .en: return "en"
        case .jp: return "ja"
        case .kor: return "ko"
        case .auto: return ""
        }
    }
}

/// 翻译风格 —— 只有百度大模型支持（接口的 reference 字段）。
enum TranslateStyle: String, CaseIterable, Identifiable {
    case standard, free, colloquial, academic, concise
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard:   return "标准"
        case .free:       return "意译（更自然）"
        case .colloquial: return "口语化"
        case .academic:   return "学术正式"
        case .concise:    return "简洁"
        }
    }
    var instruction: String {
        switch self {
        case .standard:   return ""
        case .free:       return "采用意译，不要逐字直译，符合目标语言的表达习惯"
        case .colloquial: return "用自然口语化的方式翻译，像 native speaker 日常说话"
        case .academic:   return "使用正式、学术化的书面语翻译"
        case .concise:    return "翻译要简洁明了，去掉冗余表述"
        }
    }
}

// MARK: - OCR 换行修复

/// OCR 常把一句话硬折成多行，带着换行去翻译会把句子在半截切开。
/// 规则：上一行不以句末标点收尾就合并，句末标点才保留换行。
func mergeWrappedLines(_ text: String) -> String {
    let enders = ".!?。！？…;；:："
    let lines = text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard !lines.isEmpty else { return text }
    var out = ""
    for line in lines {
        if out.isEmpty {
            out = line
        } else if let last = out.last, enders.contains(last) {
            out += "\n" + line
        } else {
            out += " " + line
        }
    }
    return out
}

// MARK: - 百度大模型翻译

/// POST https://fanyi-api.baidu.com/ait/api/aiTextTranslate
/// Header: Authorization: Bearer <API Key>；Body: appid/from=auto/to/q/model_type
enum BaiduEngine {
    struct Failure: Error { let code: String; let message: String }
    struct Result { let text: String; let fromLanguage: String? }

    static func translate(_ text: String,
                          apiKey: String,
                          appid: String,
                          to: String,
                          style: String,
                          completion: @escaping (Swift.Result<Result, Failure>) -> Void) {
        guard let url = URL(string: "https://fanyi-api.baidu.com/ait/api/aiTextTranslate") else {
            completion(.failure(Failure(code: "url", message: "接口地址非法")))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "appid": appid,
            "from": "auto",
            "to": to,
            "q": text,
        ]
        if !style.isEmpty { body["reference"] = style }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(Failure(code: "network", message: error.localizedDescription)))
                    return
                }
                guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(Failure(code: "parse", message: "返回格式异常")))
                    return
                }
                if let code = obj["error_code"] as? String {
                    let msg = obj["error_msg"] as? String ?? ""
                    completion(.failure(Failure(code: code, message: "百度错误码 \(code) \(msg)\(hint(for: code))")))
                    return
                }
                let items = obj["trans_result"] as? [[String: Any]] ?? []
                let out = items.compactMap { $0["dst"] as? String }.joined(separator: "\n")
                let from = obj["from"] as? String
                if out.isEmpty {
                    completion(.failure(Failure(code: "empty", message: "没有返回译文")))
                } else {
                    completion(.success(Result(text: out, fromLanguage: from)))
                }
            }
        }.resume()
    }

    static func hint(for code: String) -> String {
        switch code {
        case "54001": return " —— API Key 或 APP ID 填错了吧"
        case "52003": return " —— APP ID 不对，或服务没开通"
        case "90107": return " —— 开发者认证还没通过，去「我的认证」看看"
        case "58002": return " —— 「大模型文本翻译」服务没开通"
        case "54003", "59004": return " —— 请求太频繁，歇一秒再试"
        case "58003": return " —— 这个 IP 今日被封，明天解封"
        default: return ""
        }
    }
}

// MARK: - 离线 OCR

enum OCR {
    static func recognize(_ image: NSImage, completion: @escaping (String) -> Void) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            DispatchQueue.main.async { completion("") }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            // recognitionLanguages 必须显式给：默认只认英文，不给中文就识别不出汉字
            for languages in [["zh-Hans", "zh-Hant", "en-US"], []] {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                if !languages.isEmpty { request.recognitionLanguages = languages }
                do { try handler.perform([request]) } catch { continue }
                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                DispatchQueue.main.async { completion(text) }
                return
            }
            DispatchQueue.main.async { completion("") }
        }
    }
}

// MARK: - 朗读

final class Speaker {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: isChinese(text) ? "zh-CN" : "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }
    func stop() { synth.stopSpeaking(at: .immediate) }
}

// MARK: - 历史记录

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    let source: String
    let translated: String
    let date: Date
}

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private let key = "history"
    private let limit = 100

    @Published var entries: [HistoryEntry] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = list
        }
    }

    func add(source: String, translated: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !translated.isEmpty else { return }
        // 完全一样的内容不重复记
        guard !entries.contains(where: { $0.source == trimmed && $0.translated == translated }) else { return }
        entries.insert(HistoryEntry(source: trimmed, translated: translated, date: Date()), at: 0)
        if entries.count > limit { entries = Array(entries.prefix(limit)) }
        save()
    }

    func clear() { entries = []; save() }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - 全局快捷键（Carbon，不需要辅助功能权限）

final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onFire: (() -> Void)?

    /// ⌥Space：optionKey(0x0800) + 空格键码 49
    func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let ptr = userData else { return noErr }
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(ptr).takeUnretainedValue()
            DispatchQueue.main.async { mgr.onFire?() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)

        let keyID = EventHotKeyID(signature: OSType(0x59494150), id: 1)
        RegisterEventHotKey(49, UInt32(optionKey), keyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }
}

// MARK: - 剪贴板截图监听

final class ClipboardWatcher {
    static let shared = ClipboardWatcher()
    private var timer: Timer?
    private var lastChange = -1
    var onImage: ((NSImage) -> Void)?

    func start() {
        stop()
        lastChange = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = NSPasteboard.general.changeCount
            guard now != self.lastChange else { return }
            self.lastChange = now
            // 只对「图」反应：我们自动复制译文时也会改动剪贴板，那是文本，不会误触发
            if let img = AppDelegate.imageFromClipboard() {
                DispatchQueue.main.async { self.onImage?(img) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }
}

// MARK: - AppDelegate：⌘V 拦截 / 服务菜单 / 快捷键

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// ⌘V 抓到图时的回调；返回 true 表示已消费
    static var handlePastedImage: ((NSImage) -> Bool)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 0) 外观：默认跟随系统（深浅自适应），也可以手动钉死浅色/深色
        AppearanceMode.apply(AppearanceMode.current)

        // 1) 拦截 ⌘V：截图进剪贴板是 NSImage，TextEditor 收到图只会当附件塞进去
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let image = AppDelegate.imageFromClipboard() else { return event }
            return AppDelegate.handlePastedImage?(image) == true ? nil : event
        }

        // 2) 系统「服务」菜单：选中文字 → 右键 → 用「便捷翻译」翻译
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // 3) 全局快捷键 ⌥Space
        HotKeyManager.shared.register()
        HotKeyManager.shared.onFire = { [weak self] in self?.bringUp() }

        // 4) 选区浮窗翻译（需在系统设置→隐私与安全性→辅助功能 授权后才会真正生效）
        SelectionPopupController.shared.startIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
    }

    static func imageFromClipboard() -> NSImage? {
        let board = NSPasteboard.general
        guard board.canReadObject(forClasses: [NSImage.self], options: nil) else { return nil }
        return board.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage
    }

    /// 把窗口拉到最前（快捷键 / 服务菜单都走这里）
    func bringUp() {
        if EdgeDockController.shared.handleSummon() { return }   // 贴边态下 ⌥Space = 展开/收起
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isMiniaturized }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Services
    @objc func translateText(_ pboard: NSPasteboard,
                             userData: String,
                             error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string) else { return }
        bringUp()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .incomingText, object: text)
        }
    }
}

// MARK: - 选区浮窗翻译（PopClip 式：在任意 App 里选中文字即浮出翻译，不切换界面）

/// 浮窗上展示/暂存的数据。SwiftUI 视图以 @ObservedObject 监听它，控制器也持有同一实例。
final class PopupTranslationModel: ObservableObject {
    @Published var selectedText: String = ""
    @Published var resultText: String = ""
    @Published var errorMsg: String?
    @Published var infoMsg: String?          // 中性提示（如"已复制到剪贴板"），不是错误但要说清楚
    @Published var styleHint: String?        // 「换个译法」时当前用的口吻
    @Published var detectedSource: String?
    /// 每换一次选区就 +1，浮窗视图靠 .task(id:) 监听它 → 自动开翻，不用手点
    @Published var autoTranslateToken: Int = 0
}

/// 浮窗面板：无边框 + nonactivating，显示在其他 App 之上但不抢焦点（当前软件保持前台）。
final class SelectionPanel: NSPanel {
    var onMouseInsideChange: ((Bool) -> Void)?
    override init(contentRect: NSRect, styleMask style: StyleMask, backing: NSWindow.BackingStoreType, defer d: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: backing, defer: d)
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isFloatingPanel = true
        self.hasShadow = true           // 留一点投影把浮窗和底下的内容分开，否则字会和背景糊在一起
        self.backgroundColor = .clear
        self.isOpaque = false
        self.ignoresMouseEvents = false
    }
    override func mouseEntered(with event: NSEvent) { onMouseInsideChange?(true) }
    override func mouseExited(with event: NSEvent) { onMouseInsideChange?(false) }
}

/// 浮窗里的 SwiftUI 视图：把选中文字喂给已验证的翻译通道（Baidu 在线 / Apple 离线）。
struct SelectionPopupView: View {
    @ObservedObject var model: PopupTranslationModel
    @AppStorage("popupClearness") private var clearness = 0.5   // 设置页那个滑块，实时生效
    @State private var config: TranslationSession.Configuration?
    @State private var sessionGeneration = 0
    @State private var isBusy = false
    @State private var styleCycle = 0            // 「换个译法」点到第几种（每点一次换一种口吻）

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "character.book.closed")
                    .foregroundStyle(Color(nsColor: AccentTheme.current.accent))
                Text("选区翻译").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { SelectionPopupController.shared.dismissPopup() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }

            Text(model.selectedText)
                .font(.system(size: 12))
                .lineLimit(3)
                .foregroundStyle(.primary)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .secondaryLabelColor).opacity(0.08)))

            HStack(spacing: 10) {
                Button { translate() } label: {
                    Text(isBusy ? "翻译中…" : (model.resultText.isEmpty ? "翻译" : "换个译法"))
                }
                .disabled(isBusy || model.selectedText.isEmpty)
                Button { copyResult() } label: { Text("复制译文") }
                    .disabled(model.resultText.isEmpty)
                Spacer()
            }.controlSize(.small)

            Divider().opacity(0.6)

            if let err = model.errorMsg {
                Text(err).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3)
            }
            if let info = model.infoMsg {
                Text(info).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            }
            ScrollView {
                Text(model.resultText.isEmpty ? (isBusy ? "翻译中…" : "…") : model.resultText)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }.frame(maxHeight: 120)

            if let src = model.detectedSource {
                Text("检测语言：\(src)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let hint = model.styleHint {
                Text("本次译法：\(hint)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: 320)
        // 通透度由「设置 → 窗口通透度 → 选区浮窗」那个滑块实时控制，不用改代码
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial.opacity(Clearness.material(clearness))))
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(Clearness.backing(clearness, max: 0.12))))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .tint(Color(nsColor: AccentTheme.current.accent))
        // 复用主窗口验证过的离线翻译通道（代际号一变就重建修饰符，绕过它的去重）
        .background(
            Color.clear.frame(width: 1, height: 1)
                .translationTask(config) { session in await runTranslation(session) }
                .id(sessionGeneration)
        )
        // 每次换选区（token 变化）自动开翻；.task(id:) 在首次出现时也会跑一次
        .task(id: model.autoTranslateToken) {
            guard model.autoTranslateToken > 0 else { return }
            translate()
        }
    }

    /// rephrasing = true 表示用户点了「换个译法」：
    /// 同一段原文、同一套引擎，参数不变的话大模型输出基本是稳定的（这就是"重新翻一遍还是一样口吻"的原因），
    /// 所以换个译法不能靠"再翻一次"，得真的改指令 —— 依次轮换 标准/意译/口语化/学术/简洁。
    private func translate(rephrasing: Bool = false) {
        let text = model.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.resultText = ""; model.errorMsg = nil; model.detectedSource = nil
        isBusy = true

        let engine = UserDefaults.standard.string(forKey: "engine") ?? "auto"
        let appid = UserDefaults.standard.string(forKey: "baiduAppID") ?? ""
        let key = UserDefaults.standard.string(forKey: "baiduApiKey") ?? ""
        let target = TargetChoice(rawValue: UserDefaults.standard.string(forKey: "targetChoice") ?? "auto") ?? .auto
        let baseStyle = TranslateStyle(rawValue: UserDefaults.standard.string(forKey: "style") ?? "standard") ?? .standard

        let style: TranslateStyle
        if rephrasing {
            styleCycle += 1
            let order: [TranslateStyle] = [.standard, .free, .colloquial, .academic, .concise]
            let start = order.firstIndex(of: baseStyle) ?? 0
            style = order[(start + styleCycle) % order.count]
            model.styleHint = style.label
        } else {
            styleCycle = 0
            style = baseStyle
            model.styleHint = nil
        }

        let (appleTarget, baiduTarget) = resolvePopupTarget(target: target, text: text)
        let sourceLang = resolvePopupSource(target: target, text: text)
        let useBaidu = !key.isEmpty && !appid.isEmpty && engine != "offline"

        if useBaidu {
            BaiduEngine.translate(text, apiKey: key, appid: appid, to: baiduTarget, style: style.instruction) { res in
                isBusy = false
                switch res {
                case .success(let out):
                    model.resultText = out.text
                    model.detectedSource = out.fromLanguage.map(languageName)
                    HistoryStore.shared.add(source: text, translated: out.text)
                case .failure(let f):
                    // 离线引擎没有 style 概念，换译法只对在线（大模型）路径有效
                    model.errorMsg = "在线失败（\(f.message)），改用离线"
                    model.styleHint = nil
                    self.startApple(text: text, source: sourceLang, target: appleTarget)
                }
            }
        } else {
            if rephrasing { model.styleHint = "离线引擎不支持换译法，已按原设置重翻" }
            startApple(text: text, source: sourceLang, target: appleTarget)
        }
    }

    private func startApple(text: String, source: Locale.Language?, target: Locale.Language) {
        sessionGeneration += 1
        config = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            config = TranslationSession.Configuration(source: source, target: target)
        }
    }

    @MainActor private func runTranslation(_ session: TranslationSession) async {
        let text = model.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try await session.prepareTranslation()
            let resp = try await session.translate(text)
            model.resultText = resp.targetText
            if let lang = resp.sourceLanguage.languageCode { model.detectedSource = languageName(lang.identifier) }
            HistoryStore.shared.add(source: text, translated: resp.targetText)
        } catch {
            model.errorMsg = "离线翻译失败：\(error.localizedDescription)　·　首次使用需联网下载语言包"
        }
        isBusy = false
    }

    private func copyResult() {
        guard !model.resultText.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(model.resultText, forType: .string)
    }
}

private func resolvePopupTarget(target: TargetChoice, text: String) -> (Locale.Language, String) {
    if target == .auto {
        return isChinese(text)
            ? (Locale.Language(identifier: "en"), "en")
            : (Locale.Language(identifier: "zh-Hans"), "zh")
    }
    return (Locale.Language(identifier: target.appleCode), target.baiduCode)
}
private func resolvePopupSource(target: TargetChoice, text: String) -> Locale.Language? {
    if target != .auto { return nil }
    if isChinese(text) { return Locale.Language(identifier: "zh-Hans") }
    let (cjk, latin) = charCounts(text)
    if cjk == 0 && latin > 0 { return Locale.Language(identifier: "en") }
    return nil
}

/// 后台监测器：轮询前台 App 的 Accessibility 选区，命中即浮出面板。
final class SelectionPopupController {
    static let shared = SelectionPopupController()
    let model = PopupTranslationModel()
    private var timer: Timer?
    private var panel: SelectionPanel?
    private var hosting: NSHostingController<SelectionPopupView>?
    private var lastText: String = ""
    private var lastElement: AXUIElement?
    private var mouseInside = false
    private var manualAccessPids: Set<Int32> = []   // 已打过无障碍提示的进程
    private var axHintResult = ""                   // 设置无障碍提示的返回码（诊断用）
    private var missStreak = 0                      // 连续"有选字动作但找不到选区"的次数
    private var probeAt: [String: Date] = [:]       // 诊断导出：每个 App 各自节流（别互相覆盖）
    private var emptySince: Date?                   // 选区为空的起始时刻（防"闪断"用）
    private var suppressAt = Date.distantPast       // 抑制是什么时候生效的
    private var pendingText = ""                    // 防抖：正在观察中的选区内容
    private var pendingSince = Date.distantPast
    private var suppressText = ""                   // 被用户手动关掉的选区内容（不再弹）
    private var suppressBundle = ""                 // ↑ 这段文字是在哪个 App 里被关掉的
    private var lastFrontBundle = ""                // 用于判断"换了 App"
    private let settleDelay: TimeInterval = 0.30    // 选区内容静止多久才算"选完了"
    private let panelW: CGFloat = 320, panelH: CGFloat = 230

    // AX 属性名用字面量 CFString，避开 SDK 里这些常量有时被桥成 String / Unmanaged 的不一致
    private let kFocusedUIElement = "AXFocusedUIElement" as CFString
    private let kSelectedText = "AXSelectedText" as CFString
    private let kTrustedPrompt = "AXTrustedCheckOptionPrompt" as CFString
    private let kAXPos = "AXPosition" as CFString
    private let kAXSz = "AXSize" as CFString
    private let kAXParent = "AXParent" as CFString
    private let kAXChildren = "AXChildren" as CFString
    private let kAXRole = "AXRole" as CFString
    private let kAXFocusedWindow = "AXFocusedWindow" as CFString
    private let kAXEditableAncestor = "AXEditableAncestor" as CFString
    private let kAXSelectedTextRange = "AXSelectedTextRange" as CFString
    private let kAXStringForRange = "AXStringForRange" as CFString               // 参数化属性
    private let kAXSelectedTextMarkerRange = "AXSelectedTextMarkerRange" as CFString
    private let kAXStringForTextMarkerRange = "AXStringForTextMarkerRange" as CFString
    private let kAXAttributedStringForTextMarkerRange = "AXAttributedStringForTextMarkerRange" as CFString
    private let kAXManualAccessibility = "AXManualAccessibility" as CFString      // Chromium 系认这个
    private let kAXEnhancedUserInterface = "AXEnhancedUserInterface" as CFString  // WebKit/Safari 认这个

    var hasPermission: Bool { AXIsProcessTrusted() }

    func startIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "selectionPopup") else { stop(); return }
        // 开关是开的但没拿到信任（例如换了签名/重装后授权作废）→ 主动弹一次系统授权框。
        // 不弹的话会静默失败，用户只会觉得"浮窗没出来"。
        if !AXIsProcessTrusted() { requestPermission() }
        start()
    }

    func start() {
        stop()
        installGestureMonitors()   // 记录"用户有没有主动操作"，用来挡住乱弹
        // 0.2s 轮询：配合 0.30s 的选区静止判定，"松手后约 0.4s 出浮窗"
        timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        removeGestureMonitors()
        hidePopup()
    }

    /// 弹系统授权框（首次开启时调用）。
    func requestPermission() {
        let opts = [kTrustedPrompt: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func poll() {
        guard let front = NSWorkspace.shared.frontmostApplication else { hidePopup(reason: "拿不到前台 App"); return }
        // 自己的窗口不监听（那边用主界面自己的逻辑）
        if front.bundleIdentifier == "com.zegeyoudaoli.translator" { hidePopup(reason: "前台是自己"); return }
        debugLog("front", front.bundleIdentifier ?? "?")
        // 换 App = 换了上下文：解除"这段文字被手动关过"的抑制，否则跨 App 会被一直拉黑
        // 注意：这里**不能**在换 App 时清掉"已被手动关掉"的记录。
        // 之前的写法就是这么干的，结果是：在 A 里点掉浮窗 → 切到 B → 切回 A，
        // 选区还在、又弹一次 —— 用户视角就是"关不掉、一直弹"。
        // 抑制按 (App, 文字) 绑定，换 App 各自保留；只有选区真的消失才清空。
        let bid = front.bundleIdentifier ?? "?"
        lastFrontBundle = bid
        let trusted = AXIsProcessTrusted()
        debugLog("trust", trusted ? "yes" : "no")
        guard trusted else { return }

        // 浏览器默认**不构建完整无障碍树**（省性能），必须由辅助功能客户端先"打个招呼"，
        // 它才会把网页内容（含选区）暴露出来。而且 Chromium 和 WebKit 认的属性名不一样：
        //   · Chromium/Electron（Discord、Chrome、Edge）→ AXManualAccessibility
        //   · WebKit（Safari）→ AXEnhancedUserInterface
        // 两个都设（对方不认的属性会被忽略），每个进程一次即可。
        // 之前只设了 Chromium 那个，所以 Discord 能用而 Safari 一直取不到选区。
        let pid = front.processIdentifier
        if !manualAccessPids.contains(pid) {
            let appElem = AXUIElementCreateApplication(pid)
            // 超时很关键：默认 AX 调用会等对方 App 响应，对方忙/卡时能拖住我们主线程好几秒，
            // 表现就是浮窗"时灵时不灵"甚至整个 app 卡住。0.5s 足够正常响应。
            AXUIElementSetMessagingTimeout(appElem, 0.5)
            let r1 = AXUIElementSetAttributeValue(appElem, kAXManualAccessibility, kCFBooleanTrue)
            let r2 = AXUIElementSetAttributeValue(appElem, kAXEnhancedUserInterface, kCFBooleanTrue)
            axHintResult = "Manual=\(r1.rawValue) Enhanced=\(r2.rawValue)"
            manualAccessPids.insert(pid)
        }

        let systemWide = AXUIElementCreateSystemWide()

        // ①【防乱弹】必须是"用户主动做的选区"才弹。
        //    光看 AXSelectedText 非空是不够的：很多情况不是用户选的 —— 点地址栏时
        //    系统自动全选、输入法组字时把候选标成选中、网页加载完自己设个选区……
        //    这些都算"没人要求翻译"，弹出来就是骚扰。
        if !userGestureRecently {
            debugLog("noGesture", "跳过（非用户主动操作）")
            resetPending(); maybeHide(); return
        }

        // ②【含 Safari】多来源找选区：不同 App 把 AXSelectedText 挂在不同层级上。
        //    Chromium 挂在焦点元素上；WebKit/Safari 常挂在焦点元素的祖先（AXWebArea），
        //    所以只查焦点元素的话，Safari 里选中网页文字永远取不到 → 表现为"不生效"。
        let found = readSelection(pid: pid, systemWide: systemWide, bundleID: bid)
        debugLog("selFrom", found.source.rawValue)
        if !found.text.isEmpty { missStreak = 0 }
        guard let elem = found.element, !found.text.isEmpty else {
            debugLog("selErr", found.errorCode)
            resetPending(); maybeHide(); return
        }

        // ③【防乱弹】选区落在可编辑控件里（地址栏、聊天输入框、搜索框）→ 不弹。
        //    这些地方系统/输入法经常会"帮你选中"，而且用户在那里通常是要打字不是要翻译。
        if isEditable(elem), !UserDefaults.standard.bool(forKey: "popupInEditable") {
            debugLog("skipEditable", "跳过（选区在可编辑控件内）")
            resetPending(); maybeHide(); return
        }

        let trimmed = found.text
        if trimmed.isEmpty {
            // ⚠️ 选区"空"不一定是真没选 —— 浏览器重排无障碍树时经常闪断一拍。
            // 之前的代码见到空就直接收窗、清记录，于是出现两个毛病：
            //   · 浮窗刚弹出来一秒就自己消失（闪断把它收掉了）
            //   · 切 App 回来后抑制被顺手清掉 → 又弹
            // 现在统一加"持续时间"判定：闪断（<1.2s）不当事，真消失才处理。
            resetPending()
            let now = Date()
            let since = emptySince ?? now
            emptySince = since
            let emptyFor = now.timeIntervalSince(since)

            // 真·取消选中（持续 2.5s 才算）→ 清掉抑制，让以后重新选还能弹
            if emptyFor > 2.5, bid == suppressBundle { suppressText = ""; suppressBundle = "" }
            // 持续 1.2s 才算选区真的没了 → 允许下一次弹同一段
            if emptyFor > 1.2 {
                lastText = ""
                if !mouseInside { hidePopup(reason: "选区消失(持续\(String(format: "%.1f", emptyFor))s)") }
            }
            return
        }
        emptySince = nil
        if trimmed == lastText { return }       // 同一选区已经弹过了
        // 用户"重新选了一次"（拖动/双击）→ 解除抑制。
        // 这条是泽哥要的："点掉之后我再手动重选同一段，应该还能弹"。
        // 关键在"拖动/双击"才算重新选，单击（比如切窗口点一下）不算。
        if !suppressText.isEmpty, !suppressBundle.isEmpty,
           lastSelectGesture > suppressAt.addingTimeInterval(0.5) {
            suppressText = ""; suppressBundle = ""
        }
        // 用户手动关掉过这段 → 不再弹（哪怕它还选着）。
        // 比对时连 App 一起看：在 Discord 关掉的文字，到别的 App 里选中照样该弹。
        if trimmed == suppressText, bid == suppressBundle {
            debugLog("suppressed", "\(trimmed.count) 字符")
            return
        }

        // ④ 防抖：拖选过程中选区一直在变，只有内容连续 settleDelay 秒没变（说明松手了）
        //    才弹窗，避免"还没选完浮窗就跳出来"
        let now = Date()
        if trimmed != pendingText {
            pendingText = trimmed
            pendingSince = now
            debugLog("pending", "\(trimmed.count) 字符")
            return
        }
        guard now.timeIntervalSince(pendingSince) >= settleDelay else { return }

        debugLog("selected", "\(trimmed.count) 字符")
        lastText = trimmed
        lastElement = elem
        // 锚点：优先用选区元素的屏幕矩形，拿不到（Electron 常给整页大矩形）退回鼠标位置
        showPopup(text: trimmed, anchor: selectionAnchor(for: elem))
    }

    // MARK: 选区读取（多来源回退）

    private struct Selection {
        var text: String = ""
        var element: AXUIElement?
        var source: Source = .none
        var errorCode: String = ""
        enum Source: String { case systemFocus, appFocus, parent, descent, none }
    }

    private func readSelection(pid: pid_t, systemWide: AXUIElement, bundleID: String) -> Selection {
        let systemFocused = focusedElement(of: systemWide)
        let appFocused = focusedElement(of: AXUIElementCreateApplication(pid))

        // 1) 焦点元素本身（Chromium、原生 App 走这条）
        if let e = systemFocused, let t = selectedText(of: e, webKitRange: true) { return Selection(text: t, element: e, source: .systemFocus) }
        // 2) App 级焦点元素：有些 App 只在 application 元素上填 AXFocusedUIElement
        if let e = appFocused, let t = selectedText(of: e, webKitRange: true) { return Selection(text: t, element: e, source: .appFocus) }
        // 3) 沿父链往上找（**Safari 走这条**：选区挂在 AXWebArea 上，而 WebArea 是焦点元素的祖先）
        if let start = systemFocused ?? appFocused {
            var cur: AXUIElement? = start
            for _ in 0..<8 {
                guard let c = cur, let p = attribute(c, kAXParent) as! AXUIElement? else { break }
                if let t = selectedText(of: p, webKitRange: true) { return Selection(text: t, element: p, source: .parent) }
                cur = p
            }
        }
        // 4) 兜底：在焦点窗口里做"有预算的"广度搜索。
        //    AX 调用是跨进程 IPC，不能随便全树扫，所以限制预算（节点数 + 间隔）。
        var roots: [AXUIElement] = []
        if let e = systemFocused { roots.append(e) }
        if let e = appFocused { roots.append(e) }
        if let w = attribute(AXUIElementCreateApplication(pid), kAXFocusedWindow) as! AXUIElement? { roots.append(w) }
        if let hit = descentSearch(roots: roots) { return Selection(text: hit.0, element: hit.1, source: .descent) }
        // 一个都没找到 → 把诊断信息记下来，方便定位是哪类 App 不配合：
        //   focusRoles = 焦点元素角色
        //   rangeInfo  = 选区范围读不读得到、有多长（区分"树没建起来" vs "取字断掉"）
        debugLog("focusRoles", "system=\(role(of: systemFocused)) app=\(role(of: appFocused))")
        if let e = systemFocused ?? appFocused {
            debugLog("rangeInfo", describeSelectionRange(of: e))
        }
        // 用户明明做了选区动作、却连续多次都找不到 → 说明这个 App 的读法我没吃准，
        // 直接把它的无障碍树导出来（泽哥只需在 Safari 里选一次字，文件自动出现）
        // 只统计"用户刚做了选字动作（拖动/双击）之后"的失败，
        // 否则"压根没选东西"也会被算成失败，白白导出报告（上一版就被 WorkBuddy 覆盖了 Safari 的）
        missStreak += 1
        let selectGestureFresh = Date().timeIntervalSince(lastSelectGesture) < 2.5
        if missStreak >= 6, selectGestureFresh,
           Date().timeIntervalSince(probeAt[bundleID] ?? .distantPast) > 30 {
            probeAt[bundleID] = Date()
            dumpAXProbe(pid: pid, bundleID: bundleID, systemFocused: systemFocused, appFocused: appFocused)
        }
        return Selection(errorCode: "未找到选区")
    }

    private func role(of e: AXUIElement?) -> String {
        guard let e, let r = attribute(e, kAXRole) as? String else { return "无" }
        return r
    }

    private func focusedElement(of elem: AXUIElement) -> AXUIElement? {
        attribute(elem, kFocusedUIElement) as! AXUIElement?
    }

    private func attribute(_ e: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name, &ref) == .success ? ref : nil
    }

    /// 该元素的选区文本；没选到东西一律返回 nil，让调用方继续往上/往深找。
    ///
    /// 两条读法，缺一不可：
    ///  ① 直接读 `AXSelectedText` —— Chromium/原生 App 走这条，一次调用就拿到
    ///  ② **WebKit/Safari 这条属性是空的**（实测：整棵 AXWebArea 子树 160 个节点全没有），
    ///     得先读 `AXSelectedTextRange` 拿到选区范围，再用参数化属性 `AXStringForRange`
    ///     把那段文字取出来 —— VoiceOver 走的就是这条路。
    private func selectedText(of e: AXUIElement, webKitRange: Bool = false) -> String? {
        if let raw = attribute(e, kSelectedText) as? String {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        guard webKitRange else { return nil }
        // ② 常规 WebKit 路线：选区范围 → 参数化取字
        if let t = textForSelectedRange(of: e) { return t }
        // ③ 兜底：文本标记范围（VoiceOver 那套 API）。
        //    Safari/WebKit 有可能只暴露这个而不暴露 AXSelectedTextRange，
        //    多试一条成本很低，但能救回一整个浏览器。
        return textForSelectedMarkerRange(of: e)
    }

    /// WebKit/Safari 的另一条路：`AXSelectedTextMarkerRange` + 参数化取字
    private func textForSelectedMarkerRange(of e: AXUIElement) -> String? {
        guard let marker = attribute(e, kAXSelectedTextMarkerRange) else { return nil }
        for attr in [kAXStringForTextMarkerRange, kAXAttributedStringForTextMarkerRange] {
            var out: CFTypeRef?
            let err = AXUIElementCopyParameterizedAttributeValue(e, attr, marker, &out)
            guard err == .success else {
                debugLog("markerFail", "err=\(err.rawValue)")
                continue
            }
            let str = (out as? String) ?? (out as? NSAttributedString)?.string
            if let str {
                let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    /// 把一个 App 的无障碍树关键信息导出到 /tmp/yi-axprobe.txt。
    /// 目的：遇到"读不到选区"的 App（如 Safari/WebKit）时，别靠猜 ——
    /// 直接看它的焦点元素暴露了哪些属性、谁身上有选区，才能对着改。
    private func dumpAXProbe(pid: pid_t, bundleID: String, systemFocused: AXUIElement?, appFocused: AXUIElement?) {
        var out = "=== 「便捷翻译」选区诊断 ===\n"
        out += "时间: \(Date())\n"
        out += "前端 App: \(bundleID) (pid \(pid))\n"
        out += "无障碍提示设置返回码: \(axHintResult)\n\n"

        out += "[系统级焦点元素]\n" + describeElement(systemFocused)
        out += "\n[应用级焦点元素]\n" + describeElement(appFocused)

        out += "\n[父链（往上 8 层）]\n"
        var cur: AXUIElement? = systemFocused ?? appFocused
        for i in 1...8 {
            guard let c = cur, let p = attribute(c, kAXParent) as! AXUIElement? else { break }
            out += "  ↑\(i) \(briefElement(p))\n"
            cur = p
        }

        out += "\n[子树扫描：谁身上有选区（限 250 节点 / 8 层 / 每节点最多 30 子）]\n"
        var visited = 0
        for root in [systemFocused, appFocused].compactMap({ $0 }) {
            var queue: [(AXUIElement, Int)] = [(root, 0)]
            while let (node, depth) = queue.first, visited < 250 {
                queue.removeFirst(); visited += 1
                out += "  \(briefElement(node))\n"
                if depth < 8, let kids = attribute(node, kAXChildren) as? [AXUIElement] {
                    queue.append(contentsOf: kids.prefix(30).map { ($0, depth + 1) })
                }
            }
        }
        out += "\n共访问 \(visited) 个节点\n"

        // 两份：一份全局最新的（方便直接读），一份按 App 归档（避免被别的 App 覆盖）
        let safeName = bundleID.replacingOccurrences(of: "/", with: "_")
        try? out.write(toFile: "/tmp/yi-axprobe.txt", atomically: true, encoding: .utf8)
        try? out.write(toFile: "/tmp/yi-axprobe-\(safeName).txt", atomically: true, encoding: .utf8)
        debugLog("probe", "已导出诊断（\(visited) 节点）→ /tmp/yi-axprobe-\(safeName).txt")
    }

    /// 详细描述：角色 + 暴露的全部属性名 + 选区的三种读法结果（诊断的核心信息）
    private func describeElement(_ e: AXUIElement?) -> String {
        guard let e else { return "  （拿不到）\n" }
        var out = "  角色: \(role(of: e))\n"
        var names: CFArray?
        if AXUIElementCopyAttributeNames(e, &names) == .success, let list = names as? [String] {
            out += "  属性(\(list.count)): \(list.joined(separator: ", "))\n"
            out += "  含 AXSelectedText: \(list.contains("AXSelectedText"))"
            out += " / AXSelectedTextRange: \(list.contains("AXSelectedTextRange"))"
            out += " / AXStringForRange: \(list.contains("AXStringForRange"))\n"
        } else {
            out += "  属性: 读不到\n"
        }
        out += "  " + selectionProbe(of: e) + "\n"
        return out
    }

    private func briefElement(_ e: AXUIElement) -> String {
        "角色=\(role(of: e))  " + selectionProbe(of: e)
    }

    /// 三种读法各试一次，报结果（不返回文字，只报"有没有"）
    private func selectionProbe(of e: AXUIElement) -> String {
        var parts: [String] = []
        if let t = attribute(e, kSelectedText) as? String {
            parts.append("AXSelectedText(\(t.count)字)")
        } else { parts.append("AXSelectedText=无") }

        var rangeRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(e, kAXSelectedTextRange, &rangeRef)
        if err == .success, let v = rangeRef as! AXValue? {
            var r = CFRange(location: 0, length: 0)
            parts.append(AXValueGetValue(v, .cfRange, &r) ? "Range(len=\(r.length))" : "Range(解析失败)")
        } else { parts.append("Range(err=\(err.rawValue))") }
        return parts.joined(separator: " ")
    }

    /// 只读诊断：选区范围有没有、多长（不取字，避免污染日志）
    private func describeSelectionRange(of e: AXUIElement) -> String {
        var rangeRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(e, kAXSelectedTextRange, &rangeRef)
        guard err == .success, let v = rangeRef as! AXValue? else { return "读不到(err=\(err.rawValue))" }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(v, .cfRange, &range) else { return "AXValue 解析失败" }
        return "length=\(range.length)"
    }

    /// WebKit 专用：选区范围 → 参数化取字
    private func textForSelectedRange(of e: AXUIElement) -> String? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXSelectedTextRange, &rangeRef) == .success,
              let v = rangeRef as! AXValue? else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(v, .cfRange, &range), range.length > 0 else { return nil }

        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRange, v, &out)
        guard err == .success, let str = out as? String else {
            // 有选区范围却取不出文字 → 记下来，方便定位是哪一步断的
            debugLog("rangeFail", "err=\(err.rawValue)")
            return nil
        }
        let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private var lastDescent = Date.distantPast
    private let descentInterval: TimeInterval = 1.0      // 兜底搜索最小间隔，防止每 0.2s 扫一次树
    private let descentNodeBudget = 80                   // 单次最多访问多少个节点（AX 是跨进程 IPC，省着用）
    private let descentGestureWindow: TimeInterval = 2.0 // 只在"刚有用户操作"这段时间内才值得扫树

    /// 在若干"根"的子树里找选区。**从焦点元素开始**很关键：
    /// 浏览器把焦点元素报成 AXWebArea（整页），选区就在它的子树里；
    /// 若从窗口开始扫，预算会先被工具栏/侧栏/标签栏吃掉，等不到内容区就用光了。
    private func descentSearch(roots: [AXUIElement]) -> (String, AXUIElement)? {
        let now = Date()
        // 没人操作的时候扫树纯属浪费对方 App 的 CPU 和 IPC —— 这一步很贵，
        // 而且会把我们自己的主线程占住（AX 调用是同步的），表现出来就是"浮窗时灵时不灵"。
        guard now.timeIntervalSince(lastGesture) < descentGestureWindow else { return nil }
        guard now.timeIntervalSince(lastDescent) >= descentInterval else { return nil }
        lastDescent = now

        var visited = 0
        for root in roots {
            var queue: [(AXUIElement, Int)] = [(root, 0)]
            while let (node, depth) = queue.first, visited < descentNodeBudget {
                queue.removeFirst()
                visited += 1
                if let t = selectedText(of: node, webKitRange: true) { return (t, node) }
                if depth < descentMaxDepth, let kids = attribute(node, kAXChildren) as? [AXUIElement] {
                    queue.append(contentsOf: kids.prefix(20).map { ($0, depth + 1) })
                }
            }
            if visited >= descentNodeBudget { break }
        }
        debugLog("descent", "扫了 \(visited) 个节点没找到选区")
        return nil
    }

    private let descentMaxDepth = 6       // 网页 DOM 很深，但选区不会埋太深，6 层够用

    // MARK: 用户主动操作检测

    private var lastGesture = Date.distantPast
    private var lastSelectGesture = Date.distantPast   // 明确的"选字动作"：拖动 或 双击
    private var mouseDownAt = Date.distantPast
    private var mouseDownPoint = NSPoint.zero
    private var lastClickUp = Date.distantPast
    private var modifierHeld = false
    private let gestureWindow: TimeInterval = 1.6
    private var gestureMonitors: [Any] = []

    /// "最近有用户主动操作"：鼠标按/松过，或者刚按过/正按着 Shift/⌘/⌥。
    /// 后者是为了键盘选区（Shift+方向键、⌘A）：按住期间算，**松开那一刻也算一次**，
    /// 否则松开 Shift 后闸门立刻关上，键盘选中的文字反而弹不出来。
    private var userGestureRecently: Bool {
        modifierHeld || Date().timeIntervalSince(lastGesture) < gestureWindow
    }

    /// 只监听"有没有操作"，不记录任何内容：
    /// · 鼠标按下/松开 → 记时间戳
    /// · 修饰键状态变化（flagsChanged）→ 记"是否按着修饰键"
    /// 特意**不监听 keyDown**：那会把用户敲的每个字都过一遍我们的进程，
    /// 既没必要（记 Shift 状态就够判断"是不是在键盘选字"）也不体面。
    private func installGestureMonitors() {
        guard gestureMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .flagsChanged]
        // leftMouseDown 用来记录"按下点"，配合 up 判断这是拖动还是单击
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return }
            if event.type == .flagsChanged {
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let held = !mods.intersection([.shift, .command, .option, .control]).isEmpty
                self.modifierHeld = held
                self.lastGesture = Date()      // 按下和松开都算一次操作
            } else if event.type == .leftMouseDown {
                self.mouseDownAt = Date()
                self.mouseDownPoint = NSEvent.mouseLocation
                self.lastGesture = Date()
            } else if event.type == .leftMouseUp {
                let moved = hypot(NSEvent.mouseLocation.x - self.mouseDownPoint.x,
                                  NSEvent.mouseLocation.y - self.mouseDownPoint.y) > 4
                let isDouble = Date().timeIntervalSince(self.lastClickUp) < 0.45
                self.lastClickUp = Date()
                self.lastGesture = Date()
                // 只有"拖动"和"双击"才算用户在**选字**；单击只是点点界面/切换窗口，
                // 不能拿它当作"重新选了一遍"（否则切 App 点一下就又把抑制解除了）
                if moved || isDouble { self.lastSelectGesture = Date() }
            } else {
                self.lastGesture = Date()
            }
        }) {
            gestureMonitors.append(m)
        }
    }

    private func removeGestureMonitors() {
        gestureMonitors.forEach { NSEvent.removeMonitor($0) }
        gestureMonitors.removeAll()
        modifierHeld = false
    }

    /// 选区所在元素是不是"可编辑控件"（地址栏/输入框/搜索框/聊天框）。
    /// 看的是**提供选区的那个元素**，不是"当前焦点是谁" —— 这样不会误伤
    /// "Discord 里选中一条消息"（那种情况选区在静态文本上，输入框只是碰巧还持有焦点）。
    private func isEditable(_ e: AXUIElement) -> Bool {
        if let role = attribute(e, kAXRole) as? String,
           editableRoles.contains(role) { return true }
        // Chromium 专用标记：元素自身不可编辑、但有可编辑祖先（网页表单里常见）
        if attribute(e, kAXEditableAncestor) != nil { return true }
        return false
    }

    private let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    private func resetPending() { pendingText = ""; pendingSince = .distantPast }

    /// 选区锚点（NSWindow 坐标系，原点左下）。取不到"合理大小"的矩形就返回 nil。
    private func selectionAnchor(for elem: AXUIElement) -> NSRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, kAXPos, &posRef) == .success,
              AXUIElementCopyAttributeValue(elem, kAXSz, &sizeRef) == .success,
              let pv = posRef as! AXValue?, let sv = sizeRef as! AXValue? else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pv, .cgPoint, &pt)
        AXValueGetValue(sv, .cgSize, &sz)
        // 整页/整窗这种大矩形锚了等于没锚，还不如跟鼠标走
        guard sz.width > 0, sz.height > 0, sz.width < 1400, sz.height < 620 else { return nil }
        // AX 用主屏左上原点，转 NSWindow 坐标要翻 y
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: pt.x, y: screenH - (pt.y + sz.height), width: sz.width, height: sz.height)
    }

    /// 调试日志：只在「某一项状态」变化时追加一行，用来定位"浮窗没出来"卡在哪一环。
    private var lastLogState: [String: String] = [:]
    private func debugLog(_ state: String, _ detail: String) {
        if lastLogState[state] == detail { return }
        lastLogState[state] = detail
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let line = "[\(df.string(from: Date()))] \(state) \(detail)\n"
        let path = "/tmp/yi-selection.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func maybeHide() {
        if !mouseInside { hidePopup(reason: "没读到选区/焦点") }
    }

    func showPopup(text: String, anchor: NSRect?) {
        model.selectedText = text
        model.resultText = ""
        model.errorMsg = nil
        model.infoMsg = nil
        model.styleHint = nil
        model.detectedSource = nil
        if panel == nil { buildPanel() }
        guard let panel else { return }
        panel.setFrame(popupFrame(anchor: anchor), display: true)
        panel.alphaValue = 1
        panel.orderFront(nil)
        // ③ 自动翻译：token 一变，浮窗视图里的 .task(id:) 就重新跑一次，不用手点「翻译」
        model.autoTranslateToken += 1
    }

    /// 浮窗位置：优先贴选区矩形下方；下方不够就翻到上方；全程钳在屏幕可视区内。
    /// anchor 为 nil（拿不到选区矩形）时退回鼠标位置——这是兜底，不是默认。
    private func popupFrame(anchor: NSRect?) -> NSRect {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(panelW, vf.width), h = min(panelH, vf.height)
        var x: CGFloat, y: CGFloat
        if let a = anchor {
            x = a.minX                                  // 与选区左边缘对齐
            y = a.minY - h - 8                          // 默认贴选区下方
            if y < vf.minY + 4 { y = a.maxY + 8 }       // 下方放不下 → 翻到选区上方
        } else {
            let m = NSEvent.mouseLocation
            x = m.x - w / 2
            y = m.y - h - 12
        }
        x = min(max(vf.minX + 4, x), vf.maxX - w - 4)
        y = min(max(vf.minY + 4, y), vf.maxY - h - 4)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func buildPanel() {
        let p = SelectionPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        let h = NSHostingController(rootView: SelectionPopupView(model: model))
        p.contentViewController = h
        p.setContentSize(NSSize(width: panelW, height: panelH))
        if let cv = p.contentView {
            let ta = NSTrackingArea(rect: cv.bounds,
                                    options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                    owner: p, userInfo: nil)
            cv.addTrackingArea(ta)
        }
        p.onMouseInsideChange = { [weak self] inside in
            self?.mouseInside = inside
        }
        hosting = h
        panel = p
    }

    func hidePopup(reason: String = "?") {
        // 记下是谁把浮窗收掉的 —— "刚弹出来就消失"这类问题全靠这个定位
        debugLog("hide", reason)
        lastText = ""
        resetPending()
        emptySince = nil
        guard let panel else { return }
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    /// 用户手动点掉浮窗（X）：记住这段选区，只要内容没变就不再弹，
    /// 哪怕它在原软件里还处于选中状态。等选区消失或换一段文字后才恢复。
    func dismissPopup() {
        suppressText = model.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        suppressBundle = lastFrontBundle
        suppressAt = Date()
        hidePopup(reason: "用户点了 X（已抑制这段文字）")
    }
}

/// 通透度滑块（四个窗口共用一套文案与量程）
struct ClearnessSlider: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value < 0.34 ? "偏实" : (value < 0.67 ? "适中" : "很透"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...1)
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @State private var inputText = ""
    @State private var outputText = ""
    @State private var isTranslating = false
    @State private var errorMessage: String?
    @State private var detectedSource: String?
    @State private var copied = false

    // 翻译任务开关 + 会话代际号（代际号一变就重建修饰符，绕过它的去重）
    @State private var config: TranslationSession.Configuration?
    @State private var sessionGeneration = 0
    @State private var debounceTask: Task<Void, Never>?

    // 截图
    @State private var pastedImage: NSImage?
    @State private var isRecognizing = false

    // 本窗口通透度（设置 → 窗口通透度 → 翻译窗口）
    @AppStorage("mainClearness") private var mainClearness = 0.30

    /// 输入区右上角那几个动作按钮的"大红色"（醒目，按要求统一走这个色）
    private var actionRed: Color { Color(red: 0.91, green: 0.10, blue: 0.13) }

    // 设置
    @AppStorage("engine") private var engineMode = "auto"
    @AppStorage("baiduAppID") private var baiduAppID = ""
    @AppStorage("baiduApiKey") private var baiduApiKey = ""
    @AppStorage("targetChoice") private var targetRaw = TargetChoice.auto.rawValue
    @AppStorage("style") private var styleRaw = TranslateStyle.standard.rawValue
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @AppStorage("autoCopy") private var autoCopy = false
    @AppStorage("clipboardWatchMode") private var clipboardWatchMode = ClipboardWatchMode.off
    @AppStorage("accentTheme") private var accentTheme = "glass"

    // 界面状态
    @State private var window: NSWindow?
    @State private var showHistory = false
    @ObservedObject private var history = HistoryStore.shared
    @Environment(\.openWindow) private var openWindow

    @FocusState private var inputFocused: Bool

    private var trimmedInput: String { inputText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var inputIsChinese: Bool { isChinese(trimmedInput) }
    private var style: TranslateStyle { TranslateStyle(rawValue: styleRaw) ?? .standard }
    private var target: TargetChoice { TargetChoice(rawValue: targetRaw) ?? .auto }

    private var usesBaidu: Bool {
        guard !baiduApiKey.isEmpty, !baiduAppID.isEmpty else { return false }
        return engineMode != "offline"
    }

    /// 最终目标语种（Apple / 百度两套代码）
    private var resolvedTarget: (apple: Locale.Language, baidu: String) {
        if target == .auto {
            return inputIsChinese
                ? (Locale.Language(identifier: "en"), "en")
                : (Locale.Language(identifier: "zh-Hans"), "zh")
        }
        return (Locale.Language(identifier: target.appleCode), target.baiduCode)
    }

    /// 源语言。显式选了目标语种时留 nil 交给引擎检测，避免源=目标撞车。
    private var sourceLanguage: Locale.Language? {
        if target != .auto { return nil }
        if inputIsChinese { return Locale.Language(identifier: "zh-Hans") }
        let (cjk, latin) = charCounts(trimmedInput)
        if cjk == 0 && latin > 0 { return Locale.Language(identifier: "en") }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            inputPane.frame(maxHeight: .infinity)
            Divider()
            outputPane.frame(maxHeight: .infinity)
            Divider()
            statusBar
        }
        .frame(minWidth: 560, minHeight: 420)
        .tint(Color(nsColor: AccentTheme(rawValue: accentTheme)?.accent ?? .controlAccentColor))
        // 通透度由「设置 → 窗口通透度 → 翻译窗口」那个滑块控制，拖动即时生效
        .background(.ultraThinMaterial.opacity(Clearness.material(mainClearness)))
        .background(Color(nsColor: .windowBackgroundColor)
            .opacity(Clearness.backing(mainClearness, max: 0.20)))
        .background(
            Color.clear.frame(width: 1, height: 1)
                .translationTask(config) { session in await runTranslation(session) }
                .id(sessionGeneration)
        )
        .background(WindowAccessor { window in
            self.window = window
            applyWindowLevel()
            EdgeDockController.shared.attach(window)
        })
        .onChange(of: inputText) { _, _ in scheduleTranslation() }
        .onChange(of: alwaysOnTop) { _, _ in applyWindowLevel(); syncClipboardWatch() }
        .onChange(of: clipboardWatchMode) { _, _ in syncClipboardWatch() }
        .onChange(of: targetRaw) { _, _ in scheduleTranslation() }
        .onChange(of: styleRaw) { _, _ in scheduleTranslation() }
        .onReceive(NotificationCenter.default.publisher(for: .incomingText)) { note in
            if let text = note.object as? String { inputText = text }
        }
        .onAppear {
            inputFocused = true
            AppDelegate.handlePastedImage = { [self] image in
                handlePastedImage(image)
                return true
            }
            ClipboardWatcher.shared.onImage = { [self] image in handlePastedImage(image) }
            syncClipboardWatch()
        }
        .onDrop(of: [.image], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                if let image = object as? NSImage {
                    DispatchQueue.main.async { handlePastedImage(image) }
                }
            }
            return true
        }
        .popover(isPresented: $showHistory) {
            HistoryView { entry in
                inputText = entry.source
                outputText = entry.translated
                showHistory = false
            }
        }
    }

    // MARK: 触发

    private func scheduleTranslation() {
        let delay: UInt64 = usesBaidu ? 1_000_000_000 : 600_000_000
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            fire()
        }
    }

    private func fire() {
        let text = trimmedInput
        guard !text.isEmpty else {
            outputText = ""
            detectedSource = nil
            errorMessage = nil
            config = nil
            return
        }
        if usesBaidu { runBaidu(text) } else { startAppleSession() }
    }

    private func startAppleSession() {
        sessionGeneration += 1
        config = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            config = TranslationSession.Configuration(source: sourceLanguage,
                                                      target: resolvedTarget.apple)
        }
    }

    private func runBaidu(_ text: String) {
        isTranslating = true
        errorMessage = nil
        BaiduEngine.translate(text,
                              apiKey: baiduApiKey,
                              appid: baiduAppID,
                              to: resolvedTarget.baidu,
                              style: style.instruction) { result in
            isTranslating = false
            switch result {
            case .success(let out):
                if trimmedInput == text { finish(out.text, from: out.fromLanguage) }
            case .failure(let failure):
                if trimmedInput == text {
                    errorMessage = "在线引擎失败（\(failure.message)），已自动改用离线引擎"
                }
                startAppleSession()
            }
        }
    }

    @MainActor
    private func runTranslation(_ session: TranslationSession) async {
        let text = trimmedInput
        guard !text.isEmpty else { return }
        isTranslating = true
        errorMessage = nil
        do {
            try await session.prepareTranslation()
            let response = try await session.translate(text)
            if trimmedInput == text {
                finish(response.targetText,
                       from: response.sourceLanguage.languageCode?.identifier)
            }
        } catch {
            if trimmedInput == text {
                errorMessage = "翻译失败：\(error.localizedDescription)　·　首次使用需联网下载语言包"
            }
        }
        isTranslating = false
    }

    /// 译文上屏 + 可选自动复制 + 记历史
    private func finish(_ text: String, from: String?) {
        outputText = text
        detectedSource = from.map(languageName)
        errorMessage = nil
        if autoCopy {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
        }
        HistoryStore.shared.add(source: trimmedInput, translated: text)
    }

    // MARK: 截图

    private func handlePastedImage(_ image: NSImage) {
        pastedImage = image
        isRecognizing = true
        errorMessage = nil
        outputText = ""
        OCR.recognize(image) { text in
            isRecognizing = false
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorMessage = "这张图里没识别出文字 —— 试试文字更清晰、更大的截图"
                return
            }
            inputText = mergeWrappedLines(text)
        }
    }

    private func syncClipboardWatch() {
        let shouldRun: Bool
        switch clipboardWatchMode {
        case .off:        shouldRun = false
        case .always:     shouldRun = true
        case .pinnedOnly: shouldRun = alwaysOnTop
        }
        if shouldRun { ClipboardWatcher.shared.start() } else { ClipboardWatcher.shared.stop() }
    }

    private func applyWindowLevel() {
        window?.level = alwaysOnTop ? .floating : .normal
    }

    // MARK: 界面

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("输入").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if !inputText.isEmpty {
                    Text("\(inputText.count) 字").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Button("清空") { clearAll() }
                        .buttonStyle(.borderless).font(.system(size: 11))
                        .foregroundStyle(actionRed)
                }
                Button { Speaker.shared.speak(trimmedInput) } label: {
                    Image(systemName: "speaker.wave.2").foregroundStyle(actionRed)
                }
                .buttonStyle(.borderless)
                .disabled(trimmedInput.isEmpty)
                .help("朗读原文")
                Button { pasteImageFromClipboard() } label: {
                    HStack(spacing: 4) { Image(systemName: "photo"); Text("粘贴图片") }
                        .font(.system(size: 11))
                        .foregroundStyle(actionRed)
                }
                .buttonStyle(.borderless)
                .help("读取剪贴板里的截图识别文字（⌘V 同样生效）")
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)

            if let image = pastedImage {
                HStack(spacing: 10) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(height: 52).clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("来自截图").font(.system(size: 11, weight: .semibold))
                        Text("⌘V 或点「粘贴图片」可换一张").font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { pastedImage = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $inputText)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 11)
                    .focused($inputFocused)
                if inputText.isEmpty {
                    Text("输入中文自动译成英文，输入英文自动译成中文；⌘V 可粘贴截图识别文字")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(.horizontal, 16).padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }
            .padding(.bottom, 10)
        }
    }

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("译文").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                if !outputText.isEmpty, let src = detectedSource {
                    Text("· \(src) → \(target == .auto ? (inputIsChinese ? "英文" : "中文") : target.label)")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                Picker("", selection: $targetRaw) {
                    ForEach(TargetChoice.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .help("目标语种；留「自动」则不是中文的一律译中文")
                Button { Speaker.shared.speak(outputText) } label: { Image(systemName: "speaker.wave.2") }
                    .buttonStyle(.borderless)
                    .disabled(outputText.isEmpty)
                    .help("朗读译文")
                Button { copyOutput() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "已复制" : "复制")
                    }.font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .disabled(outputText.isEmpty)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)

            ScrollView {
                Text(outputText).font(.system(size: 15))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if isRecognizing {
                ProgressView().controlSize(.small)
                Text("识别图中文字…")
            } else if isTranslating {
                ProgressView().controlSize(.small)
                Text("翻译中…")
            } else if let msg = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(msg).foregroundStyle(Color.orange)
            } else if !outputText.isEmpty {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(Color(nsColor: .systemGreen))
                Text("就绪")
            } else {
                Text("等待输入")
            }
            Spacer()
            Text(usesBaidu ? "百度大模型" : "本机离线 · 不联网")
                .foregroundStyle(.tertiary)
            Toggle("置顶", isOn: $alwaysOnTop)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            // 原来是个 11pt 的灰色裸图标，混在状态栏里几乎看不见。
            // 改成带文字的描边按钮：图标换 clock.arrow.circlepath（更表意）、
            // 字号提到 12、外加一层强调色描边，视觉上从"装饰"变成"能点的入口"。
            Button { showHistory = true } label: {
                Label(history.entries.isEmpty ? "历史记录" : "历史记录 \(history.entries.count)",
                      systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: AccentTheme(rawValue: accentTheme)?.accent ?? .controlAccentColor))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("历史记录（已存 \(history.entries.count) 条，点开查看/复制）")
            Button { openSettingsWindow(openWindow: openWindow) } label: {
                Image(systemName: "gearshape").font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("设置　全局呼出：⌥Space")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: 动作

    private func clearAll() {
        inputText = ""
        outputText = ""
        detectedSource = nil
        errorMessage = nil
        pastedImage = nil
        config = nil
    }

    private func copyOutput() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(outputText, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private func pasteImageFromClipboard() {
        if let image = AppDelegate.imageFromClipboard() {
            handlePastedImage(image)
        } else {
            errorMessage = "剪贴板里没有图片 —— 先截图（⌘⇧4 或 ⌘⌃⇧4）"
        }
    }
}

// MARK: - 窗口访问器（置顶功能要拿到真实的 NSWindow）

struct WindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let w = view.window { onResolve(w) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let w = view.window { onResolve(w) } }
    }
}

// MARK: - 贴边胶囊（拖到屏幕边缘自动收纳）

/// 交互模型：
///   拖窗口靠近屏幕边缘（<24px）→ 吸附贴边，主窗口隐藏，胶囊顶上
///   悬停胶囊 → 不展开（只点击才展开，避免误弹）
///   点击胶囊 → 持续显示（移开也不缩回）
///   Esc / ⌥Space / 拖离边缘 → 退出贴边态
///
/// 实现要点：由于展开只由「点击胶囊」触发，轮询已不再承担悬停检测，
/// 仅用于在已展开时判断光标是否离开（理论上点击展开的都 pin 了不会缩，保留以防万一）。
/// 当初不用鼠标事件监听是因为 App 未激活时光标在自己窗口上不产生 mouseMoved 事件，
/// 但既然现在只需点胶囊，胶囊自己的 mouseDown 回调足矣。
final class EdgeDockController: NSObject, NSWindowDelegate {
    static let shared = EdgeDockController()

    enum Edge { case left, right, top, bottom }

    private(set) var edge: Edge?
    private(set) var pinned = false
    private var mainWindow: NSWindow?
    private var capsule: CapsulePanel?
    private var dockedFrame: NSRect = .zero
    private var dockScreen: NSScreen?      // orderOut 后 window.screen 变 nil，必须提前存
    private var restoringFrame = false     // 自己 setFrame 会触发 windowDidMove，防递归
    private var capsuleDragging = false    // 胶囊正被拖动：期间不轮询、不插手位置
    private var outsideSince: Date?
    private var pollTimer: Timer?
    private var monitors: [Any] = []
    private var allowRealClose = false     // 点 X = 收成胶囊；只有「退出 App」前才会置 true

    var isEnabled: Bool { UserDefaults.standard.object(forKey: "edgeDock") as? Bool ?? true }

    /// 「退出 App」按钮前调用：放行真正的关闭，否则点 X 只会收成胶囊
    func prepareToQuit() { allowRealClose = true }

    /// 配色主题切换后：胶囊实时重染（窗口 tint 由 SwiftUI 的 @AppStorage 自动刷新）
    func refreshAppearance() {
        if let cap = capsule, let cv = cap.contentView as? CapsuleContentView {
            cv.refreshTheme()
        }
    }

    // MARK: 挂接

    func attach(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        // 玻璃窗口外观：透明标题栏 + 非不透明（SwiftUI 侧用 .regularMaterial 填背景）
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.delegate = self
        startPolling()
        let esc = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, let self, self.handleEscape() { return nil }
            return e
        }
        if let esc { monitors.append(esc) }
        let click = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            self?.handleClick(at: NSEvent.mouseLocation)
            return e
        }
        if let click { monitors.append(click) }
    }

    /// ⌥Space / 菜单「显示窗口」在贴边态下的开关逻辑。返回 true = 已处理。
    func handleSummon() -> Bool {
        guard isEnabled, edge != nil, let w = mainWindow else { return false }
        if w.isVisible { collapse() } else { show(pinned: true) }
        return true
    }

    func applySetting(enabled: Bool) {
        if !enabled { undock(thenShow: true) }
    }

    // MARK: 贴边判定

    private func nearestEdge(of w: NSWindow) -> Edge? {
        let threshold: CGFloat = 24
        guard let screen = w.screen ?? NSScreen.main else { return nil }
        let vf = screen.visibleFrame, f = w.frame
        let ds: [(Edge, CGFloat)] = [
            (.left,   abs(f.minX - vf.minX)),
            (.right,  abs(vf.maxX - f.maxX)),
            (.top,    abs(vf.maxY - f.maxY)),
            (.bottom, abs(f.minY - vf.minY)),
        ]
        guard let hit = ds.min(by: { $0.1 < $1.1 }), hit.1 <= threshold else { return nil }
        return hit.0
    }

    private func snappedFrame(_ f: NSRect, edge: Edge, in vf: NSRect) -> NSRect {
        var r = f
        switch edge {
        case .left:   r.origin.x = vf.minX
        case .right:  r.origin.x = vf.maxX - r.width
        case .top:    r.origin.y = vf.maxY - r.height
        case .bottom: r.origin.y = vf.minY
        }
        return r
    }

    private func dock(to e: Edge, window w: NSWindow) {
        guard let screen = w.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var snapped = snappedFrame(w.frame, edge: e, in: vf)
        // 沿边方向钳制在屏幕内（留 2pt，让窗口也能落到角上）
        switch e {
        case .left, .right:
            snapped.origin.y = min(max(vf.minY + 2, snapped.origin.y), vf.maxY - snapped.height - 2)
        case .top, .bottom:
            snapped.origin.x = min(max(vf.minX + 2, snapped.origin.x), vf.maxX - snapped.width - 2)
        }
        edge = e
        pinned = false
        outsideSince = nil
        dockedFrame = snapped
        dockScreen = screen
        restoringFrame = true
        w.setFrame(snapped, display: false)
        restoringFrame = false
        w.orderOut(nil)          // 主窗口让位，胶囊顶上
        showCapsule()
    }

    private func undock(thenShow: Bool = false) {
        guard edge != nil else { return }
        edge = nil
        pinned = false
        outsideSince = nil
        capsule?.orderOut(nil)
        if thenShow, let w = mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: 展开 / 收起

    /// 胶囊当前应处的位置（动画的起止点）
    private func capsuleTargetFrame() -> NSRect {
        guard let e = edge, let screen = dockScreen ?? NSScreen.main else { return .zero }
        return capsuleRect(edge: e, anchor: dockedFrame, vf: screen.visibleFrame)
    }

    private func show(pinned pin: Bool) {
        guard let w = mainWindow, edge != nil else { return }
        pinned = pin
        outsideSince = nil
        capsule?.orderOut(nil)                       // 先藏胶囊，窗口从胶囊位置长出来
        let start = capsule?.frame ?? capsuleTargetFrame()
        restoringFrame = true
        w.setFrame(start, display: false)
        w.alphaValue = 0
        w.level = .floating                          // 动画期间浮起，结束后按需调整
        w.orderFront(nil)
        // 快速淡入（先可见），主角是由小变大的尺寸动画
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            w.animator().alphaValue = 1
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(dockedFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.restoringFrame = false
            guard pin else { return }
            let top = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? false
            w.level = top ? .floating : .normal
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        })
    }

    func collapse() {
        guard let w = mainWindow, edge != nil, w.isVisible else { return }
        pinned = false
        outsideSince = nil
        let target = capsuleTargetFrame()
        restoringFrame = true
        // 由大变小缩到胶囊位置（不淡出，缩到位后胶囊淡入，视觉连续）
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.restoringFrame = false
            w.orderOut(nil)
            self?.showCapsule(animated: true)        // 缩到胶囊位置后，胶囊淡入
        })
    }

    // MARK: 胶囊窗

    private func showCapsule(animated: Bool = false) {
        guard let e = edge, let screen = dockScreen ?? NSScreen.main else { return }
        let panel = capsule ?? CapsulePanel()
        if capsule == nil {
            panel.onClick = { [weak self] in self?.show(pinned: true) }   // 点胶囊 → 持续显示
            capsule = panel
        }
        (panel.contentView as? CapsuleContentView)?.onDrop = { [weak self] in self?.redockCapsule(panel) }   // 拖完松开 → 自动贴边
        (panel.contentView as? CapsuleContentView)?.onDragBegan = { [weak self] in self?.capsuleDragging = true }
        panel.setFrame(capsuleRect(edge: e, anchor: dockedFrame, vf: screen.visibleFrame), display: true)
        panel.orderFront(nil)
        if animated {
            panel.alphaValue = 0
            panel.animator().alphaValue = 1
        }
    }

    /// 拖动胶囊松手后：按当前位置吸附到最近的屏幕边缘，并同步主窗口的展开位置。
    /// ⚠️ dockedFrame 必须存「完整窗口尺寸」的贴边位置——若误存胶囊的小尺寸，
    /// 展开时 SwiftUI 的 minWidth 钳制会把窗口撑回 560 宽而 origin 还贴着边 → 整窗飞出屏幕。
    private func redockCapsule(_ panel: CapsulePanel) {
        capsuleDragging = false
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let e = preferredEdge(for: panel.frame, in: vf, current: edge)
        var f = mainWindow?.frame ?? NSRect(x: 0, y: 0, width: 580, height: 440)
        f.size.width = min(f.width, vf.width)
        f.size.height = min(f.height, vf.height)
        switch e {
        case .left:   f.origin = NSPoint(x: vf.minX, y: panel.frame.midY - f.height / 2)
        case .right:  f.origin = NSPoint(x: vf.maxX - f.width, y: panel.frame.midY - f.height / 2)
        case .top:    f.origin = NSPoint(x: panel.frame.midX - f.width / 2, y: vf.maxY - f.height)
        case .bottom: f.origin = NSPoint(x: panel.frame.midX - f.width / 2, y: vf.minY)
        }
        // 沿边方向钳制在屏幕内。留 2pt 余量而不是更大的值，
        // 这样拖到四个角时胶囊/窗口能真正落到角上（之前 4pt 会让人觉得角落是"死角"）
        let m: CGFloat = 2
        switch e {
        case .left, .right:
            f.origin.y = min(max(vf.minY + m, f.origin.y), vf.maxY - f.height - m)
        case .top, .bottom:
            f.origin.x = min(max(vf.minX + m, f.origin.x), vf.maxX - f.width - m)
        }
        edge = e
        dockScreen = screen
        dockedFrame = f
        // 平滑滑入：从松手位置动画到贴边位置，而不是"啪"地瞬移过去
        let target = capsuleRect(edge: e, anchor: f, vf: vf)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// 选最近的边。角落里"到两边几乎等距"，直接取最小会在两条边之间反复横跳，
    /// 所以给**当前已贴的那条边** 40pt 的偏好（迟滞）：只有另一条边明显更近才换边。
    private func preferredEdge(for f: NSRect, in vf: NSRect, current: Edge?) -> Edge {
        let cands: [(Edge, CGFloat)] = [
            (.left,   abs(f.minX - vf.minX)),
            (.right,  abs(vf.maxX - f.maxX)),
            (.top,    abs(vf.maxY - f.maxY)),
            (.bottom, abs(f.minY - vf.minY)),
        ]
        var best: (Edge, CGFloat) = (.left, .greatestFiniteMagnitude)
        for (e, d) in cands {
            let score = d + (e == current ? -40 : 0)
            if score < best.1 { best = (e, score) }
        }
        return best.0
    }

    private func capsuleRect(edge e: Edge, anchor: NSRect, vf: NSRect) -> NSRect {
        let thick: CGFloat = 24, long: CGFloat = 36, gap: CGFloat = 3
        let m: CGFloat = 2          // 沿边余量也收到 2pt：让胶囊能真正停在四个角上
        switch e {
        case .left, .right:
            let x = e == .left ? vf.minX + gap : vf.maxX - thick - gap
            let y = min(max(vf.minY + m, anchor.midY - long / 2), vf.maxY - long - m)
            return NSRect(x: x, y: y, width: thick, height: long)
        case .top, .bottom:
            let y = e == .bottom ? vf.minY + gap : vf.maxY - thick - gap
            let x = min(max(vf.minX + m, anchor.midX - long / 2), vf.maxX - long - m)
            return NSRect(x: x, y: y, width: long, height: thick)
        }
    }

    // MARK: 轮询（悬停进出检测）

    private func startPolling() {
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 0.12, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    @objc private func poll() {
        guard isEnabled, edge != nil, !capsuleDragging else { return }
        let loc = NSEvent.mouseLocation

        if let cap = capsule, cap.isVisible {
            // 胶囊态：悬停不展开，只有点击胶囊（CapsulePanel.onClick）才展开，这里不做事
            return
        }
        guard let w = mainWindow, w.isVisible, !pinned else { return }
        if w.frame.insetBy(dx: -4, dy: -4).contains(loc) {
            outsideSince = nil
        } else {
            // 移开持续 0.45s 才缩回，避免扫过边缘时误缩
            let since = outsideSince ?? Date()
            outsideSince = since
            if Date().timeIntervalSince(since) > 0.45 { collapse() }
        }
    }

    private func handleClick(at loc: NSPoint) {
        guard isEnabled, edge != nil, !pinned,
              let w = mainWindow, w.isVisible,
              w.frame.insetBy(dx: -4, dy: -4).contains(loc) else { return }
        pinned = true   // 在临时展开的窗口里点了一下 → 视为要持续用
        outsideSince = nil
    }

    private func handleEscape() -> Bool {
        guard isEnabled, edge != nil, mainWindow?.isVisible == true else { return false }
        collapse()
        return true
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard isEnabled, !restoringFrame,
              let w = mainWindow, w === notification.object as? NSWindow, w.isVisible else { return }
        // 已处于胶囊态（edge != nil）才跟边；不再「拖到边缘自动收成胶囊」
        guard edge != nil else { return }
        if nearestEdge(of: w) == nil {
            undock()                // 拖离边缘 → 恢复普通窗口
        } else {
            dockedFrame = w.frame   // 沿边缘挪动：展开位置跟随
        }
    }

    /// 点窗口红 X：不让它真正关闭，改成收成胶囊（贴近最近边缘，无视 24px 阈值）
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else { return true }
        if allowRealClose { return true }   // 「退出 App」放行
        if isEnabled { collapseToCapsule(); return false }
        return true                        // 功能关闭则正常关闭窗口
    }

    private func collapseToCapsule() {
        guard isEnabled, let w = mainWindow else { return }
        if edge == nil, let e = nearestEdgeAlways(of: w) {
            dock(to: e, window: w)   // 当前是自由窗口 → 吸附最近边缘并收成胶囊
        } else {
            collapse()               // 已贴边 → 直接收起
        }
    }

    /// 永远返回最近的边缘（用于「点 X 收胶囊」，不论离边多远）
    private func nearestEdgeAlways(of w: NSWindow) -> Edge? {
        guard let screen = w.screen ?? NSScreen.main else { return nil }
        let vf = screen.visibleFrame, f = w.frame
        let ds: [(Edge, CGFloat)] = [
            (.left,   abs(f.minX - vf.minX)),
            (.right,  abs(vf.maxX - f.maxX)),
            (.top,    abs(vf.maxY - f.maxY)),
            (.bottom, abs(f.minY - vf.minY)),
        ]
        return ds.min(by: { $0.1 < $1.1 })?.0
    }
}

/// 贴边时的胶囊小窗：无边框、不抢焦点、点一下固定展开
final class CapsulePanel: NSPanel {
    var onClick: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 24, height: 36),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = CapsuleContentView(frame: NSRect(x: 0, y: 0, width: 24, height: 36))
        view.onClick = { [weak self] in self?.onClick?() }
        contentView = view
    }
}

final class CapsuleContentView: NSView {
    var onClick: (() -> Void)?
    var onDrop: (() -> Void)?          // 拖拽松手后交给控制器重新贴边
    var onDragBegan: (() -> Void)?     // 拖拽真正开始时通知控制器（控制器据此暂停插手）

    private let capsuleAccent = NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1)  // 蓝 #007AFF
    private var effect: NSVisualEffectView!
    private var tintView: NSView!
    private var gloss: CAGradientLayer!
    private var label: NSTextField!
    private var dragMouseStart: NSPoint?   // 按下时的鼠标屏幕坐标（不是窗口坐标！）
    private var windowStart: NSPoint?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        clipsToBounds = false

        // 毛玻璃底（behindWindow：模糊窗口背后的桌面/其他窗口 → 真玻璃感）
        effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        addSubview(effect)

        // 强调色染色层（低透明度，保持通透）
        tintView = NSView()
        tintView.wantsLayer = true
        tintView.layer?.masksToBounds = true
        addSubview(tintView)

        // 顶部高光（模拟玻璃的镜面反光）
        gloss = CAGradientLayer()
        gloss.colors = [NSColor.white.withAlphaComponent(0.18).cgColor,
                        NSColor.white.withAlphaComponent(0.0).cgColor]
        gloss.startPoint = CGPoint(x: 0.5, y: 0)
        gloss.endPoint = CGPoint(x: 0.5, y: 0.55)
        tintView.layer?.addSublayer(gloss)

        label = NSTextField(labelWithString: "译")
        label.font = .systemFont(ofSize: 15, weight: .bold)
        addSubview(label)

        refreshTheme()
    }

    /// 布局不写死：胶囊会被 setFrame 在竖条(26×110)/横条(110×26)之间切换，
    /// 每次布局按当前 bounds 重算全部 frame 和圆角，否则切向后高光/文字全是错位的
    override func layout() {
        super.layout()
        let r = min(bounds.width, bounds.height) / 2
        effect.frame = bounds
        effect.layer?.cornerRadius = r
        tintView.frame = bounds
        tintView.layer?.cornerRadius = r
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // 隐式动画会让 resize 时高光拖影
        gloss.frame = bounds
        CATransaction.commit()
        label.sizeToFit()
        label.frame.origin = CGPoint(x: (bounds.width - label.frame.width) / 2,
                                     y: (bounds.height - label.frame.height) / 2)
    }

    /// 胶囊统一用蓝色（与窗口主题无关），最透 + 极细边框
    func refreshTheme() {
        // 通透度：设置 → 窗口通透度 → 菜单栏胶囊（AppKit 侧直接读 UserDefaults，
        // 拖动时由设置页调 refreshAppearance() 触发这里重画）
        let t = UserDefaults.standard.object(forKey: "capsuleClearness") as? Double ?? 0.0
        effect.alphaValue = 1.0 - 0.65 * max(0, min(1, t))   // 1.0 → 0.35

        // 深浅自适应：高光和染色的强度按当前外观走。
        // 浅色模式下背景本身就是亮的，白色高光要更强一点才看得出"玻璃反光"；
        // 染色也一样，浅色底上 5% 几乎不可见，给到 9%。
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        gloss.colors = [NSColor.white.withAlphaComponent(isDark ? 0.18 : 0.55).cgColor,
                        NSColor.white.withAlphaComponent(0.0).cgColor]
        tintView.layer?.backgroundColor = capsuleAccent.withAlphaComponent(isDark ? 0.05 : 0.09).cgColor
        effect.layer?.borderColor = capsuleAccent.cgColor
        effect.layer?.borderWidth = 0.75
        label.textColor = capsuleAccent
    }

    /// 系统/应用外观切换时 AppKit 会回调这里 → 重画自绘的图层
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTheme()
    }

    // MARK: 拖拽（按下→移动超阈值算拖，松手自动贴边；没移动过点一下展开）

    override func mouseDown(with event: NSEvent) {
        // ⚠️ 必须用 NSEvent.mouseLocation（屏幕绝对坐标），不能用 event.locationInWindow。
        // 窗口自己会跟着鼠标移动，而 locationInWindow 是"相对窗口左上角"的：
        // 窗口右移 dx 后，同一个鼠标点算出来的 locationInWindow.x 反而小了 dx，
        // 于是位移被算成 2dx、窗口再跑更远 → 正反馈发散，表现出来就是"拖着一路乱跳"。
        dragMouseStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let ms = dragMouseStart, let ws = windowStart, let win = window else { return }
        let cur = NSEvent.mouseLocation            // 屏幕坐标：与窗口是否移动无关
        let dx = cur.x - ms.x, dy = cur.y - ms.y
        if !didDrag {
            guard hypot(dx, dy) >= 3 else { return }   // 阈值内不算拖，避免误触
            didDrag = true
            onDragBegan?()                             // 告诉控制器：开始拖了，别插手
        }
        win.setFrameOrigin(NSPoint(x: ws.x + dx, y: ws.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            onDrop?()                 // 拖动后松手 → 控制器重新贴边
        } else {
            onClick?()               // 没拖动 → 视为点击 → 展开
        }
        dragMouseStart = nil; windowStart = nil; didDrag = false
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - 历史记录面板

struct HistoryView: View {
    @ObservedObject private var history = HistoryStore.shared
    var onPick: (HistoryEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("历史记录").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("清空") { HistoryStore.shared.clear() }
                    .buttonStyle(.borderless).font(.system(size: 11))
            }
            .padding(12)

            Divider()

            if history.entries.isEmpty {
                Text("还没有记录").font(.system(size: 12)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(history.entries) { entry in
                            Button { onPick(entry) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.source).font(.system(size: 12)).lineLimit(2)
                                    Text(entry.translated).font(.system(size: 12))
                                        .foregroundStyle(.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 380, height: 420)
    }
}

// MARK: - App

@main
struct YiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        WindowGroup("便捷翻译") { ContentView() }
            .defaultSize(width: 580, height: 440)

        Window("设置", id: settingsWindowID) { EngineSettingsView() }
            .windowResizability(.contentSize)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarMenu()
        } label: {
            Image(nsImage: StatusBarIcon.image)
                .accessibilityLabel("便捷翻译")
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - 状态栏图标

/// 状态栏图标：实心圆角方块 + 镂空的「译」字（底色实心、字是透明的）。
///
/// 画成 **template 图**（`isTemplate = true`）是刻意的，不是偷懒：
/// 模板图的不透明部分会被 macOS 用「当前菜单栏前景色」填充，于是
///   · 深色菜单栏 → 白底 + 镂空字（正是要的效果）
///   · 浅色菜单栏 → 深底 + 镂空字（自动反色，否则白底和白菜单栏糊在一起，图标等于消失）
/// 这样两种外观下都看得见。若要做成"永远纯白底"，把 `isTemplate` 改成 false、
/// 并把下面 setFill 改成 NSColor.white 即可 —— 但浅色菜单栏下会基本看不见。
enum StatusBarIcon {
    static let image: NSImage = {
        // 18×18 是菜单栏图标的常见尺寸；方块留 1pt 边距，避免贴满显得臃肿
        let side: CGFloat = 18
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let box = rect.insetBy(dx: 1, dy: 1.5)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: box, xRadius: 4.5, yRadius: 4.5).fill()

            // 关键一步：用 destinationOut 把「译」字"挖"掉 → 字的位置变成透明（镂空）
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.saveGState()
            ctx.setBlendMode(.destinationOut)
            let text = "译" as NSString
            // 0.72 是试出来的：再大（0.80）字会顶满方块、四周留白太窄，
            // 镂空效果会变成"一圈细边描着的字"；再小则笔画糊。0.72 四周留白与字重最平衡。
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: box.height * 0.72, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
            let ts = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: box.midX - ts.width / 2, y: box.midY - ts.height / 2 + 0.5),
                      withAttributes: attrs)
            ctx.restoreGState()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

// MARK: - 菜单栏下拉

/// 单独抽成 View：要用 @Environment(\.openWindow)，在 App 的 SceneBuilder 里直接取不稳。
struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("显示「便捷翻译」窗口　⌥Space") { HotKeyManager.shared.onFire?() }
        Button("朗读剪贴板内容") {
            if let text = NSPasteboard.general.string(forType: .string) { Speaker.shared.speak(text) }
        }
        Button("设置…") { openSettingsWindow(openWindow: openWindow) }
        Divider()
        Button("退出") { EdgeDockController.shared.prepareToQuit(); NSApp.terminate(nil) }
    }
}

// MARK: - 设置

struct EngineSettingsView: View {
    @AppStorage("engine") private var engineMode = "auto"
    @AppStorage("baiduAppID") private var baiduAppID = ""
    @AppStorage("baiduApiKey") private var baiduApiKey = ""
    @AppStorage("style") private var styleRaw = TranslateStyle.standard.rawValue
    @AppStorage("autoCopy") private var autoCopy = false
    @AppStorage("clipboardWatchMode") private var clipboardWatchMode = ClipboardWatchMode.off
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("startAtLogin") private var startAtLogin = false
    @AppStorage("edgeDock") private var edgeDock = true
    @AppStorage("accentTheme") private var accentTheme = "glass"
    @AppStorage("selectionPopup") private var selectionPopup = false
    @AppStorage("popupInEditable") private var popupInEditable = false   // 输入框内也弹（默认关）
    @AppStorage("popupClearness") private var popupClearness = 0.5        // 选区浮窗
    @AppStorage("mainClearness") private var mainClearness = 0.30         // 翻译窗口
    @AppStorage("settingsClearness") private var settingsClearness = 0.30 // 设置窗口（就是本窗口）
    @AppStorage("capsuleClearness") private var capsuleClearness = 0.0    // 菜单栏胶囊
    @AppStorage("appearanceMode") private var appearanceMode = "system"   // 跟随系统 / 浅色 / 深色
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("翻译引擎") {
                Picker("引擎", selection: $engineMode) {
                    Text("智能（推荐）—— 填了百度凭据走在线大模型，没填走离线").tag("auto")
                    Text("仅离线 —— 苹果本机引擎，不联网，质量一般").tag("offline")
                    Text("强制百度在线 —— 大模型翻译，文字会上传到百度").tag("baidu")
                }
                .pickerStyle(.radioGroup)
            }

            Section("百度大模型翻译") {
                TextField("APP ID", text: $baiduAppID)
                SecureField("API Key", text: $baiduApiKey)
                Text("""
                ① APP ID：控制台左栏「开发者中心 → 开发者信息」顶部，一串数字
                ② API Key：控制台左栏「API Key 管理」，点 Key 列的复制图标
                ③ 还需完成开发者认证并开通「大模型文本翻译」服务，否则报 90107 / 58002
                """)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("隐私提示：走在线引擎时文字会发送到百度服务器。介意就选「仅离线」。")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }

            Section("翻译风格（需在线引擎）") {
                Picker("风格", selection: $styleRaw) {
                    ForEach(TranslateStyle.allCases) { s in Text(s.label).tag(s.rawValue) }
                }
                .labelsHidden()
                Text("走的是百度接口的「翻译指令」字段：同一句话，意译和直译出来的味道差别很大。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("自动化") {
                Toggle("翻译完成自动复制译文到剪贴板", isOn: $autoCopy)
                Picker("监听剪贴板", selection: $clipboardWatchMode) {
                    ForEach(ClipboardWatchMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .help("关闭 / 一直监听 / 仅在窗口置顶时")
                Text("选「仅在窗口置顶时」：平时不轮询剪贴板（省电、避免误吞截图），只有把窗口钉在顶上时才自动接管。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("选区浮窗翻译（任意软件里选中即译）") {
                Toggle("开启选区浮窗", isOn: $selectionPopup)
                    .onChange(of: selectionPopup) { _, on in
                        if on {
                            SelectionPopupController.shared.requestPermission()
                            SelectionPopupController.shared.start()
                        } else {
                            SelectionPopupController.shared.stop()
                        }
                    }
                Toggle("在输入框里也弹浮窗", isOn: $popupInEditable)
                Text("默认关：地址栏、搜索框、聊天输入框经常被系统或输入法「自动选中」，在那里弹窗就是骚扰。需要就打开。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !SelectionPopupController.shared.hasPermission {
                    Button("打开「辅助功能」权限设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    Text("首次使用需在 系统设置 → 隐私与安全性 → 辅助功能 里给「便捷翻译」打勾，否则监测不到其他 App 的选区。开启开关时已自动弹出授权请求。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("""
                开启后：在 GitHub、Discord、浏览器、邮件等任意软件里选中一段文字，
                屏幕对应位置会浮出一个小面板，自动翻译出译文——
                当前软件保持前台，不需要切到「便捷翻译」窗口。
                """)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("窗口通透度") {
                ClearnessSlider(title: "翻译窗口", value: $mainClearness)
                ClearnessSlider(title: "选区浮窗", value: $popupClearness)
                ClearnessSlider(title: "设置窗口（本窗口）", value: $settingsClearness)
                ClearnessSlider(title: "菜单栏胶囊", value: $capsuleClearness)
                    .onChange(of: capsuleClearness) { _, _ in EdgeDockController.shared.refreshAppearance() }
                Text("四个窗口各自独立，拖动即时生效、不用重启。往右更透（能朦胧看到后面的内容），往左更实（字更清楚）。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("界面") {
                Picker("外观", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { m in Text(m.label).tag(m.rawValue) }
                }
                .pickerStyle(.menu)
                .onChange(of: appearanceMode) { _, raw in
                    AppearanceMode.apply(AppearanceMode(rawValue: raw) ?? .system)
                }
                Picker("配色", selection: $accentTheme) {
                    ForEach(AccentTheme.allCases) { t in Text(t.label).tag(t.rawValue) }
                }
                .pickerStyle(.menu)
                .onChange(of: accentTheme) { _, _ in EdgeDockController.shared.refreshAppearance() }
                Toggle("在菜单栏显示「便捷翻译」图标", isOn: $showMenuBar)
                Toggle("点窗口红 X 收成胶囊", isOn: $edgeDock)
                    .onChange(of: edgeDock) { _, on in EdgeDockController.shared.applySetting(enabled: on) }
                Toggle("开机启动", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { _, newValue in
                        if let err = LoginItem.setEnabled(newValue) {
                            startAtLogin = !newValue   // 设置没成功，把开关拨回去
                            loginItemError = err
                        } else {
                            loginItemError = nil
                        }
                    }
                if let err = loginItemError {
                    Text(err).font(.system(size: 11)).foregroundStyle(.orange)
                }
                Text("""
                App 当前是「菜单栏常驻」模式（LSUIElement）：不显示 Dock 图标，也没有自己的菜单栏。
                所以设置入口放在菜单栏下拉里，全局呼出固定为 ⌥Space。
                如果关掉开机启动，下次要靠 Spotlight（⌘Space 搜「便捷翻译」）或手动打开来启动它。
                """)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("窗口置顶在状态栏那个「置顶」勾选框里。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        // .grouped：标签排在控件"上方"而不是左侧那一栏。
        // macOS 默认的 Form 是"左标签列 + 右控件列"，标签列宽度由最长标签撑开，
        // 一旦比窗口还宽，左边的字就会被裁掉（之前 APP ID 的 A 就是这么没的）。
        // grouped 风格下标签独占一行、可换行，从结构上杜绝这种裁剪。
        .formStyle(.grouped)
        .frame(width: 560)
        // 设置窗口自身的通透度：先把 Form 自带的实底去掉，再铺一层可调毛玻璃
        .scrollContentBackground(.hidden)
        .background(.ultraThinMaterial.opacity(Clearness.material(settingsClearness)))
        .background(Color(nsColor: .windowBackgroundColor)
            .opacity(Clearness.backing(settingsClearness, max: 0.22)))
        // 窗口本体也必须是"非不透明 + 透明背景"，否则毛玻璃只会磨到自己的实底，看不出通透
        .background(WindowAccessor { w in
            w.isOpaque = false
            w.backgroundColor = .clear
            w.titlebarAppearsTransparent = true
        })
    }
}
