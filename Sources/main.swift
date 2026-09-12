// DeepSeek Balance — macOS 菜单栏「余额 + 峰谷时段」指示器
//
// 功能：
//   1. 实时（默认每 60 秒）拉取 https://api.deepseek.com/user/balance 显示账户余额
//   2. 按北京时间判定当前处于「高峰时段」还是「空闲时段（谷值）」，并倒计时到下一次切换
//   3. 展示 deepseek-flash / deepseek-v4-pro 在当前时段的单价
//
// 编译： swiftc -O -swift-version 5 Sources/main.swift -o "DeepSeek Balance.app/Contents/MacOS/DeepSeekBalance"

import AppKit
import Foundation

// MARK: - 常量

private let beijingTZ = TimeZone(identifier: "Asia/Shanghai")!
private let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
private let platformURL = URL(string: "https://platform.deepseek.com/usage")!

private let configDirPath = NSString(string: "~/.deepseek-balance").expandingTildeInPath
private let configFilePath = configDirPath + "/config.json"
private let dshCredentialsPath = NSString(string: "~/.dsh/.credentials.yaml").expandingTildeInPath
private let launchAgentPath = NSString(string: "~/Library/LaunchAgents/com.deepseek.balance.plist").expandingTildeInPath
private let launchAgentLabel = "com.deepseek.balance"

/// 高峰时段（北京时间，周一至周五）：09:00-12:00、14:00-18:00，其余全部为空闲时段。
/// 空闲时段单价 = 高峰时段单价 × 0.5。
private let peakWindows: [(start: Int, end: Int)] = [(9 * 60, 12 * 60), (14 * 60, 18 * 60)]

/// 单价（元 / 百万 tokens）——此处为「空闲时段」价格，高峰时段需 ×2。
private struct ModelPrice {
    let name: String
    let hit: Double      // 输入 · 缓存命中
    let miss: Double     // 输入 · 缓存未命中
    let out: Double      // 输出
}

private let modelPrices: [ModelPrice] = [
    ModelPrice(name: "deepseek-flash",   hit: 0.02, miss: 1.0, out: 4.0),
    ModelPrice(name: "deepseek-v4-pro",  hit: 0.15, miss: 4.5, out: 13.5),
]

// MARK: - 峰谷判定

private func isPeak(_ date: Date) -> Bool {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = beijingTZ
    let c = cal.dateComponents([.weekday, .hour, .minute], from: date)
    guard let wd = c.weekday, let h = c.hour, let m = c.minute else { return false }
    guard (2...6).contains(wd) else { return false }  // 1 = 周日 ... 7 = 周六
    let minutes = h * 60 + m
    return peakWindows.contains { minutes >= $0.start && minutes < $0.end }
}

/// 下一次峰谷切换的时刻（分钟精度）
private func nextTransitionDate(from now: Date) -> Date {
    let current = isPeak(now)
    var probe = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.up) * 60)
    for _ in 0..<(60 * 24 * 10) {
        if isPeak(probe) != current { return probe }
        probe = probe.addingTimeInterval(60)
    }
    return now
}

private func humanDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    if total <= 0 { return "即将切换" }
    let d = total / 86400
    let h = (total % 86400) / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if d > 0 { return "\(d) 天 \(h) 小时" }
    if h > 0 { return "\(h) 小时 \(m) 分" }
    if m > 0 { return "\(m) 分 \(s) 秒" }
    return "\(s) 秒"
}

// MARK: - 小工具

private let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeZone = beijingTZ
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "HH:mm:ss"
    return f
}()

private let dateTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeZone = beijingTZ
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "M月d日 HH:mm"
    return f
}()

private func money(_ raw: String) -> String {
    guard let v = Double(raw) else { return raw }
    return String(format: "%.2f", v)
}

/// 价格：整数不带小数，其余保留有效小数（0.02 / 1 / 4 / 4.5 / 13.5）
private func price(_ v: Double) -> String { String(format: "%g", v) }

/// 字符串的终端显示宽度（中日韩字符按 2 列计）
private func displayWidth(_ s: String) -> Int {
    var w = 0
    for u in s.unicodeScalars {
        let v = u.value
        let wide = (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0xA4CF)
            || (v >= 0xAC00 && v <= 0xD7A3) || (v >= 0xF900 && v <= 0xFAFF)
            || (v >= 0xFE30 && v <= 0xFE6F) || (v >= 0xFF00 && v <= 0xFF60)
            || (v >= 0xFFE0 && v <= 0xFFE6)
        w += wide ? 2 : 1
    }
    return w
}

/// 右侧补空格到指定显示宽度（至少保留 1 个空格，避免标签与数值粘连）
private func pad(_ s: String, to width: Int) -> String {
    s + String(repeating: " ", count: max(1, width - displayWidth(s)))
}

private func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}

// MARK: - 配置

private struct AppConfig: Codable {
    var api_key: String?
    var refresh_seconds: Double?
    var auto_refresh: Bool?
}

private func readConfig() -> AppConfig? {
    guard let data = FileManager.default.contents(atPath: configFilePath) else { return nil }
    return try? JSONDecoder().decode(AppConfig.self, from: data)
}

@discardableResult
private func writeConfig(_ cfg: AppConfig) -> Bool {
    try? FileManager.default.createDirectory(atPath: configDirPath, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(cfg) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: configFilePath))) != nil
}

private func ensureConfigExists() {
    guard !FileManager.default.fileExists(atPath: configFilePath) else { return }
    writeConfig(AppConfig(api_key: "", refresh_seconds: 60, auto_refresh: true))
}

/// API Key 解析顺序：环境变量 → 本应用 config.json → DSH 凭证文件
private func resolveAPIKey() -> (key: String?, source: String) {
    let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let env, !env.isEmpty { return (env, "环境变量 DEEPSEEK_API_KEY") }

    if let k = readConfig()?.api_key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
        return (k, configFilePath)
    }

    if let text = try? String(contentsOfFile: dshCredentialsPath, encoding: .utf8),
       let k = firstMatch(#"DEEPSEEK_API_KEY:\s*(\S+)"#, in: text) {
        return (k, dshCredentialsPath)
    }
    return (nil, "未找到（可写入 \(configFilePath) 的 api_key 字段）")
}

// MARK: - 余额接口

private struct BalanceResponse: Decodable {
    struct Info: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String
    }
    let isAvailable: Bool
    let balanceInfos: [Info]
}

private struct APIErrorBody: Decodable {
    struct Inner: Decodable { let message: String? }
    let error: Inner?
}

/// 接口返回 snake_case（total_balance / is_available …），统一转换后解码
private func decodeBalance(_ data: Data) throws -> BalanceResponse {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(BalanceResponse.self, from: data)
}

private func parseErrorMessage(_ data: Data?, status: Int) -> String {
    if let data, let body = try? JSONDecoder().decode(APIErrorBody.self, from: data),
       let msg = body.error?.message, !msg.isEmpty {
        return "HTTP \(status)：\(msg)"
    }
    if status == 401 { return "HTTP 401：API Key 无效或已过期" }
    return "HTTP \(status)"
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var apiKey: String?
    private var keySource: String = ""
    private var balance: BalanceResponse.Info?
    private var balanceCurrency: String = "CNY"
    private var isAvailable: Bool = true
    private var lastError: String?
    private var lastUpdated: Date?

    private var refreshSeconds: Double = 60
    private var autoRefresh: Bool = true
    private var refreshTimer: Timer?
    private var titleTimer: Timer?
    private var inFlight = false

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ensureConfigExists()

        let cfg = readConfig()
        refreshSeconds = cfg?.refresh_seconds ?? 60
        autoRefresh = cfg?.auto_refresh ?? true
        let resolved = resolveAPIKey()
        apiKey = resolved.key
        keySource = resolved.source

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .noImage
            button.toolTip = "DeepSeek 余额与峰谷时段"
        }
        menu.delegate = self
        statusItem.menu = menu

        render()
        if apiKey != nil { refreshBalance() }

        scheduleRefreshTimer()
        // 每 5 秒仅重绘菜单栏标题：保证峰谷切换在边界后 5 秒内反映出来（不发请求）
        titleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.renderTitle()
        }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        guard autoRefresh else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: max(15, refreshSeconds), repeats: true) { [weak self] _ in
            self?.refreshBalance()
        }
    }

    private func persist() {
        var cfg = readConfig() ?? AppConfig(api_key: "", refresh_seconds: 60, auto_refresh: true)
        cfg.refresh_seconds = refreshSeconds
        cfg.auto_refresh = autoRefresh
        writeConfig(cfg)
    }

    // MARK: 网络

    func refreshBalance() {
        guard let key = apiKey else { render(); return }
        guard !inFlight else { return }
        inFlight = true

        var req = URLRequest(url: balanceURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                defer { self.render() }

                if let error {
                    self.lastError = "网络错误：\(error.localizedDescription)"
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.lastError = "无响应"
                    return
                }
                guard http.statusCode == 200, let data else {
                    self.lastError = parseErrorMessage(data, status: http.statusCode)
                    return
                }
                do {
                    let decoded = try decodeBalance(data)
                    self.balance = decoded.balanceInfos.first
                    self.balanceCurrency = decoded.balanceInfos.first?.currency ?? "CNY"
                    self.isAvailable = decoded.isAvailable
                    self.lastError = nil
                    self.lastUpdated = Date()
                } catch {
                    self.lastError = "解析响应失败：\(error.localizedDescription)"
                }
            }
        }.resume()
    }

    // MARK: 渲染

    private func render() {
        renderTitle()
        rebuildMenu()
    }

    private func symbol(for currency: String) -> String { currency == "USD" ? "$" : "¥" }

    private func renderTitle() {
        guard let button = statusItem?.button else { return }
        let peak = isPeak(Date())

        let title = NSMutableAttributedString()
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let small = NSFont.systemFont(ofSize: 11, weight: .semibold)

        if let err = lastError, balance == nil {
            title.append(NSAttributedString(string: "DS ", attributes: [.font: mono]))
            title.append(NSAttributedString(string: "⚠︎", attributes: [
                .font: small, .foregroundColor: NSColor.systemRed,
            ]))
            button.attributedTitle = title
            button.toolTip = "DeepSeek：\(err)"
            return
        }

        let amount = balance.map { money($0.totalBalance) } ?? "—"
        title.append(NSAttributedString(string: "\(symbol(for: balanceCurrency))\(amount) ", attributes: [.font: mono]))
        title.append(NSAttributedString(string: "●", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: peak ? NSColor.systemOrange : NSColor.systemGreen,
        ]))
        title.append(NSAttributedString(string: peak ? "峰" : "谷", attributes: [
            .font: small,
            .foregroundColor: peak ? NSColor.systemOrange : NSColor.systemGreen,
        ]))
        button.attributedTitle = title

        var tip = peak ? "高峰时段（全价）" : "空闲时段（谷值 · 半价）"
        tip += "\n北京时间 \(clockFormatter.string(from: Date()))"
        if let b = balance {
            tip += "\n总余额 \(symbol(for: balanceCurrency))\(money(b.totalBalance))"
        }
        if let err = lastError { tip += "\n⚠︎ \(err)" }
        button.toolTip = "DeepSeek " + tip
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // —— 余额 ——
        menu.addItem(sectionHeader("DeepSeek 账户余额"))
        if let b = balance {
            let cur = symbol(for: balanceCurrency)
            menu.addItem(info("总余额", "\(cur)\(money(b.totalBalance))"))
            menu.addItem(info("充值余额", "\(cur)\(money(b.toppedUpBalance))"))
            menu.addItem(info("赠送余额", "\(cur)\(money(b.grantedBalance))"))
            if !isAvailable {
                menu.addItem(info("状态", "余额不足，API 不可用", tint: .systemRed))
            }
        } else if apiKey == nil {
            menu.addItem(info("状态", "未找到 API Key", tint: .systemRed))
            menu.addItem(link("如何配置 API Key…") { [weak self] in self?.showKeyHelp() })
        } else {
            menu.addItem(info("状态", lastError ?? "正在加载…", tint: lastError == nil ? nil : .systemRed))
        }

        menu.addItem(.separator())

        // —— 峰谷 ——
        let now = Date()
        let peak = isPeak(now)
        let next = nextTransitionDate(from: now)
        menu.addItem(sectionHeader("峰谷时段（北京时间）"))
        menu.addItem(info("当前时段", peak ? "高峰时段 · 全价" : "空闲时段 · 半价",
                          tint: peak ? .systemOrange : .systemGreen))
        menu.addItem(info(peak ? "距离转入空闲" : "距离转入高峰",
                          "\(humanDuration(next.timeIntervalSince(now)))（\(dateTimeFormatter.string(from: next))）"))
        menu.addItem(info("高峰时段", "周一至周五 09:00–12:00、14:00–18:00"))
        menu.addItem(info("空闲时段", "其余全部时间（含夜间与周末）"))

        // —— 价格表 ——
        let priceItem = NSMenuItem(title: "当前时段单价（元 / 百万 tokens）", action: nil, keyEquivalent: "")
        let priceMenu = NSMenu()
        for m in modelPrices {
            let factor = peak ? 2.0 : 1.0
            let sub = NSMenuItem(title: m.name, action: nil, keyEquivalent: "")
            let subMenu = NSMenu()
            subMenu.addItem(info("输入 · 缓存命中", price(m.hit * factor), width: 18))
            subMenu.addItem(info("输入 · 缓存未命中", price(m.miss * factor), width: 18))
            subMenu.addItem(info("输出", price(m.out * factor), width: 18))
            sub.submenu = subMenu
            priceMenu.addItem(sub)
        }
        priceMenu.addItem(.separator())
        priceMenu.addItem(info("空闲价", "= 高峰价 × 0.5"))
        priceItem.submenu = priceMenu
        menu.addItem(priceItem)

        menu.addItem(.separator())

        // —— 操作 ——
        if let lastUpdated {
            menu.addItem(info("上次更新", clockFormatter.string(from: lastUpdated)))
        }
        menu.addItem(info("数据来源", keySource))

        let refresh = NSMenuItem(title: "立即刷新", action: #selector(actionRefresh), keyEquivalent: "r")
        refresh.keyEquivalentModifierMask = [.command]
        refresh.target = self
        menu.addItem(refresh)

        let auto = NSMenuItem(title: "自动刷新", action: #selector(actionToggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = autoRefresh ? .on : .off
        menu.addItem(auto)

        let intervalItem = NSMenuItem(title: "刷新频率", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for secs in [30.0, 60.0, 300.0, 900.0] {
            let label = secs < 60 ? "\(Int(secs)) 秒" : "\(Int(secs / 60)) 分钟"
            let it = NSMenuItem(title: label, action: #selector(actionSetInterval(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = secs
            it.state = abs(refreshSeconds - secs) < 1 ? .on : .off
            intervalMenu.addItem(it)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        menu.addItem(.separator())
        menu.addItem(link("打开 DeepSeek 用量与账单页") {
            NSWorkspace.shared.open(platformURL)
        })
        menu.addItem(link("打开配置文件") { [weak self] in self?.openConfigFile() })

        let login = NSMenuItem(title: "开机自动启动", action: #selector(actionToggleLogin), keyEquivalent: "")
        login.target = self
        login.state = FileManager.default.fileExists(atPath: launchAgentPath) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 DeepSeek Balance", action: #selector(actionQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: 菜单构造辅助

    private func sectionHeader(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    private func info(_ label: String, _ value: String, tint: NSColor? = nil, width: Int = 16) -> NSMenuItem {
        let item = NSMenuItem()
        let attr = NSMutableAttributedString(string: pad(label, to: width), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        attr.append(NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: tint ?? NSColor.labelColor,
        ]))
        item.attributedTitle = attr
        item.isEnabled = false
        return item
    }

    private func link(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(actionRunClosure(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ClosureBox(handler)
        return item
    }

    private final class ClosureBox {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc private func actionRunClosure(_ sender: NSMenuItem) {
        (sender.representedObject as? ClosureBox)?.run()
    }

    // MARK: 动作

    @objc private func actionRefresh() { refreshBalance() }

    @objc private func actionToggleAuto() {
        autoRefresh.toggle()
        persist()
        scheduleRefreshTimer()
        if autoRefresh { refreshBalance() }
        render()
    }

    @objc private func actionSetInterval(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Double else { return }
        refreshSeconds = secs
        persist()
        scheduleRefreshTimer()
        render()
    }

    @objc private func actionToggleLogin() {
        let on = !FileManager.default.fileExists(atPath: launchAgentPath)
        if on {
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist: [String: Any] = [
                "Label": launchAgentLabel,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? FileManager.default.createDirectory(
                    atPath: (launchAgentPath as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: launchAgentPath))
            }
        } else {
            try? FileManager.default.removeItem(atPath: launchAgentPath)
        }
        render()
    }

    @objc private func actionQuit() { NSApp.terminate(nil) }

    private func openConfigFile() {
        ensureConfigExists()
        NSWorkspace.shared.open(URL(fileURLWithPath: configFilePath))
    }

    private func showKeyHelp() {
        let alert = NSAlert()
        alert.messageText = "未找到 DeepSeek API Key"
        alert.informativeText = """
        按以下任一方式配置即可：

        1. 在 ~/.deepseek-balance/config.json 的 "api_key" 字段填入你的 Key；
        2. 或设置环境变量 DEEPSEEK_API_KEY（需重启本应用）；
        3. 本应用也会自动复用 DeepSeek Harness 的凭证 ~/.dsh/.credentials.yaml。

        获取 Key：https://platform.deepseek.com/api_keys
        """
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "打开配置目录")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: configDirPath))
        }
    }

    // MARK: 自检输出

    func dumpUI() {
        if let button = statusItem.button {
            print("菜单栏标题： \(button.attributedTitle.string)")
            print("悬停提示：   \((button.toolTip ?? "").replacingOccurrences(of: "\n", with: " / "))")
        }
        print("\n--- 下拉菜单 ---")
        dump(menu, indent: 0)
    }

    private func dump(_ menu: NSMenu, indent: Int) {
        let lead = String(repeating: "  ", count: indent)
        for item in menu.items {
            if item.isSeparatorItem { print("\(lead)  ────────────"); continue }
            let title = (item.attributedTitle?.string ?? item.title)
                .replacingOccurrences(of: " {2,}", with: "  ", options: .regularExpression)
            var flags: [String] = []
            if !item.isEnabled { flags.append("只读") }
            if item.state == .on { flags.append("✓") }
            if !item.keyEquivalent.isEmpty { flags.append("⌘\(item.keyEquivalent)") }
            print("\(lead)  • \(title)\(flags.isEmpty ? "" : "  [\(flags.joined(separator: " "))]")")
            if let sub = item.submenu { dump(sub, indent: indent + 1) }
        }
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        if autoRefresh { refreshBalance() }
    }
}

// MARK: - 自检（不启动界面）

private func runSelfTest() {
    let fmt = DateFormatter()
    fmt.timeZone = beijingTZ
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd HH:mm"

    let cases: [(String, Bool)] = [
        ("2026-09-12 23:37", false),  // 周六夜间 → 谷
        ("2026-09-13 10:00", false),  // 周日白天 → 谷
        ("2026-09-14 08:59", false),  // 周一 08:59 → 谷
        ("2026-09-14 09:00", true),   // 周一 09:00 → 峰
        ("2026-09-14 11:59", true),
        ("2026-09-14 12:00", false),  // 午休 → 谷
        ("2026-09-14 13:59", false),
        ("2026-09-14 14:00", true),
        ("2026-09-18 17:59", true),   // 周五
        ("2026-09-18 18:00", false),
        ("2026-09-19 10:00", false),  // 周六 → 谷
    ]

    print("=== 峰谷判定自检（北京时间）===")
    var failures = 0
    for (stamp, expected) in cases {
        guard let date = fmt.date(from: stamp) else { print("无法解析 \(stamp)"); failures += 1; continue }
        let actual = isPeak(date)
        let ok = actual == expected
        if !ok { failures += 1 }
        print("\(ok ? "✅" : "❌") \(stamp)  期望=\(expected ? "峰" : "谷")  实际=\(actual ? "峰" : "谷")")
    }

    let now = Date()
    let peakNow = isPeak(now)
    let next = nextTransitionDate(from: now)
    print("\n=== 当前状态 ===")
    print("现在：\(fmt.string(from: now)) CST  →  \(peakNow ? "高峰时段（全价）" : "空闲时段（谷值 · 半价）")")
    print("下一次切换：\(fmt.string(from: next)) CST（\(humanDuration(next.timeIntervalSince(now))) 后）→ \(isPeak(next) ? "高峰" : "空闲")")

    print("\n=== 单价（元 / 百万 tokens，当前时段）===")
    for m in modelPrices {
        let f = peakNow ? 2.0 : 1.0
        print("\(pad(m.name, to: 18)) 输入命中 \(price(m.hit * f))  输入未命中 \(price(m.miss * f))  输出 \(price(m.out * f))")
    }

    let resolved = resolveAPIKey()
    print("\n=== API Key ===")
    if let k = resolved.key {
        print("来源：\(resolved.source)")
        print("前缀：\(k.prefix(7))…（长度 \(k.count)）")
    } else {
        print("未找到：\(resolved.source)")
    }

    print("\n=== 余额接口 ===")
    if let key = resolved.key {
        var req = URLRequest(url: balanceURL)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let sem = DispatchSemaphore(value: 0)
        var out = ""
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { out = "❌ 网络错误：\(err.localizedDescription)"; return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200, let data else {
                out = "❌ \(parseErrorMessage(data, status: status))"; return
            }
            guard let decoded = try? decodeBalance(data),
                  let first = decoded.balanceInfos.first else {
                out = "❌ 响应解析失败"; return
            }
            out = "✅ 可用=\(decoded.isAvailable)  总余额 \(first.currency) \(money(first.totalBalance))"
                + "（充值 \(money(first.toppedUpBalance)) + 赠送 \(money(first.grantedBalance))）"
        }.resume()
        _ = sem.wait(timeout: .now() + 25)
        print(out.isEmpty ? "❌ 请求超时" : out)
    } else {
        print("跳过（无 Key）")
    }

    print("\n结果：\(failures == 0 ? "全部通过 ✅" : "\(failures) 个用例失败 ❌")")
}

// MARK: - 入口

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
    exit(0)
} else if CommandLine.arguments.contains("--dump-ui") {
    // 真实构建菜单栏与菜单，把结果渲染成文字打印后退出（用于自动化验证）
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification))
    RunLoop.current.run(until: Date().addingTimeInterval(6))
    delegate.dumpUI()
    exit(0)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
