import Foundation

// MARK: - 生态规则（语言 / 工具链缓存）
//
// 覆盖范围：在既有的 Node/Rust/Go/Python/Java 之外，补齐 25 条「语言运行时、
// 包管理器、构建工具链」的默认缓存目录，共 25 条：
//
// 标准（21 条，全部可自动重建，grade = .safe）：
//   SwiftPM、Deno、Bun、uv、Poetry、RubyGems、Bundler、Hex、Cabal、Stack、
//   opam、NuGet、Dart pub、Bazel、Zig、Conan、Ivy、node-gyp、Electron、
//   Carthage、JetBrains。
//
// 激进（4 条，默认不进标准预设，需要逐条确认）：
//   Go 模块缓存（.caution）、VS Code 缓存数据（.suggested）、
//   Flutter 发布缓存（.caution）、Conda 包缓存（.caution）。
//
// 约定：路径一律使用 macOS 默认安装位置（仅主目录内、不含通配符），
// 缓存根用 .topLevel 按目录汇总；删除动作仍逐条经过 PathSafety 校验。

public enum EcosystemRules {

    /// 标准预设增量：语言/包管理器/工具链的默认下载与索引缓存，可自动重建。
    public static let standard: [CleanupRule] = [
        CleanupRule(id: "eco.swiftpm", name: "SwiftPM 缓存", category: .packageCaches,
                    path: "~/Library/Caches/org.swift.swiftpm", minAgeDays: 7, grade: .safe,
                    note: "Swift 包依赖与仓库缓存，下次构建时按需重新拉取。"),
        CleanupRule(id: "eco.deno", name: "Deno 缓存", category: .packageCaches,
                    path: "~/Library/Caches/deno", minAgeDays: 7, grade: .safe,
                    note: "Deno 远程模块与类型缓存，再次运行时会重新下载。"),
        CleanupRule(id: "eco.bun", name: "Bun 安装缓存", category: .packageCaches,
                    path: "~/.bun/install/cache", minAgeDays: 7, grade: .safe,
                    note: "Bun 下载的 npm 包缓存，重新安装时按需获取。"),
        CleanupRule(id: "eco.uv", name: "uv 缓存", category: .packageCaches,
                    path: "~/Library/Caches/uv", minAgeDays: 7, grade: .safe,
                    note: "uv 的 Python 包下载与构建缓存，下次安装时重建。"),
        CleanupRule(id: "eco.poetry", name: "Poetry 缓存", category: .packageCaches,
                    path: "~/Library/Caches/pypoetry", minAgeDays: 7, grade: .safe,
                    note: "Poetry 的依赖下载与虚拟环境构件缓存。"),
        CleanupRule(id: "eco.rubygems", name: "RubyGems 缓存", category: .packageCaches,
                    path: "~/.gem", minAgeDays: 7, grade: .safe,
                    note: "已下载的 gem 安装包，bundle install 时可重新获取。"),
        CleanupRule(id: "eco.bundler", name: "Bundler 缓存", category: .packageCaches,
                    path: "~/.bundle/cache", minAgeDays: 7, grade: .safe,
                    note: "Bundler 的 gem 缓存，安装依赖时按需重下。"),
        CleanupRule(id: "eco.hex", name: "Hex 缓存", category: .packageCaches,
                    path: "~/.hex", minAgeDays: 7, grade: .safe,
                    note: "Elixir Hex 包缓存，mix deps.get 时会重新下载。"),
        CleanupRule(id: "eco.cabal", name: "Cabal 包缓存", category: .packageCaches,
                    path: "~/.cabal/packages", minAgeDays: 7, grade: .safe,
                    note: "Haskell Cabal 的包索引与压缩包缓存。"),
        CleanupRule(id: "eco.stack", name: "Stack 缓存", category: .packageCaches,
                    path: "~/.stack", minAgeDays: 30, grade: .safe,
                    note: "Stack 的程序与快照缓存，重建时按需重新下载；保留 30 天。"),
        CleanupRule(id: "eco.opam", name: "opam 下载缓存", category: .packageCaches,
                    path: "~/.opam/download-cache", minAgeDays: 7, grade: .safe,
                    note: "OCaml opam 的源码包下载缓存，安装时可重新获取。"),
        CleanupRule(id: "eco.nuget", name: "NuGet 包缓存", category: .packageCaches,
                    path: "~/.nuget/packages", minAgeDays: 30, grade: .safe,
                    note: "NuGet 已解压的包缓存，还原项目时按需重建；保留 30 天。"),
        CleanupRule(id: "eco.pub", name: "Dart pub 缓存", category: .packageCaches,
                    path: "~/.pub-cache", minAgeDays: 7, grade: .safe,
                    note: "Dart 与 Flutter 的 pub 包缓存，pub get 时重新下载。"),
        CleanupRule(id: "eco.bazel", name: "Bazel 缓存", category: .developer,
                    path: "~/.cache/bazel", minAgeDays: 7, grade: .safe,
                    note: "Bazel 的 action 与输出缓存，下次构建会重新生成。"),
        CleanupRule(id: "eco.zig", name: "Zig 编译缓存", category: .developer,
                    path: "~/.cache/zig", minAgeDays: 7, grade: .safe,
                    note: "Zig 编译中间产物缓存，重新编译自动重建。"),
        CleanupRule(id: "eco.conan", name: "Conan 包缓存", category: .packageCaches,
                    path: "~/.conan2/p", minAgeDays: 7, grade: .safe,
                    note: "Conan 2 的包与构建缓存，安装依赖时重新获取。"),
        CleanupRule(id: "eco.ivy", name: "Ivy 缓存", category: .packageCaches,
                    path: "~/.ivy2/cache", minAgeDays: 7, grade: .safe,
                    note: "Ant/Ivy 依赖缓存，解析依赖时会重新下载。"),
        CleanupRule(id: "eco.nodegyp", name: "node-gyp 缓存", category: .developer,
                    path: "~/Library/Caches/node-gyp", minAgeDays: 7, grade: .safe,
                    note: "node-gyp 下载的 Node 头文件与编译缓存。"),
        CleanupRule(id: "eco.electron", name: "Electron 下载缓存", category: .developer,
                    path: "~/Library/Caches/electron", minAgeDays: 7, grade: .safe,
                    note: "Electron 预编译二进制缓存，安装时按需重新下载。"),
        CleanupRule(id: "eco.carthage", name: "Carthage 缓存", category: .packageCaches,
                    path: "~/Library/Caches/org.carthage.CarthageKit", minAgeDays: 7, grade: .safe,
                    note: "Carthage 依赖下载与构建缓存，bootstrap 时可重建。"),
        CleanupRule(id: "eco.jetbrains", name: "JetBrains 索引缓存", category: .developer,
                    path: "~/Library/Caches/JetBrains", minAgeDays: 7, grade: .safe,
                    note: "IDEA/GoLand 等 IDE 的索引缓存，首次打开项目会重新建立。")
    ]

    /// 激进预设增量：删除后需要重新下载较多内容，默认不进入标准预设。
    public static let aggressiveOnly: [CleanupRule] = [
        CleanupRule(id: "eco.go-modcache", name: "Go 模块缓存", category: .packageCaches,
                    path: "~/go/pkg/mod", minAgeDays: 30, grade: .caution,
                    note: "已下载的 Go 模块源码；删除后首次构建需重新下载依赖。"),
        CleanupRule(id: "eco.vscode-cacheddata", name: "VS Code 缓存数据", category: .developer,
                    path: "~/Library/Application Support/Code/CachedData", minAgeDays: 30, grade: .suggested,
                    note: "VS Code 旧版本缓存，重启后按需重建；建议先关闭 VS Code。"),
        CleanupRule(id: "eco.flutter-pub", name: "Flutter 发布缓存", category: .packageCaches,
                    path: "~/.flutter/pub", minAgeDays: 30, grade: .caution,
                    note: "Flutter SDK 自带的 pub 缓存；删除后 pub get 会重新下载。"),
        CleanupRule(id: "eco.conda", name: "Conda 包缓存", category: .packageCaches,
                    path: "~/opt/anaconda3/pkgs", minAgeDays: 30, minSizeMB: 50, grade: .caution,
                    note: "Conda 已解压的包与安装包缓存；删除后环境重建需重新下载。")
    ]

    /// 标准 + 激进的全部生态规则，便于合并或统计。
    public static var all: [CleanupRule] { standard + aggressiveOnly }
}
