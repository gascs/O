# 更新日志

本项目的所有重要变更都会记录在此文件。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本 SemVer](https://semver.org/lang/zh-CN/)。
版本号的唯一来源是仓库根目录的 [`VERSION`](VERSION) 文件。

## [Unreleased]

暂无。

## [0.5.0] - 2026-11-05

本次为功能性更新：安全加固、性能优化，并把编程语言 / 工具链缓存纳入规则体系。

### 新增 Added

- **25 条编程语言与工具链缓存规则**（`Sources/MoleLiteCore/Models/EcosystemRules.swift`）：
  - 标准预设 21 条：SwiftPM、Deno、Bun、uv、Poetry、RubyGems、Bundler、Hex、Cabal、
    Stack、opam、NuGet、pub、Bazel、Zig、Conan、Ivy、node-gyp、Electron、Carthage、
    JetBrains。
  - 激进预设 4 条：Go 模块缓存、VS Code 缓存数据（建议级）、Flutter 发布缓存、
    Conda 包缓存。
- **`VERSION` 文件作为唯一版本来源**：`build_app.sh` / `build_dmg.sh` / `doctor.sh`
  会校验 `VERSION`、`Info.plist`、`Components.swift` 三者一致，不一致直接报错退出。
- **DMG 发布硬化**：DMG 内含 `LICENSE`，同时产出 `dist/O-<version>.dmg.sha256`，
  打包脚本自带 `shasum -a 256 -c` 自校验；优先构建 arm64 + x86_64 universal 包，
  失败时显式报错再回退，不静默降级。
- **CI**：新增 GitHub Actions（macOS 14），push / PR 运行两套测试与 App 构建并上传
  `.app` 产物；推送 `v*` 标签时额外构建 DMG 与校验文件并作为 artifact 上传（Release 由维护者手动发布，便于撰写发布说明）。
- **开源配套**：`SECURITY.md`、`CONTRIBUTING.md`、`CODE_OF_CONDUCT.md`、
  本 `CHANGELOG.md`、Issue 模板（macOS 版本 / 芯片架构 / 完全磁盘访问 / 规则预设）、
  `.gitattributes`、`.editorconfig`。
- **`doctor.sh` 增强**：真实安装路径与构建版本比较、VERSION ↔ Components ↔ Info.plist
  一致性、DMG SHA-256 校验、任一异常非零退出。
- 分类列表补齐「大文件扫描」（下载 / 桌面 / 文稿 / 影片中的大文件与旧文件），
  扫描分类共 **14 个**。
- README 中英双版新增「支持的编程语言与工具链」「性能与算法」小节，补充
  Gatekeeper 首次打开步骤、SHA-256 校验命令与 universal 包说明。

### 变更 Changed

- 规则预设更新为 **保守 5 / 标准 47 / 激进 58** 条（原 5 / 26 / 33）。
- README 不再硬编码测试通过数字，测试数量由 `run_tests.sh` 实时打印，随功能演进。
- 构建产物统一使用 `.build/app/`，`build_app.sh` 清理旧 bundle 前会校验路径。
- 无 Developer ID 证书时明确使用 ad-hoc 签名并提示「未公证」，不再静默处理失败。

### 修复 Fixed

- **路径安全**：符号链接解析后先做禁止目录 / 保护目录 / 允许范围校验，再判断是否仍在
  主目录内；禁止与保护目录比较改为大小写不敏感（`~/library` 等同 `~/Library`），
  修复可借符号链接越界删除的路径逃逸问题。
- **⌘⌫ 直接清理**：现在与界面内按钮走同一确认流程；扫描中或未选中时忽略，不再绕过确认。
- **规则导入**：拒绝指向敏感目录（`~/.ssh`、钥匙串、Mail / Safari 数据等）的规则；
  导入的规则不再保留 `safe` 级（降为建议级），用户文件类规则强制为谨慎级。
- **废纸篓分类**：条目改为需显式确认的永久删除，并在确认文案中标注「不可恢复」；
  `CleanReport` 区分 `movedBytes`（移入废纸篓）与 `freedBytes`（永久删除）。
- **扫描去重与截断**：`userCaches` 与包管理器 / 系统缓存分类不再重复统计同一目录；
  大结果集截断阈值统一，截断后 `totalBytes` 同步重算。
- **测试隔离**：测试不再写真实 `$HOME` / `~/Library` / `~/.Trash`，改为临时目录构造 home，
  受限沙箱与 CI 下可稳定通过（此前有 19 个用例因沙箱拦截失败）。

### 性能 Performance

- 磁盘 / 网络采样移出主线程（概览 2 s、菜单栏 5 s 的 IOKit、`getifaddrs`、容量统计），
  菜单栏与主窗口共用同一采样器，去掉重复的两套循环。
- 概览历史不再每个 tick 全量 JSON 解码，改为缓存最新扫描摘要，仅在数据变化时重解码。
- `estimateCleanable()` 可取消并带代次保护，不会覆盖用户手动扫描的进度与报告。
- 大文件 / 重复文件扫描与清理加入代次校验，取消旧任务后旧回调不再把新状态改成「已取消」。
- 大文件结果改为有界插入取 Top-N（`O(n·log k)`），修复排序比较器在相等时返回错误值的问题。
- 进度合并保持低频主线程刷新，扫描中列表增量更新，减少整体重建造成的卡顿。
- 概览新增只读的「废纸篓大小 + 在 Finder 中打开」信息行，不再把废纸篓计入可清理估算。

### 安全 Security

- 详见 [SECURITY.md](SECURITY.md)。本次重点：符号链接路径逃逸、危险规则导入、
  永久删除确认、版本与产物一致性校验。
- 应用仍然**不含遥测、不自动联网**；清理过程不调用 shell 命令，权限变更后重启 App
  仅通过系统 `/usr/bin/open`。

### 已知限制 Known limitations

- DMG 为 ad-hoc 签名且未公证：首次打开需在「系统设置 › 隐私与安全性」点「仍要打开」，
  或右键 O.app › 打开，或执行 `xattr -dr com.apple.quarantine /Applications/O.app`。
- 未授予「完全磁盘访问」时，邮件、Safari 等受保护位置会显示为受限，属预期行为。

## [0.4.0] - 2026-10-30

首个公开版本。

### 新增 Added

- 原生 SwiftUI 菜单栏磁盘清理器，最低支持 macOS 13，零第三方依赖。
- 5 / 26 / 33 条规则的保守 / 标准 / 激进三档预设，支持自定义与导出导入。
- 13 个扫描分类：用户缓存、日志、Xcode 与模拟器、废纸篓、应用残留、诊断报告、
  开发归档、包管理器缓存、Docker、iOS 备份、邮件附件、个人文件、系统缓存副本。
- 「完全磁盘访问」引导与受限项提示；清理默认移入废纸篓，可恢复。
- 规则预览、按大小 / 年龄过滤、扫描结果按分类展示。
- `build_app.sh` / `build_dmg.sh` / `run_tests.sh` / `doctor.sh` 四个本地脚本，
  支持仅 Command Line Tools 的构建路径。
