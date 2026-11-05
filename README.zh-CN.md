<div align="center">

# O

**一款原生 macOS 磁盘清理工具：清理默认只移入废纸篓；唯一的永久操作是清空废纸篓本身，且必须先确认。**

[English](README.md) · [简体中文](README.zh-CN.md)

[![Release](https://img.shields.io/github/v/release/gascs/O?sort=semver)](https://github.com/gascs/O/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black.svg)](#环境要求)
[![CI](https://github.com/gascs/O/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gascs/O/actions/workflows/ci.yml)

</div>

---

O 是一个用 SwiftUI 编写的 macOS 磁盘清理与系统工具：看清磁盘被什么占用、找出可以安全释放的空间，**默认把文件移入废纸篓** —— 清理过程不调用 shell、不静默提权、无遥测。唯一的例外是**废纸篓**分类：清空它是永久删除，必须经过明确的二次确认。

| 首页（浅色） | 首页（深色） |
| --- | --- |
| ![首页浅色](Docs/01-home-light.png) | ![首页深色](Docs/01-home-dark.png) |

| 清理 | 规则 |
| --- | --- |
| ![清理](Docs/02-clean-light.png) | ![规则](Docs/09-rules-light.png) |

> 浅色为当前首页截图；深色为历史截图，顶部略有裁切、且并非所有卡片都与浅色图处于同一状态，此处仅用于对比配色。

## 功能

- **顶部导航** —— 六页（首页 · 清理 · 空间 · 应用 · 系统 · 规则）平铺在 46pt 紧凑导航条，⌘1–⌘6 直达；860×600 最小窗口下不换行不截断。
- **首页** —— 芯片、核心数、内存、GPU、屏幕分辨率与缩放、序列号末四位；macOS 版本与构建号、运行时长、启动磁盘、电池健康与循环次数、热压力、本地网络接口与 IP。实时图表（CPU 折线、内存分段条、磁盘占用环、网络上下行速率）2 秒采样，窗口隐藏时降为 10 秒。所有数值来自真实系统 API（sysctl / IOKit / Metal / getifaddrs），读不到就显示「不可用」并说明原因，绝不伪造。
- **规则驱动的清理** —— 扫描按用户可编辑的规则执行，而不是写死的分类。**14 类来源**：用户缓存、应用日志、Xcode 派生数据、废纸篓、大文件扫描（下载 / 文稿 / 桌面 / 影片）、应用残留（Application Support / Containers / Group Containers / Saved Application State / HTTPStorages）、诊断报告、开发者产物、包管理器缓存、Docker、iOS 备份、邮件附件、个人文件、系统缓存副本。
- **规则页** —— 三档预设（**保守 5 条 / 标准 47 条 / 激进 58 条**），逐条增删改停，受保护路径清单，扫描后回填每条规则的预计可释放空间与命中数。谨慎级规则启用需二次确认。
- **首次启动引导** —— 四步：为什么需要权限、当前真实探测状态、如何去授权、清理规则引擎怎么用。可跳过，之后在 系统 › 权限 重新打开。
- **菜单栏常驻** —— 模板图标（系统按外观着色），紧凑面板展示磁盘 / CPU / 内存 / 网络 / 电池，扫描状态与主窗口同步。
- **M2 设计系统** —— 暖纸 `#F5F4ED` / 暖黑 `#141318`，墨蓝 `#144A74` 唯一强调色，衬线标题 + SF Pro 正文 + 等宽 tabular 数字，1px 细线，克制动效，自动跟随深浅色。

## 菜单栏

![菜单栏面板](Docs/10-menubar-light.png)

菜单栏面板一眼展示磁盘、CPU、内存、网络与电池，扫描状态与主窗口同步，并可直接进入扫描、主窗口、设置、权限与概览。

## 规则引擎

| 能力 | 说明 |
| --- | --- |
| 规则模型 | 名称、类别、路径（支持 `~` 展开）、最小年龄（天）、最小体积（MB）、安全等级（安全 / 建议 / 谨慎）、是否启用、说明、扫描方式 |
| 校验规范 | 每次保存都经过 `PathSafety` 与规则校验：空路径、相对路径、主目录本身、系统前缀、主目录外、`~/Library` 根、符号链接逃逸（先解析符号链接再校验白名单）、受保护路径一律拒绝并**给出原因**；同一配置内不允许重复路径；禁止目录比较大小写不敏感（`~/library` 等同 `~/Library`） |
| 预设 | 保守 · 标准 · 激进一键套用，之后仍可逐条编辑；激进预设套用前二次确认 |
| 导入 / 导出 | JSON 带元数据信封（格式版本、应用版本、导出时间），文件名带时间戳。导入时可选**合并到现有规则 / 替换全部**：合并保留现有规则并跳过同路径条目，替换则整套换掉；非法条目逐条跳过并报告原因，绝不静默丢弃。导入规则不保留 `safe` 级（降为建议级），用户文件类规则强制为谨慎级，指向敏感位置（`~/.ssh`、钥匙串、Mail / Safari 数据、`~/Library` 根等）的规则一律拒绝 |
| 受保护清单 | 加入的路径永不清理；导入时保护清单按并集合并 |
| 预计空间 | 每条规则的可释放体积与命中数来自一次真实规则扫描；父子规则根嵌套去重，不会重复计量 |

扫描为后台流式执行：可取消，进度 150ms 节流回调、界面 100ms 合并刷新，显示 ETA，避免符号链接环与重复遍历，重叠的缓存根会去重，权限不足的路径记录跳过原因而不是报错，超大结果集按统一阈值截断并同步重算 `totalBytes`。

## 支持的编程语言与工具链

0.5.0 新增 **25 条**缓存规则：**标准预设 21 条**（均为安全级，默认 7 天未访问才清理，另注明者除外），**激进预设 4 条**。路径均为 macOS 上各工具的默认缓存位置，与其它规则一样经过 `PathSafety` / `RuleValidator` 校验。

| 工具链 | 缓存路径 | 等级 | 预设 |
| --- | --- | --- | --- |
| SwiftPM | `~/Library/Caches/org.swift.swiftpm` | 安全 | 标准 |
| Deno | `~/Library/Caches/deno` | 安全 | 标准 |
| Bun | `~/.bun/install/cache` | 安全 | 标准 |
| uv（Python） | `~/Library/Caches/uv` | 安全 | 标准 |
| Poetry | `~/Library/Caches/pypoetry` | 安全 | 标准 |
| RubyGems | `~/.gem` | 安全 | 标准 |
| Bundler | `~/.bundle/cache` | 安全 | 标准 |
| Hex（Elixir） | `~/.hex` | 安全 | 标准 |
| Cabal（Haskell） | `~/.cabal/packages` | 安全 | 标准 |
| Stack（Haskell） | `~/.stack` | 安全 | 标准（30 天） |
| opam（OCaml） | `~/.opam/download-cache` | 安全 | 标准 |
| NuGet（.NET） | `~/.nuget/packages` | 安全 | 标准（30 天） |
| Dart pub | `~/.pub-cache` | 安全 | 标准 |
| Bazel | `~/.cache/bazel` | 安全 | 标准 |
| Zig | `~/.cache/zig` | 安全 | 标准 |
| Conan（C/C++） | `~/.conan2/p` | 安全 | 标准 |
| Ivy（Java） | `~/.ivy2/cache` | 安全 | 标准 |
| node-gyp | `~/Library/Caches/node-gyp` | 安全 | 标准 |
| Electron | `~/Library/Caches/electron` | 安全 | 标准 |
| Carthage | `~/Library/Caches/org.carthage.CarthageKit` | 安全 | 标准 |
| JetBrains 系列 IDE | `~/Library/Caches/JetBrains` | 安全 | 标准 |
| Go 模块 | `~/go/pkg/mod` | 谨慎 | 激进（30 天） |
| VS Code 缓存数据 | `~/Library/Application Support/Code/CachedData` | 建议 | 激进（30 天） |
| Flutter pub 缓存 | `~/.flutter/pub` | 谨慎 | 激进（30 天） |
| Conda 包缓存 | `~/opt/anaconda3/pkgs` | 谨慎 | 激进（30 天，≥ 50 MB） |

npm / yarn / pnpm / pip / Homebrew / Go 构建缓存 / Cargo / Gradle / Maven / CocoaPods 的缓存由 0.4.x 起就有的包管理器规则覆盖；Xcode 派生数据与模拟器仍在独立分类中。欢迎继续补充 —— 新增规则清单见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 性能与算法

0.5.0 重做了扫描与刷新的热路径，磁盘扫描时界面不再卡顿：

- **移出主线程** —— 概览（每 2 秒）与菜单栏（每 5 秒）的磁盘 / 网络 / IOKit 采样改到后台执行；两处共用同一个采样器，不再各跑一套循环。
- **历史解码缓存** —— 概览不再每个 tick 全量解码历史 JSON，只缓存并复用最新扫描摘要，数据变化时才重解码。
- **代次防竞态** —— 扫描、清理与后台可清理估算都带代次标记；被取消任务的迟到回调不会覆盖新任务的进度或报告，后台估算也不会盖掉用户手动发起的扫描结果。
- **Top-N 选择** —— 大文件与重复文件结果改为有界插入（`O(n·log k)`），不再全量排序，同时仍保留总数供界面展示。
- **稳定排序** —— 大文件排序比较器修复了 `descending ? !result : result` 在相等时返回错误值的问题，并以路径作为明确的次级排序键。
- **增量列表** —— 进度以低频合并刷新主线程，扫描中的列表按 diff/追加更新，而不是每次重建整个数组。
- **截断与去重一致** —— 已被更具体规则根覆盖的缓存目录会跳过；结果集截断后同步重算 `totalBytes`，展示数字与列表一致。

## 快捷键

| 快捷键 | 作用 |
| --- | --- |
| `⌘1 … ⌘6` | 首页 / 清理 / 空间 / 应用 / 系统 / 规则 |
| `⇧⌘R` | 开始扫描 |
| `⌘⌫` | 清理所选项 |
| `⇧⌘E` | 导出报告 |
| `⌘F` | 聚焦搜索 |
| `⌘R` | 刷新当前页 |
| `⌘,` | 打开设置 |

## 环境要求

- macOS 13 Ventura 或更高（在 macOS 13 / 14 / 15 上开发与测试）。
- Apple Silicon（arm64）或 Intel（x86_64）—— 发布的 DMG 是 **universal** 二进制。
- 无第三方依赖、无需包管理器、日常清理不需要管理员密码。

## 安装

**DMG 方式** —— 从 [Releases](https://github.com/gascs/O/releases/latest) 下载 `O-0.5.0.dmg`，先校验再打开，把 **O** 拖入 Applications：

```bash
# 两个文件放在同一目录：
shasum -a 256 -c O-0.5.0.dmg.sha256
# 或打印摘要，与 Release 页面上的值比对：
shasum -a 256 O-0.5.0.dmg
```

DMG 内含 `O.app`、`Applications` 快捷方式与项目 **LICENSE**。

macOS 13 / 14 / 15 首次打开（构建为 ad-hoc 签名、未公证，Gatekeeper 会拦一次）：

1. 被拦截后进入 **系统设置 › 隐私与安全性 › 安全性**，点「仍要打开」，再确认「打开」；
2. 或在 Finder 中右键 **O.app** › **打开** › 「打开」（不要直接双击）；
3. 仍被拦截时执行 `xattr -dr com.apple.quarantine /Applications/O.app` 后再打开。

**源码方式** —— 用 Xcode 打开 `Package.swift`（选 O scheme，⌘R 运行，⌘U 测试），或：

```bash
bash build_app.sh
open .build/app/O.app
```

## 构建与测试

需要 macOS 13+，以及完整 Xcode 或 Command Line Tools（`Package.swift` 为 `swift-tools-version: 5.9`，Swift 5 语言模式）。

```bash
bash doctor.sh        # 只读环境自检，任一异常以非零退出
bash build_app.sh     # release 构建 → .build/app/O.app（尽量 universal）
bash run_tests.sh     # App 编译 + XCTest + SelfTest，分别报告
bash build_dmg.sh     # → dist/O-<版本号>.dmg 与 .dmg.sha256
```

- **版本号单一来源** —— 只需改 `VERSION`。`VERSION`、`Info.plist`（`CFBundleShortVersionString`）与 `Components.swift` 的 `AppInfo.fallbackVersion` 三者不一致时，`build_app.sh` / `build_dmg.sh` / `doctor.sh` 直接报错退出。
- **XCTest** —— 一套用例，覆盖路径安全、扫描器行为、废纸篓服务、规则（预设、校验、持久化、JSON 往返、宽松导入、合并去重、扫描过滤）、重复文件、启动项、关窗与单实例。测试已做隔离：用临时目录构造 home，不写真实 `$HOME`，受限沙箱与 CI 下可稳定通过。
- **SelfTest** —— 不依赖 XCTest 的断言级自检（无 Xcode 也能跑），包含一次**真实**的移入废纸篓往返（创建临时文件 → 移入废纸篓 → 校验 → 清理测试产物）。两套测试的真实数量由 `run_tests.sh` 打印，本文档刻意不硬编码。
- **CI** —— GitHub Actions（`macOS 14`）在每次 push / PR 时跑两套测试与 App 构建并上传 `.app`；推送 `v*` 标签时额外构建 DMG 与 SHA-256 校验文件并作为 workflow artifact 上传。Release 由维护者手动发布，以便撰写发布说明。

内置诊断，无需屏幕录制权限：

```bash
.build/app/O.app/Contents/MacOS/O --ui-audit         # 每页离屏 2x PNG，浅 / 深两套
.build/app/O.app/Contents/MacOS/O --lifecycle-audit  # 关窗驻留与窗口复用
```

## 安全边界

- **默认只进废纸篓。** 普通清理调用 `trashItem`；扫描与清理全过程不包含 `rm`，也不调用 shell。
- **唯一的永久操作必须显式确认。** **废纸篓**分类是永久删除：确认弹窗会写明「永久删除、不可恢复」，`CleanReport` 也把 `movedBytes`（移入废纸篓）与 `freedBytes`（永久删除）分开统计，避免数字混淆。
- **路径白名单。** 系统前缀在扫描与清理之前就被拒绝；符号链接先解析、再以大小写不敏感方式与禁止 / 保护目录比对，最后才走「仍在主目录内」的捷径，因此链接无法逃出白名单。
- **不静默提权。** 应用不主动索取权限；权限缺失时功能降级并解释，而不是报错。
- **清理不调用 shell。** 唯一的进程启动是权限变更后 `PermissionCenter` 用系统 `/usr/bin/open -n` 重启自身；不会执行任何用户或第三方命令。
- **数据不出本机。** 设备信息只读且本地化：无网络上报、无遥测。
- **发布完整性。** DMG 附带 SHA-256 校验文件，App bundle 内含 LICENSE，构建时校验 bundle 内版本与 `VERSION` 一致。

## 已知限制

- 未授权完全磁盘访问时，`~/.Trash`、`~/Library/Mail`、Safari 数据等受保护位置会如实显示受限，而不是计入统计。
- 废纸篓分类的清空在设计上不可恢复 —— 确认前请先看预览清单。
- 磁盘趋势需要连续多天的采样点才有完整曲线。
- 重复文件查找基于 SHA-256，不做视觉相似媒体匹配。
- 应用图标为暖纸浅色；macOS 图标不随深色模式自动切换。
- 界面当前为中文；本地化资源在计划中。
- ad-hoc 签名且未公证：适合本机与小组使用；面向大众分发需配置 Developer ID 签名并公证，详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 参与贡献与安全

- [CONTRIBUTING.md](CONTRIBUTING.md) —— 构建 / 测试 / 新增规则 / 截图重生成 / PR 流程。
- [SECURITY.md](SECURITY.md) —— 私密漏洞上报与威胁模型（符号链接逃逸、规则导入、权限提示、发布完整性）。
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) —— Contributor Covenant 2.1 行为准则。
- [CHANGELOG.md](CHANGELOG.md) —— 版本历史（Keep a Changelog）。

## 许可证

[MIT](LICENSE) © O Project

**免责声明** —— O 是磁盘工具。尽管普通清理只进废纸篓，清空废纸篓分类仍是永久删除；执行前请务必查看确认弹窗与预览清单。作者不对数据丢失承担责任。
