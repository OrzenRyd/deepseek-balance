# DeepSeek Balance

[![build](https://github.com/OrzenRyd/deepseek-balance/actions/workflows/build.yml/badge.svg)](https://github.com/OrzenRyd/deepseek-balance/actions/workflows/build.yml)
![platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![language](https://img.shields.io/badge/Swift-no%20dependencies-orange)

macOS 菜单栏小软件：**实时显示 DeepSeek 账户余额**，并告诉你**当前是高峰时段还是空闲时段（谷值）**。

菜单栏常驻一行：`¥4.66 ●谷` —— 绿点 = 谷值（半价），橙点 = 峰值（全价），点开就是完整详情。

```
┌────────────────────────────────────────────┐
│  DeepSeek 账户余额                          │
│    总余额   ¥4.66                           │
│    充值余额 ¥4.66                           │
│    赠送余额 ¥0.00                           │
├────────────────────────────────────────────┤
│  峰谷时段（北京时间）                        │
│    当前时段      空闲时段 · 半价             │
│    距离转入高峰  1 天 9 小时（9月14日 09:00）│
│    高峰时段      周一至周五 09:00–12:00、    │
│                  14:00–18:00                │
├────────────────────────────────────────────┤
│  当前时段单价（元 / 百万 tokens）        ▸  │
│  上次更新  23:43:12                         │
│  立即刷新  ⌘R      自动刷新 ✓               │
│  刷新频率  30秒 / 1分钟 / 5分钟 / 15分钟 ▸  │
│  打开 DeepSeek 用量与账单页                  │
│  开机自动启动                               │
│  退出 DeepSeek Balance                  ⌘Q  │
└────────────────────────────────────────────┘
```

## 特性

- **余额实时刷新**：调用官方 `GET /user/balance`，默认每 60 秒一次，打开菜单时也会立刻刷一次
- **峰谷自动判定 + 倒计时**：明确告诉你距离下一次切换还有多久
- **单价随峰谷联动**：价格表按当前时段自动显示全价或半价
- **纯原生、零依赖**：只用系统自带的 `swiftc` + AppKit，产物约 1.6 MB，不占 Dock
- **Key 三种来源自动解析**：环境变量 / 配置文件 / 其它工具的凭证文件

## 安装

### 方式一：下载预编译包

到 [Releases](https://github.com/OrzenRyd/deepseek-balance/releases) 下载 `DeepSeek-Balance-macOS.zip`，解压后把 `DeepSeek Balance.app` 拖进「应用程序」或 `~/Applications`，双击运行。

> 本包为 ad-hoc 签名（未做 Apple 公证）。若首次打开被 Gatekeeper 拦下，右键点图标选「打开」，或执行
> `xattr -dr com.apple.quarantine "/Applications/DeepSeek Balance.app"`。

### 方式二：从源码构建

需要 Xcode Command Line Tools（`xcode-select --install`）。

```bash
git clone https://github.com/OrzenRyd/deepseek-balance.git
cd deepseek-balance
./install.sh     # 编译 → 安装到 ~/Applications → 启动
```

- `./build.sh` —— 只编译打包，产出 `DeepSeek Balance.app`
- 卸载：菜单里选「退出」，然后 `rm -rf ~/Applications/"DeepSeek Balance.app" ~/.deepseek-balance`

## 配置 API Key

余额接口需要 DeepSeek API Key。按以下顺序自动解析，**任一命中即可**：

1. 环境变量 `DEEPSEEK_API_KEY`
2. 本应用配置文件 `~/.deepseek-balance/config.json` 的 `api_key` 字段
3. DeepSeek Harness 的凭证 `~/.dsh/.credentials.yaml`

菜单里的「数据来源」一行会显示当前实际用的是哪一个。若都没有，菜单栏会显示 `⚠︎`，点「如何配置 API Key…」有引导。

### 换一个 Key

```bash
open ~/.deepseek-balance/config.json     # 或从菜单里点「打开配置文件」
```

```json
{
  "api_key": "sk-你的新key",
  "refresh_seconds": 60,
  "auto_refresh": true
}
```

Key 在应用启动时读取，改完退出应用再启动即可。申请地址：<https://platform.deepseek.com/api_keys>

## 峰谷规则

判定完全按官方定义，使用**北京时间（UTC+8）**，与你的系统时区无关：

| | 时间 |
|---|---|
| **高峰时段（全价）** | 周一至周五 `09:00–12:00`、`14:00–18:00` |
| **空闲时段（谷值 · 半价）** | 其余全部时间，含午休、夜间、**整个周末** |

> 空闲时段单价 = 高峰时段单价 × 0.5。
> 来源：[DeepSeek 模型 & 价格](https://api-docs.deepseek.com/zh-cn/quick_start/pricing)

菜单里的价格表会**随峰谷自动翻倍/减半**：

| 模型 | 输入·缓存命中 | 输入·缓存未命中 | 输出 |
|---|---|---|---|
| `deepseek-flash` | 0.02 / 0.04 | 1 / 2 | 4 / 8 |
| `deepseek-v4-pro` | 0.15 / 0.30 | 4.5 / 9 | 13.5 / 27 |

（单位：元 / 百万 tokens，格式为 `空闲价 / 高峰价`）

## 自检（不需要看界面）

```bash
# 验证峰谷判定逻辑 + 当前状态 + 余额接口
"./DeepSeek Balance.app/Contents/MacOS/DeepSeekBalance" --selftest

# 把菜单栏标题与整个下拉菜单渲染成文字打印出来
"./DeepSeek Balance.app/Contents/MacOS/DeepSeekBalance" --dump-ui
```

`--selftest` 会跑一遍峰谷边界用例，例如：

```
✅ 2026-09-14 08:59  期望=谷  实际=谷
✅ 2026-09-14 09:00  期望=峰  实际=峰
✅ 2026-09-14 12:00  期望=谷  实际=谷   ← 午休回到谷值
✅ 2026-09-18 18:00  期望=谷  实际=谷   ← 周五下班
✅ 2026-09-19 10:00  期望=谷  实际=谷   ← 周六全天谷值
```

## 文件结构

```
deepseek-balance/
├── Sources/main.swift            # 全部逻辑：菜单栏 App + 峰谷算法 + 余额接口
├── Tools/MakeIcon.swift          # 用 CoreGraphics 生成 App 图标
├── build.sh                      # 编译打包成 .app
├── install.sh                    # build.sh + 安装到 ~/Applications + 启动
└── .github/workflows/build.yml   # CI：每次推送自动构建并产出 zip
```

## 说明

- 价格与峰谷时段来自 DeepSeek 官方文档，若官方调整需同步修改 `Sources/main.swift` 顶部的 `peakWindows` 与 `modelPrices`。
- 本项目与 DeepSeek 官方无关联，仅调用其公开 API。

## License

[MIT](LICENSE)
