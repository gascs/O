# 贡献指南

感谢你愿意改进 O。O 是一个原生 macOS 13+ SwiftUI 磁盘清理器：**只动白名单内的
用户级缓存与可再生成数据**，默认移入废纸篓，清理过程不调用 shell 命令。

> 参与本仓库即表示你同意遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。
> 安全漏洞请不要开公开 Issue，按 [SECURITY.md](SECURITY.md) 私密上报。

## 环境要求

- macOS 13 Ventura 或更高（开发机建议 macOS 14+）
- 完整 Xcode **或** 仅 Command Line Tools（二选一，脚本会自动适配两条构建路径）
- 无需 CocoaPods / Mint / 任何第三方包管理器：项目是纯 Swift Package，零外部依赖

```bash
xcode-select -p     # 确认工具链路径
swift --version     # Package.swift 为 tools 5.9，语言模式为 Swift 5
bash doctor.sh      # 只读自检：工具链、SDK、SwiftPM、FDA、登录项、版本一致性、DMG 校验
```

`doctor.sh` 任一检查异常时会以非零退出码结束，并给出中文修复建议。

## 构建与运行

```bash
bash build_app.sh                 # 构建 .build/app/O.app（优先 universal，失败显式回退并报错）
bash build_app.sh && open .build/app/O.app
bash build_dmg.sh                 # 产出 dist/O-<版本>.dmg 与 .dmg.sha256
```

构建细节：

- `build_app.sh` 优先产出 universal 二进制：SwiftPM 6.0.3 没有 `--arch` 选项，
  脚本会用 `--triple arm64-apple-macosx13.0` 与 `--triple x86_64-apple-macosx13.0`
  各构建一次，再 `lipo -create` 合并；任一步失败都会**先打印错误**再回退到本机架构；
  SwiftPM 也失败时回退 `swiftc` 直编（自动带 CLT 的 VFS overlay）。
- 版本号唯一来源是仓库根目录 [VERSION](VERSION)。`Info.plist` 的
  `CFBundleShortVersionString` 与 `Sources/MoleLiteApp/Views/Components.swift` 中的
  `AppInfo.fallbackVersion` 必须与之一致，否则 `build_app.sh` / `build_dmg.sh` /
  `doctor.sh` 都会报错并退出。发版时只改 `VERSION` + `AppInfo.fallbackVersion` 两处。
- 无 Developer ID 证书时使用 **ad-hoc 签名**并打印说明；有证书时会自动优先
  `Developer ID Application`（也可用 `O_CODESIGN_IDENTITY` 指定）。ad-hoc 版本
  未公证，只适合本地与小组使用，面向大众分发需另行配置公证。
- 受限沙箱 / CI 中 SwiftPM 需要 `--disable-sandbox`，脚本已默认开启；
  想恢复 SwiftPM 默认沙箱可设 `O_SWIFT_SANDBOX=1`。

## 测试

```bash
bash run_tests.sh                 # [1/3] App target 编译 → [2/3] XCTest → [3/3] SelfTest
swift test --disable-sandbox      # 只跑 XCTest
swift test --disable-sandbox --filter CleanupRulesTests
```

两套测试都要通过：

| 套件 | 内容 | 计数方式 |
| --- | --- | --- |
| XCTest（`Tests/MoleLiteCoreTests`） | ByteFormatter / CleanupRules / Feature / PathSafety / Scanner / TrashService | 用例数 |
| SelfTest（`Tools/SelfTest/main.swift`） | 独立于 XCTest 的断言级复核，可在无 Xcode 环境跑 | 断言数 |

当前基线：**78+ 个 XCTest 用例**，加 SelfTest 断言。`run_tests.sh` 会分别打印两套
的真实数量；某个用例失败时不会把计数清零，而是保留真实数字并非零退出。
新增或删除测试时**不必**手动同步 README 里的数字——README 只写「78+」。

**测试隔离是硬性要求**：新写的测试不得写真实的 `$HOME`、`~/Library`、`~/.Trash`，
必须在 `FileManager.default.temporaryDirectory` 下构造临时 home。历史上正是因为
测试写真实目录，导致在沙箱化 CI 中 19 个用例失败，XCTest 现已全部改为临时 home。

已知偏差：`Tools/SelfTest/main.swift` 仍在真实 `$HOME` 下建隐藏临时子目录
（`~/.o-selftest-rules-<UUID>`、`~/Library/Caches/MoleLiteSelfTest-*.txt`）并在结束时清理。
在禁止写真实主目录的沙箱中运行会失败（`Operation not permitted`）；普通终端与
GitHub Actions runner 不受影响。欢迎把它也改成 `FileManager.default.temporaryDirectory`。

## 新增 / 修改清理规则

规则集中定义在 `Sources/MoleLiteCore/Models/CleanupRule.swift`（预设）与
`Sources/MoleLiteCore/Models/EcosystemRules.swift`（编程语言/工具链缓存）。

新增规则检查清单：

1. **路径必须真实存在**——在对应工具安装后的默认位置；使用 `~/` 开头，不要绝对路径、
   不要通配符、不要 glob。
2. **只指向可再生成数据**：包/依赖/编译缓存、日志、派生数据。不要指向
   `~/Library` 根目录、`~/Library/Preferences`、钥匙串、Mail / Safari 数据、`~/.ssh` 等。
3. 字段齐全：唯一 `id`（生态规则用 `eco.` 前缀）、中文 `name`、`category`、
   `minAgeDays`、`minSizeMB`、`grade`、一句中文 `note`、`scanMode`。
4. 分级要保守：会连带重下载或重建的用 `.suggested`；可能影响已装环境/需要重编译的用
   `.caution`；`.safe` 只给纯缓存。
5. 同步预设计数：保守 5 / 标准 47 / 激进 58 基于当前规则集；加减规则后必须同步
   `CleanupRuleCatalog` 的数组与文档中的数量，否则会被 `CleanupRulesTests` 抓到。
6. 跑 `bash run_tests.sh`，确认 `CleanupRulesTests` 与 `PathSafetyTests` 全绿。

规则导入（`RulesStore`）不允许保留 `.safe` 级或指向敏感目录的规则——导入时的降级与
拒绝逻辑由 `RuleValidator` 与测试共同保证，改动它必须补测试。

## 代码风格

- 4 空格缩进、LF、文件末尾保留换行；行宽约 120（见 [.editorconfig](.editorconfig)）。
- 不引入第三方依赖；优先 Foundation / SwiftUI / AppKit 系统 API。
- 注释用中文，解释「为什么」而不是复述「做了什么」。
- 磁盘操作必须走 `PathSafety` 校验；不要直接拼 `FileManager.removeItem` 的路径。
- 清理流程**不得**调用 shell（`Process`/`/bin/sh`）。唯一例外是权限变更后重启 App：
  `PermissionCenter` 会用 `/usr/bin/open -n` 打开自身，这是刻意保留的行为。
- 面向用户的字符串默认中文；README 中英双版需保持结构对齐。

## 截图与文档

- 截图由 App 内置的 UI 审计入口生成（`Sources/MoleLiteApp/UIAudit.swift`）：

  ```bash
  .build/app/O.app/Contents/MacOS/O --ui-audit Docs
  ```

  会直接覆盖 `Docs/01-home-light.png`、`02-clean-light.png`、`09-rules-light.png`、
  `10-menubar-light.png` 等文件名。生成后请肉眼检查裁切与状态一致性再提交。
- `Docs/01-home-dark.png` 为历史深色截图：顶部有裁切、且与浅色图状态不完全一致，
  文档已如实说明；如重截请同步更新两版 README 的描述。
- 改动用户可见行为时，同时更新 `README.md`、`README.zh-CN.md` 与 `CHANGELOG.md`。
- 所有 README 中的相对链接与图片必须真实存在（提交前用编辑器点开确认）。

## 提交与 Pull Request

1. Fork 并基于 `main` 开分支，分支名如 `fix/symlink-escape`、`feat/zig-cache-rule`。
2. 一个 PR 只做一件事；不提交 `.build/`、`dist/`、`*.dmg`、`DerivedData/` 等构建产物
   （已在 `.gitignore` 中）。
3. 不要提交版本号以外的发布产物；版本号变更请单独 PR 或由维护者统一处理。
4. PR 描述写清：问题、改动、验证命令与结果（贴 `run_tests.sh` 的汇总行即可）。
5. CI（GitHub Actions，macOS 14）会跑 `run_tests.sh` + `build_app.sh`；
   tag 推送时额外构建 DMG 并附加 SHA-256 校验文件。
6. 维护者可能会要求补测试或拆小 PR——O 直接删除用户文件，安全相关的改动宁慢勿快。
