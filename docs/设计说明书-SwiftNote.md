# SwiftNote — macOS 轻量文本编辑器 设计说明书

## 一、文档信息

| 项 | 内容 |
|------|------|
| 产品代号 | SwiftNote |
| 文档版本 | v2.10 |
| 作者 | 吴八哥（高级开发工程师 Agent） |
| 日期 | 2026-11-20 |
| 状态 | M1 已落地搜索替换（FR-08）、设置窗口、外部修改监视（FR-11）与双屏对比（FR-09）；v1.6 补大文件纯文本模式（百万行日志可对比），diff 引擎改行偏移 + 哈希 ID |
| 需求依据 | PRD v1.3（docs/PRD-SwiftNote.md） |
| 配套文档 | 评审报告（docs/评审报告-PRD-SwiftNote-v1.0.md）、M0 预研任务书（docs/M0-技术预研任务书.md） |

**变更记录**

| 版本 | 日期 | 变更内容 | 作者 |
|------|------|----------|------|
| v2.10 | 2026-11-20 | 修只读大文件面板「右侧不显示滚动条」：① 新增 ADR D-47（画布铺进 `scrollView` 内、排在 `clipView`/系统滚动条之下，`clipView` 改透传）；② 5.5 补面板滚动条层级要求；③ 新增 `SWIFTNOTE_SCROLLER_DEBUG` / `SWIFTNOTE_SCROLLER_WHEEL` 无头钩子（打印子视图顺序与几何、滚动条风格/可见性、窗口级命中视图、滚轮后顶行与滚动条状态） | 吴八哥 |
| v2.9 | 2026-11-20 | 大文件面板支持自动换行：① 新增 ADR D-46（视觉段布局 + 抽样估算滚动刻度 + 真实切段绘制/命中）；② 5.5 补折行行为（行号只标首段、开关不再置灰）；③ 4.4 说明 `wrapLines` 三种视图都生效；④ 修同一行内选区的复制会重复拼接的老 bug | 吴八哥 |
| v2.8 | 2026-11-20 | 只读文档也要能选中 / 折行：① 新增 ADR D-45（用户阈值只管只读，进不进 TextKit 由 10MB 硬上限固定）；② 4.4 补「阈值与面板解耦」并说明两个上限取小；③ 5.5 大文件面板补「拖选任意范围 + 复制 + 命中测试互逆」与「换行开关置灰」；④ 只读文档恢复语法高亮与当前行色带 | 吴八哥 |
| v2.7 | 2026-11-20 | 两个入口：① 5.7 补「右上角＋新建按钮」（自绘、可用宽度先扣掉按钮区、与 ⌘N 同路径）；② 4.4 / 组件表补「状态栏右下角自动换行开关」（显示当前开/关、点击切换，与「显示」菜单同一份设置，三处入口汇到设置变更通知） | 吴八哥 |
| v2.6 | 2026-11-20 | 判型时机与选区定位：① 5.3 补三层成本表（菜单 1 µs / 定位 0.1 ms / 解析 186 ms per 100 万字符）；② 「转换为 JSON」可用性不再依赖判型，点击后在选区内定位报文（`SnippetExtractor`），只替换报文段、保留日志前后缀；③ 定位候选必须过一遍解析校验（`[INFO]` 配平但不是数组）；④ 新增 ADR D-44 | 吴八哥 |
| v2.5 | 2026-11-20 | 右键「转换为 JSON」：① 5.3 补 `XMLToJSON`（手写保序建树、属性 `@` 前缀、混合文本进 `#text`、同名兄弟成数组、文本一律按字符串）；② 新增 ADR D-43；③ 顺手修复 ADR 表里被 D-42 行吞掉的 D-41（`restoreViewport` 光标哨兵） | 吴八哥 |
| v2.2 | 2026-11-19 | 只读阈值可配 + 大文件可编辑性评估：① 4.4 阈值改 1~2048MB（默认 10），补「setter 主动钳制」「改完对已打开文档即时重评估」两条实现细节；② 5.5 补 TextKit 装载实测表与「不做可编辑纯文本面板」的结论；③ 设置窗口阈值改为可直接输入 | 吴八哥 |
| v2.1 | 2026-11-19 | 编码切换边界：① 5.6 重写为「转为 X / 以 X 重新解码」两个正交动作 + BOM 读写 + GB18030 超集结论；② 新增 ADR D-40；③ 4.1 模型补 `hasBOM` / `lineEnding`；④ 修两处连带 bug：已打开文件重复打开时会跳到别的标签、切标签后状态栏行列号仍是上一个文档的 | 吴八哥 |
| v2.2 | 2026-11-20 | 修复「切标签后当前行高亮不跟随」：`restoreViewport` 把 `cursorOffset > 0` 当作「有没有存过光标」，光标在文首的文件（新建 / 从会话恢复）被跳过恢复，而 `textView.string =` 之后插入点停在文末 → 色带画到文末；改为一律按 `cursorOffset`（clamp）设置。另：切标签改由通知统一刷标签栏（原来只有鼠标点标签栏才更新选中态），挂载后补一次延后高亮刷新。新增 ADR D-41 | 吴八哥 |
| v2.3 | 2026-11-20 | 标签右键菜单：5.7 补「标签右键菜单」——复制文件路径 / 在访达中显示，未命名与文件已删除的置灰规则；`TabBarItem` 增 `path` 字段 | 吴八哥 |
| v2.4 | 2026-11-20 | 按 UI 评审清单落地 8 项：① 5.5 补「差异导航」（`DiffResult.hunks` + 工具栏 n/N + ⌥⌘↑↓ + 无差异置灰）；② 5.11 补「高度随命中数收缩」与「徽标胶囊底」；③ 5.7 补视觉细节（非活跃对比度、强调条对齐、SF Symbols、两端对齐）；④ 5.2 补 `.properties` 值色降饱和；⑤ 新增 ADR D-42 | 吴八哥 |
| v2.0 | 2026-11-19 | 换行符与报文格式化：① 5.6 补「换行符（EOL）」——三种风格、内存恒 `\n`、状态栏右下角切换；② 5.3 按实现重写为「JSON / XML 格式化」，JSON 改为校验后词法重排、新增 XMLService 与 SnippetFormatter（右键格式化选中片段）；③ 6.1 流程图补 EOL 归一与 txt 判定；④ 5.2/6.1 明确 `.txt`/`.log`/`.md` 不做内容嗅探；⑤ 目录树、追踪矩阵、快捷键 20 项更新；⑥ 新增 ADR D-38（`\r\n` 是单个 Character，`contains("\r")` 会漏判）、D-39（行索引与高亮解耦） | 吴八哥 |

| v1.9 | 2026-11-19 | FR-11 最近文件收尾：① 5.8「最近文件」按实现重写（⌘⇧O 快速打开面板 + 文件菜单「最近打开」子菜单）；② 新增 5.11 快速打开面板设计（候选合成、空格分词匹配、命中分档排序、键盘交互、失效文件处理）；③ 新增 ADR D-37（匹配规则放 Core 可单测；`fullSizeContentView` 窗口的卡片底色必须自己画）；④ 3.3 目录结构补 QuickOpen / QuickOpenWindowController，快捷键路由补 ⌘⇧O（第 18 个可自定义动作） | 吴八哥 |

| v1.0 | 2026-11-17 | 初稿：总体架构 + 12 个 FR 的模块设计 + 关键流程 + 非功能设计 | 吴八哥 |
| v1.1 | 2026-11-17 | ① 用户变更：标签行数上限由固定 3 行改为设置项 `maxTabRows`（默认 5，1~6），新增 4.4 偏好设置、ADR D-9；② 原型 B 实测结论固化：末行横向滚动禁用 `NSScrollView`，改自绘裁剪容器 + `isFlipped` 坐标系（5.7、D-3） |
| v1.2 | 2026-11-18 | M1 实施回填：① 新增 ADR D-10（纯 AppKit UI，CLT 无 SwiftUI 宏）、D-11（行号栏自绘，禁用 NSRulerView）、D-12（TextKit II 必须 `usingTextLayoutManager: true`）；② 3.3 目录结构改为实际 SwiftPM 双 target 布局；③ 八节测试策略补 CLT 无 XCTest 的替代方案 | 吴八哥 |
| v1.3 | 2026-11-18 | FR-08 落地回填：① 5.4 按实现重写（字面量快路径、单次遍历替代 8MB 分块、渲染属性高亮、刻度聚合、导航语义）；② 4.4 增补 3 个搜索选项键与设置窗口；③ 新增 ADR D-13（搜索扫描策略）、D-14（搜索高亮走渲染属性）、D-15（行号栏必须 `.ensuresLayout`）、D-16（视口定桩）；④ 3.3 目录结构补 Search / SettingsWindowController | 吴八哥 |
| v1.8 | 2026-11-19 | 快捷键自定义 + 中键关闭标签：① 4.4 增补 `shortcut.<action>` 键与设置窗口双页结构；② 5.7 新增「快捷键自定义」与「标签栏鼠标操作」两段（可自定义范围、存储形式、空串语义、冲突拒绝策略、录制交互）；③ 新增 ADR D-31（快捷键模型放 Core，AppKit 转换单独成层） | 吴八哥 |
| v1.7 | 2026-11-19 | 开发规范审计整改（对照《mac 应用开发注意事项》R/P/检查清单）：① 光标行列号由「全文扫换行」改行起点表 + 二分，并对超阈值文档短路（D-28）；② 会话恢复改两段式：首帧前只 stat、内容首帧后后台补（D-29）；③ 新增 ADR D-27（TextKit 枚举闭包内禁止绘制），并修正 D-26 的误判归因；④ 发版形态：dev / release 双 bundle id、`AppIcon.icns`、zip 解包校验、`clean` 注销（D-30）；⑤ 编码切换读盘移出主线程 | 吴八哥 |
| v1.8 | 2026-11-19 | FR-10 编辑核心补完：① 每个文档一条独立撤销栈，容器自己实现 `undo:`/`redo:`（D-32）；② 撤销/重做改为订阅 undoManager 通知刷新界面（D-33）；③ 撤销分组自管（`groupsByEvent = false` + 输入段空闲收口，D-34）；④ 自动换行开关与当前行高亮（D-35）；⑤ 内容指纹判定「撤销回到磁盘内容 → 自动 Clean」（D-36） | 吴八哥 |
| v1.6 | 2026-11-18 | 大文件可用性：① 新增 5.5「大文件纯文本模式」（>10MB 两侧各走 `PlainTextPaneView`：只读、固定行高、只画可见行）；② 新增 ADR D-23（大文件不进 TextKit）、D-24（spacer + 一屏画布）、D-25（dynamic 色必须套 appearance）、D-26（行号画在同一画布）；③ `DiffEngine` 改「行偏移 + 64 位哈希 ID」，去掉 `[String]` 中间态，82MB 输入峰值内存 654MB→340MB、耗时 2.9s→1.87s；④ 行内降级判据由「文件体积」改为「参与比较的字符量」；⑤ 阈值默认 20MB→10MB | 吴八哥 |
| v1.5 | 2026-11-18 | FR-09 落地回填：① 5.5 按实现重写（不插占位行的两侧各自标注、行映射同步滚动、异步装载、可编辑与保存、外部修改、降级阈值与实测数据）；② 新增 ADR D-19（禁止触碰 `textView.layoutManager`）、D-20（对比栏不折行）、D-21（不插占位行 + 行号映射）、D-22（对比文件异步装载）；③ 3.3 目录补 Compare/Diff；④ 快捷键表补 Cmd+Shift+D | 吴八哥 |
| v1.4 | 2026-11-18 | FR-11 落地回填：① 5.8 按实现重写（FileWatcher 事件复核与 inode 重挂、双保险分工、冲突话术表、删除标记、Cmd+R 主动重载）；② 新增 ADR D-17（vnode 事件不直接采信）、D-18（程序化整篇替换需抑制 textDidChange）；③ 3.3 目录结构补 FileWatcher / FileChangeDetector / EditorStore+ExternalChanges | 吴八哥 |

**与 M0 的关系**：本设计的性能参数、控件交互细节中标注「⚠️ 待 M0 校准」的条目，以 M0 实测结论为准，届时升版 v1.1 回填实测值并固化参数。

---

## 二、设计概述

### 2.1 设计目标

以 PRD v1.2 的 FR-01 ~ FR-12 与第八节非功能需求为唯一输入，产出可直接指导 M1 ~ M4 开发的技术方案。核心目标：

1. **性能确定性**：TextKit II 管线承载 50MB 级文本的打开/滚动/编辑；格式化与校验限定 ≤1MB 口径。
2. **增量优先**：语法高亮、搜索、diff 全部采用增量/视口优先策略，禁止全文件同步重算阻塞主线程。
3. **数据不丢**：原子写 + 草稿快照统一机制（PRD RV-08 裁决），任何异常路径下用户内容不静默丢失。
4. **单一机制**：会话恢复与崩溃恢复共用同一份快照存储，禁止双机制。

### 2.2 技术选型确认（落实 PRD 5.1）

| 项 | 选型 | 说明 |
|----|------|------|
| 语言 | Swift 5.9+ | 原生方案（PRD 方案 A） |
| UI 框架 | SwiftUI 为主 + AppKit 混合 | 窗口/菜单/面板用 SwiftUI；文本编辑区与多行标签条用 AppKit（NSViewRepresentable 桥接） |
| 文本引擎 | TextKit II（NSTextContentStorage / NSTextLayoutManager / NSTextView） | macOS 12+ 可用；SwiftUI 自带 TextEditor 是 TextKit 1，**禁止使用** |
| 状态管理 | Observation（@Observable，macOS 14+） | 最低支持版本建议 macOS 14+（⚠️ 待确认，PRD 遗留问题 #1） |
| 最低系统 | macOS 14+（建议） | 最终版本随 M0 实测与开发环境确认 |
| 架构模式 | MVVM + 分层架构 | SwiftUI 声明式视图 ↔ @Observable 状态 ↔ 领域服务 |
| 依赖管理 | 零第三方依赖 | 自用工具，全部用系统能力（Foundation / AppKit） |

### 2.3 待 M0 校准项清单

| # | 条目 | 当前取值 | 校准来源 |
|---|------|----------|----------|
| P-1 | TextKit II 打开 50MB JSON 耗时/内存 | 指标 ≤2s / ≤500MB | M0 原型 A（A-1~A-5） |
| P-2 | 不达标时的分块加载预案 | 视口 ±N 行按需供给（NSTextContentStorage 支持懒供给） | M0 判定分支 |
| P-3 | 标签最小宽度 | 160px（含图标/文件名/脏标记/关闭按钮） | M0 原型 B 校准 |
| P-4 | 多行标签实现载体（AppKit 自绘 vs SwiftUI Layout） | 设计倾向 AppKit 自绘 | M0 原型 B 实测拖拽/动画后定 |
| P-5 | 1MB JSON 格式化耗时 | ≤0.5s（估算） | M0 A-7 |
| P-6 | 大文件只读降级阈值 | 20MB（可配置） | M0 A-6 |

---

## 三、总体架构

### 3.1 分层架构

```
┌─────────────────────────────────────────────────────────────────┐
│  App 层（SwiftUI）                                                │
│  SwiftNoteApp · MainWindow · 菜单栏/快捷键路由 · 设置窗口           │
├─────────────────────────────────────────────────────────────────┤
│  特性层（Feature，SwiftUI 视图 + AppKit 桥接）                     │
│  ┌──────────┬──────────┬───────────┬──────────┬──────────┐      │
│  │ TabBarView│EditorView│ SearchPanel│CompareView│StatusBar │      │
│  │ (多行标签 │ (TextKit │ (搜索替换  │ (双屏对比 │ (编码/行列│      │
│  │  自绘控件)│  II 编辑)│  面板)     │  分栏)    │  /错误)  │      │
│  └──────────┴──────────┴───────────┴──────────┴──────────┘      │
├─────────────────────────────────────────────────────────────────┤
│  领域服务层（Core，纯 Swift，可单元测试）                           │
│  ┌─────────┬─────────┬─────────┬─────────┬─────────┬─────────┐  │
│  │Syntax   │JSON     │Search   │Diff     │Encoding │Session  │  │
│  │Engine   │Service  │Engine   │Engine   │Service  │Service  │  │
│  │(词法+增量)│(格式化/ │(正则/计数│(行级+行内│(检测/切换│(快照/恢复│  │
│  │         │校验)    │/视口优先)│  字符级) │  GB18030)│/最近文件)│  │
│  └─────────┴─────────┴─────────┴─────────┴─────────┴─────────┘  │
├─────────────────────────────────────────────────────────────────┤
│  基础设施层（Infrastructure）                                     │
│  FileIO（原子写/文件监视） · DraftStore（草稿存储）                  │
│  · AppLogger（本地 debug 日志） · ReadOnlyPolicy（大文件保护）     │
└─────────────────────────────────────────────────────────────────┘
```

依赖规则：上层单向依赖下层；特性层之间不互相引用，通过共享的 `EditorStore`（状态中枢）通信；Core 层不 import AppKit/SwiftUI（保证可测试）。

### 3.2 模块职责表

| 模块 | 层 | 职责 | 映射需求 |
|------|----|------|----------|
| TabBarView | 特性 | 多行标签布局/拖拽排序/关闭按钮/溢出计数 | FR-01, FR-02 |
| EditorView | 特性 | TextKit II 文本视图封装、行号、当前行高亮、自动换行 | FR-04/06/07, FR-10 |
| SearchPanel | 特性 | 搜索替换 UI、开关（正则/大小写/整词）、滚动条命中标记 | FR-08 |
| CompareView | 特性 | 双屏分栏、差异标色、同步滚动、实时刷新 | FR-09 |
| StatusBar | 特性 | 编码（点击切换）、语法模式、行列号、自动换行开关、错误提示 | FR-05, FR-10 |
| SyntaxEngine | Core | 三格式词法器、行级 token 缓存、增量重解析 | FR-04, FR-06, FR-07 |
| JSONService | Core | 格式化（2 空格）、校验、错误字节偏移→行列转换 | FR-05 |
| SearchEngine | Core | 正则编译、全量计数（后台）、视口命中计算 | FR-08 |
| DiffEngine | Core | Myers 行级 diff + 行内字符级细化 + 超时降级 | FR-09 |
| EncodingService | Core | 编码探测（UTF-8→GB18030→兜底）、解码/编码转换 | FR-10 |
| SessionService | Core | 会话快照读写、恢复流程、最近文件列表 | FR-03, FR-11 |
| FileIO | 基础设施 | 原子保存、文件监视（vnode + 激活时 mtime 校验） | FR-11, 异常 #3/#4 |
| DraftStore | 基础设施 | 未保存草稿持久化（编辑停 2s / 切标签触发） | FR-03, 可靠性 |
| ReadOnlyPolicy | 基础设施 | 大文件阈值判定、只读模式功能矩阵管控 | FR-12 |
| EditorStore | 特性（状态） | 文档列表、活跃标签、脏状态、文档状态机 | FR-01, 9.1 |

### 3.3 工程目录结构

> M1 实施后的实际结构（SwiftPM 双 target：`SwiftNoteKit` 零 UI 可测试，`SwiftNote` 为 AppKit 外壳）。
> 与原规划差异：① 拆出 Kit 库以便在无 XCTest 的 CLT 环境单测；② UI 层为 AppKit（D-10）；③ 新增 `Tests/CoreTests` 自带断言 runner。

```
SwiftNote/
├── Package.swift                      # SwiftPM：SwiftNoteKit / SwiftNote / CoreTests
├── Sources/
│   ├── SwiftNoteKit/                  # Core + Infrastructure，零 UI 依赖
│   │   ├── Core/
│   │   │   ├── Model/                 # DomainTypes、EditorDocument（含 DocumentStateMachine）
│   │   │   ├── AppSettings.swift      # 偏好设置（UserDefaults，范围钳制）
│   │   │   ├── Syntax/                # Lexer 协议、JSON/Xml/Properties 词法器、SyntaxEngine
│   │   │   ├── JSON/                  # JSONService（校验 + 词法重排美化）
│   │   │   ├── XML/                   # XMLService（报文层级化）+ XMLToJSON（报文转 JSON）+ SnippetFormatter（片段判型与分发）
│   │   │   ├── Search/                # SearchEngine + SearchQuery（字面量/正则/整词、替换、导航）
│   │   │   ├── Encoding/              # EncodingService（UTF-8 / GB18030 探测与转换）
│   │   │   └── Session/               # SessionService + SessionSnapshot（camelCase）、QuickOpen（快速打开候选与匹配）
│   │   └── Infrastructure/
│   │       ├── FileIO/                # AtomicSaver、FileLoader、AppPaths、FileWatcher（vnode）、FileChangeDetector
│   │       ├── Draft/                 # DraftStore（草稿快照，单一机制）
│   │       └── Logging/               # AppLogger
│   └── SwiftNote/                     # App + Features（纯 AppKit，D-10）
│       ├── main.swift                 # NSApplication 启动
│       ├── App/                       # AppDelegate、MainMenuBuilder、MainWindowController、SettingsWindowController
│       │   └── …
│       ├── Features/
│       │   ├── Editor/                # EditorTextView（工厂）、EditorContainerView、LineNumberGutterView、SyntaxTheme
│       │   ├── Tabs/                  # TabBarView（多行/末行裁剪滚动/溢出计数/跨行拖拽）
│       │   ├── Store/                 # EditorStore（文档与标签协调、会话持久化）+ EditorStore+ExternalChanges（FR-11）+ QuickOpenWindowController（⌘⇧O 面板）
│       │   ├── StatusBar/             # StatusBarView（路径/行列/编码/语法/校验）
│       │   ├── Search/                # SearchPanelView（搜索替换条）、MatchMarkersView（滚动条刻度）
│       │   ├── Compare/                # CompareWindowController、ComparePaneView、PlainTextPaneView（大文件，FR-09）
│       └── Resources/                 # 图标、配色（后续）
├── Tests/CoreTests/                   # 自带断言 runner：`swift run CoreTests`
├── tools/
│   ├── build-app.sh                   # 打包 dist/SwiftNote.app（Info.plist + ad-hoc 签名）
│   ├── gen_test_files.py              # 大文件测试数据生成
│   └── testdata/                      # 52MB / 200MB / 1MB + samples/ 小配置样例
├── prototypes/m0/                     # M0 预研原型 A（TextKit II）/ B（多行标签）
└── docs/                              # PRD、设计说明书、M0 任务书、评审报告、M1 进度
```


### 3.4 关键设计决策记录（ADR 简表）

| # | 决策 | 理由 | 备选与代价 |
|---|------|------|-----------|
| D-1 | 编辑区用 `NSViewRepresentable` 包裹 `NSTextView`（TextKit II），不用 SwiftUI `TextEditor` | TextEditor 是 TextKit 1，无大文本优化；TextKit II 是 PRD 选型 A 的核心依据 | 失去纯声明式封装便利，桥接代码由本设计承担 |
| D-2 | 语法高亮用自研行级词法器 + 上下文传递，校验复用系统解析器 | XML/JSON 高亮只需要词法层；系统解析器管正确性，不重复造轮子（PRD 5.2） | 自研词法器需覆盖跨行状态（见 5.2.2） |
| D-3 | 多行标签用 AppKit 自绘（NSView + `isFlipped` 自上而下布局），不用 SwiftUI Layout | 拖拽跨行、行高动画、末行横向滚动需要精细事件控制；SwiftUI 方案仍要回到 AppKit 包滚动区，混合反而更复杂 | SwiftUI `Layout` 协议备选（SwiftDown 已验证可行），M0 原型 B 已用 AppKit 跑通 B-1~B-6（P-4 据此收口） |
| D-4 | 搜索全量计数在后台 Task 执行，视口高亮优先渲染 | 50MB 文件同步扫描必卡主线程（评审 RV-06 的落地） | 计数短暂显示「统计中…」再刷新 |
| D-5 | 保存用「临时文件 + rename」原子替换 | PRD 9.2 保存流程硬性要求；防写一半崩溃损坏原文件 | 需处理同目录写权限与文件属性保留 |
| D-6 | 会话快照与崩溃恢复共用 DraftStore，单一机制 | RV-08 裁决：禁止双机制并存 | 无（机制唯一性优先于一切） |
| D-7 | 编码转换走 CFString（GB18030）而非 ICU 三方库 | 零依赖原则；GB18030 是 GBK 超集，覆盖兼容需求 | 极冷门编码不支持（超出 MVP 范围） |
| D-8 | diff 两阶段：Myers 行级（必有）+ 行内字符级（可跳过），跳过即降级 | FR-09 的「超 3s 强制降级」需要一个可丢弃的第二阶段才成立 | 大文件只看行级差异，无字符级高亮 |
| D-9 | 标签行数上限做成设置项（`maxTabRows`，默认 5，1~6），不写死 | 不同用户对编辑区高度的容忍度差异大：管配置文件的人要多行、写代码的人要单行；写死必然有一方不满 | 需承担「设置变更即时重排」的布局路径（见 4.4、5.7） |
| D-10 | **UI 层改用纯 AppKit**（`NSApplication` + 自定义窗口/视图），不引入 SwiftUI | 本机只有 Command Line Tools，SwiftUI 的 `@State` 等属性包装器已是宏实现，编译报 `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`（实测），SwiftUI 全链路不可用；AppKit 可编译、可运行、可打包 | 装完整 Xcode 后可换回 SwiftUI 外壳；Core 层（`SwiftNoteKit`）零 UI 依赖，不受影响 |
| D-11 | **行号栏自绘**（`LineNumberGutterView`），不使用 `NSRulerView` | `NSRulerView` 内部含 `NSVisualEffectView`，在本窗口里一旦真正绘制（哪怕只 `rect.fill()`）会把整窗内容冲成白板（M1 实测：标签栏与正文同时消失）；自绘栏只多写滚动同步 | 需自行跟随 `scrollView` 偏移重绘，成本极低 |
| D-12 | TextKit II 必须用 `NSTextView(usingTextLayoutManager: true)` 创建 | 手工拼 `NSTextContentStorage + NSTextLayoutManager + NSTextContainer` 再交给 `NSTextView(frame:textContainer:)`，会得到「有布局片段、storage 有内容、但完全不渲染」的空视图（M1 实测） | 该初始化器是便捷初始化器，子类不能调用 → 改为工厂函数配置，Tab 键拦截走 `NSTextViewDelegate` |

| D-13 | 搜索扫描**不分块**：整串单次遍历 + 后台 Task + generation token 丢弃过期结果 | 正则命中可能跨 8MB 块边界，分块要带重叠并去重；而单次遍历在后台线程已满足「不阻塞主线程」，900KB / 6000 命中的实测计数在 0.3s 内完成 | 超大文件（50MB+）单次扫描约 1s，期间计数显示「统计中…」，跳转不受影响（视口先渲染） |
| D-14 | 搜索高亮用 `NSTextLayoutManager.setRenderingAttributes`，不写 `textStorage` | 渲染属性不进入 `NSTextStorage`，因此不污染词法着色、不进撤销栈；且编辑前可整批移除（D-14 的配套：`textView(_:shouldChangeTextIn:)` 里先清，再让文本变更） | 渲染属性只能承载绘制类 key（颜色/下划线）；换 TextKit 1 时需改用 `layoutManager.addTemporaryAttribute` |
| D-15 | 行号栏枚举片段必须带 `enumerateTextLayoutFragments(…, options: [.ensuresLayout])` | 不带该选项时 TextKit II 只返回**未排版**片段，`layoutFragmentFrame` 全为 0，4 万行文档会把上百个行号叠画在同一个 y 上（表现为行号区一团黑块，M1 实测必现，且白烧排版时间） | 每次绘制强制排版视口附近片段，开销可接受（只到视口底部即 `return false`） |
| D-16 | 打开文档后主动「视口定桩」：按 `document.scrollPosition` 滚一次并 `layoutViewport()` | TextKit II 对大文档（900KB / 4 万行）首次排版会把 viewport 锚到文末，表现为「打开文件直接跳到最后一屏」；定桩在首帧布局后与 `async` 各做一次即可稳定 | 多一次滚动调用；`reloadFromDocument` / 编码切换同样复用该路径 |
---
| D-17 | vnode 事件不直接采信：`.delete`/`.rename` 先判路径存在性，存在即「原子写换了 inode」→ 重挂监视 + 按内容变更处理 | `FileManager.replaceItemAt` 是 rename 语义，被监视的 inode 随之消失。若把 delete 直接当删除处理，「保存一次后监视就静默失效」——外部修改再也发现不了，且界面毫无异常，属最难排查的一类缺陷。改用「路径存在性 + mtime/size 复核」双重判定 | 每次保存多一次 fd 重建（微秒级）；`cancelHandler` 负责 close 旧 fd，重挂时不可重复 close |
| D-18 | 程序化整篇替换（外部重载 / 编码切换）必须用 `suppressTextDidChange` 包住 `textView.string = …` | `NSTextView.string` 赋值同样发 `NSTextDidChange`，不抑制会把刚恢复的 Clean 文档立刻标脏。此前靠调用方补 `markSaved()` 打补丁，新增调用点就会漏 | 用实例标志而非通知去抖；标志作用域严格限定在赋值语句内 |
| D-19 | 对比栏**禁止**读取 `textView.layoutManager`（TextKit 1 接口），行高改从 `textLayoutFragment` / 独立 `NSLayoutManager` 度量 | 一旦访问 `textView.layoutManager`，AppKit 会把 TextKit II 文本视图降级到兼容模式，`textLayoutManager` 直接变 nil，行号栏取不到任何布局片段（实测表现为「行号整栏空白」且无报错） | 行高需要自己度量；换来 TextKit II 全链路不被破坏 |
| D-20 | 对比栏**关闭自动换行**，长行走横向滚动 | 同步滚动按「行号 → 行号」映射，折行后像素高度与行号不再线性对应，两栏必然视觉错位 | 长行需要横向滚动；与 Beyond Compare / FileMerge 行为一致 |
| D-21 | 对比**不插入占位行**，用行号映射补偿错位 | 占位行必须改写文本才能渲染，直接毁掉「可编辑 + 原文不变」的前提 | 插入/删除后两栏行号错位，依赖映射同步滚动；不做并排严格对齐 |
| D-22 | 对比文件**异步装载**（`FileLoader.loadAsync`），装载完成后主线程只灌文本 | 12MB 文件同步读 + 灌入会把窗口冻住数秒，与「禁止界面冻结」冲突 | 装载期间标题栏显示「读取文件…」；大文件首帧排版开销另计（见遗留项） |
| D-23 | 超过阈值（默认 10MB）的文件**不进 TextKit**，改自绘纯文本面板 | `NSTextView` 装载时会把全文排版一遍：百万行要几十秒、内存上 GB；对比栏两栏各一遍更糟。实测同一 82MB 文件，TextKit 路径卡死，纯文本路径 0.75s | 失去折行、语法高亮、光标编辑与选区；大文件本来就只读（FR-12），代价可接受 |
| D-24 | 纯文本面板拆成 `spacer`（只有尺寸）+ `canvas`（永远一屏，盖在上面按偏移重绘） | 让画布自己撑成千万 pt 高时，layer-backed 的 view 分不到 backing store，`draw` 照常执行但结果被静默丢弃（整栏空白、无报错）。实测 700 万 pt 高度必然触发 | 滚动范围由 spacer 提供；canvas 需手动转发滚轮事件 |
| D-25 | 自绘时整段绘制包在 `window.effectiveAppearance.performAsCurrentDrawingAppearance {}` 里 | `SyntaxTheme` 的配色是 dynamic `NSColor`，没有 appearance 上下文时解析失败并静默回退成无色——表现为「代码执行了、像素没变」，极难定位（用硬编码红色探针才区分开） | 每帧多一次 appearance 切换，开销可忽略 |
| D-26 | 行号画在**同一个 canvas** 内（冻结带），不另开固定 gutter 视图 | 独立 gutter 的 `draw` 会被调用但结果上不了屏，日志显示一切正常、画面全白（真因见 D-27，本节当时的「同层合成问题」属误判） | 行号随 canvas 重绘；横向滚动时靠「最后画行号带背景」实现冻结列 |
| D-27 | `enumerateTextLayoutFragments` 的闭包里**只收集、不绘制**：先攒成 `[(text, y)]`，闭包结束后统一 `draw(at:)` | 在枚举闭包内直接绘制，一个像素都上不了屏：外层 `bounds.fill()` 正常、闭包前后的实色块也正常，唯独闭包里的文字永远不出现——日志显示「枚举 19 次、draw 调用 19 次、viewport 正常」，屏幕却全白，且无任何报错。`.ensuresLayout` 会在枚举途中驱动 TextKit 重排版并切换绘制上下文，闭包内的绘制落在随后被丢弃的上下文里。改成「先收集后绘制」后，主编辑器行号栏立即恢复（1MB/4.8 万行实测） | 多一个临时数组（只存视口内行，通常 <100 项）；`.ensuresLayout` 仍必须保留（D-15） |
| D-28 | 光标行列号用**行起点表 + 二分**，并对超过高亮上限的文档直接短路 | 早期实现从文档起点用 `range(of: "\n")` 逐个跳到光标位置，等于每次方向键都扫一遍全文。200MB 文档 `sample` 实测：718 帧里 138 帧落在 `rangeOfString`（累计 ≈1.4s），输入明显发涩。行表只增不减（`scannedUpTo` 记录已扫位置），文本变更时整表作废重建 | 每行一个 `Int`（4.8 万行 ≈ 380KB）；超阈值文档没有行号栏又是只读的，行列号无意义，直接跳过 |
| D-29 | 会话恢复**两段式**：首帧前只 `FileMeta.read`（stat）建空壳文档，内容在首帧后由后台线程读入并回灌 | 同步读盘恢复 N 个标签（含 13MB 大文件）会把首帧推后数秒，用户看到的是白窗口——与「窗口必须在 200ms 内可见」冲突。空壳阶段就能确定标签、只读降级、光标与滚动位置，内容到达后只需 `reloadFromDocument()` 一次 | 首帧到内容就绪之间有一个短暂窗口，需靠 `.swiftNoteDocumentContentLoaded` 通知把大文件面板的行索引重挂一次（否则索引会按空内容建好、面板一直空白） |
| D-30 | 发版形态：`dev` / `release` **两套 bundle 路径与 bundle id**（`cn.swiftnote.app.dev` / `cn.swiftnote.app`），图标走 `tools/make-icon.swift` 产出的 `.icns`，`clean` 模式主动注销 LaunchServices 注册 | 磁盘上每多一份同 id 的 bundle，系统就多认一个「应用」：Dock 出现两个图标、默认打开程序乱指、图标缓存互相覆盖（且 `lsregister -u` 后 25~40 秒会被 mds 回填）。CLT 环境没有 `actool`，图标只能预生成 `.icns` 并写 `CFBundleIconFile` | 两份产物分别落在 `~/Library/Caches/SwiftNote-dev/` 与 `dist/`；zip 用 `ditto` 打真实路径并解包校验可执行位 |
| D-31 | 快捷键模型（`KeyCombo` / `ShortcutModifiers` / `ShortcutAction`）放 `SwiftNoteKit`，AppKit 侧的转换（事件解析、菜单 `keyEquivalent`、`ModifierFlags`）单独一层 `ShortcutAppKit` | 序列化、默认值、冲突检测都是纯逻辑，放进 App 层就只能在真机上手点——CLT 环境既无 XCTest 也无 UI 测试，等于没有回归保护。反过来 Core 不能依赖 AppKit（否则拖进 UI 依赖，违背 D-10 的双 target 划分） | 多一层桥接：`⇧]` 这类组合必须用 `characters(byApplyingModifiers: [])` 取未加 shift 的字符，具名键（回车/方向/F 键）要映射成 AppKit 的功能键字符，两处细节都放在桥里 |
| D-32 | **每个文档一条独立 `UndoManager`**：容器重写 `undoManager` 属性，并自己实现 `undo:` / `redo:` 两个菜单 action | 编辑器窗口是「一个窗口 + N 个常驻标签」，`NSTextView.undoManager` 顺着响应链拿到的是**窗口**那一条：实测在 B 标签按 ⌘Z，被撤销的是 A 标签的内容（日志：可见=未命名，撤销后 `cbm-types.json` 从 `ZZZ{` 变回 `{`，而眼前的文档毫无变化）。另外整条响应链里只有 `NSWindow` 实现 `undo:`，它转发的是窗口自己的栈，所以只换 `undoManager` 不实现这两个方法时 ⌘Z 什么也不做 | 每个标签多一个 `UndoManager` 对象；容器必须在窗口之前接住 `undo:`/`redo:`，并用 `validateMenuItem` 控制可用态 |
| D-33 | 撤销/重做**不靠 `textDidChange`** 刷新界面，改订阅 `NSUndoManagerDidUndoChange` / `DidRedoChange` | `NSTextView` 的撤销是直接替换 `textStorage`，绕过 `didChangeText`：实测连续输入 3 次收到 3 次 `textDidChange`，撤销一次收到 **0 次**。不补这条链路的话，撤销后语法高亮、行号栏、状态栏行列号、脏标记、搜索命中全是旧的（改完文本、界面不动） | 通知在文本改完之后才发（实测 handler 里读到的已是新文本），可以直接复用同一条刷新管线 |
| D-34 | 撤销分组**自己管**：`groupsByEvent = false`，按「输入段」开组（编辑前 `beginUndoGrouping`），0.4s 空闲 / 保存 / 切标签 / 撤销时收口 | `groupsByEvent` 的「每个事件一轮分组」是 NSApplication / NSWindow 驱动的，脱离窗口的 manager 永远停在 `groupingLevel = 1`（实测：插入、保存、再插入，全程组合层都是 1），整篇编辑被并成**一个** undo 组，「无限撤销」退化成「一步撤销到底」。反过来自己调 `endUndoGrouping` 去补收口，会和它的内部事件状态打架（实测崩在 `-[NSUndoManager _prepareEventGrouping]`） | 连续输入（<0.4s）合并成一步，停顿后逐步；保存时主动断段，所以「保存之后的输入」可以单独撤掉 |
| D-35 | 自动换行置为可切换（`wrapLines`），关掉时容器宽度无限 + 横向滚动条；当前行高亮用一条 6% 灰的色带**压在文本视图上层** | 文本视图在 TextKit II 下始终画自己的背景（`drawsBackground = false` 实测无效），色带垫在下层会被整块盖住（截图取像素验证：垫在下层时该行仍是纯白）。色带用 `hitTest` 返回 nil 的透传视图，不影响点击、拖选与双击选词 | 色带按 `effectiveAppearance` 显式取黑/白 6%，不用 dynamic 色——dynamic 色在没有 appearance 上下文的时机解析可能拿到白（画在白底上等于没画）；关掉换行时色带宽度跟随视口而不是文档宽度 |
| D-36 | 文档「是否已修改」用**内容指纹**（FNV-1a 64 + 字节数）判定，撤销/重做回到磁盘内容时自动转 Clean | 撤销回到保存前的内容后，脏标记仍然亮着；关闭窗口还会弹「未保存」。存整份副本比较会让每个标签多占一倍内存（大文件不可接受），因此只存 `TextFingerprint`。逐键比较 1MB 文本会拖慢输入，只在撤销/重做时算 | 指纹与 `LineIndex` 的行哈希同源（8 字节 + 长度），碰撞概率可忽略；保存 / 重新加载 / 编码切换后都要重新捕获基线 |
| D-37 | 快速打开的**匹配规则放 Core**（`QuickOpen`：候选合成 + 空格分词 + 分档排序），面板（`QuickOpenWindowController`）只管画与键盘；面板卡片用内容视图 `draw` 填 `windowBackgroundColor` | ①「`cbm` 该不该命中 `~/cfg/cbm-types.json`、该排第几」是产品规则，不是界面细节：放 Core 才能用单测钉住（21 条用例），换外壳也不受影响。② `fullSizeContentView` + `titlebarAppearsTransparent` 的窗口，**窗口背景本身是透明的**，内容视图不自己画底色，面板就会整块透出背后的编辑区（本次实测：日志正文一条条穿过面板） | ① 面板层写不了自动化测试，交互只能靠 ⌘⇧O 钩子截图核对；② 面板不用毛玻璃材质：材质在非激活/无头进程里表现不可预期，而这块是纯色卡片，实心最稳，观感也与主窗口一致 |
| D-38 | 换行符**统一在 I/O 边界转换**：读盘 `LineEnding.detect` + `normalized` 归一成 `\n`，写盘 `applied(to:)` 转回；`applied` **内部先归一一次**，不信调用方 | ① 内存里混进 `\r` 会让行号栏多算一列、正则 `$` 与搜索 range 全部偏移，而 TextKit 对 `\r\n` 的行切分行为并不稳定。② 一个真实的坑：Swift 的 String 按扩展字形簇切分，`"\r\n"` 是**单个 Character**，所以 `text.contains("\r")` 对纯 CRLF 文本返回 `false`——用它做归一化的短路条件，归一被静默跳过，随后 `\n` 又被替换成 `\r\n`，磁盘上写出 `\r\r\n`（Windows 侧读出来就是多一个空行）。单测里「CRLF 写回不叠加 `\r`」这条就是钉这个的 | 归一化对 100MB 文本是一次 O(n) 字符串重建（只在打开/保存各一次，可接受）；CRLF 文件在编辑器里看不出差别，只有状态栏标签与保存后的字节能验证 |

| D-39 | 行索引（`SyntaxEngine.rebuildLineIndex`）与**高亮开关解耦**：`setText` / `applyChange` 按「是否需要行号」（体积 ≤ 8MB）执行，着色仍按「是否支持高亮」执行 | 原实现把 `engine.setText`／`applyChange` 整体包在 `if shouldHighlight` 里，而 `.plain` 模式没有 lexer → `shouldHighlight == false` → 引擎从不接收文本 → `lineIndex(atOffset:)` 永远返回 0，**纯文本文件的行号栏整栏显示 1**（`.txt` 之前会被内容嗅探成 JSON/Properties，恰好掩盖了这个 bug；一旦按用户要求把 `.txt`/`.log` 定义为纯文本，它立刻现形） | 纯文本下每次文本变更仍会重建行表（≤8MB 一次几十毫秒，与 JSON 模式的开销一致）；超过 8MB 的文档既无行号栏也不建表 |
| D-40 | 编码切换拆成**两个正交动作**：「转为 X」（改将来写盘的编码，标脏，不读盘）与「以 X 重新解码」（按 X 重读磁盘，严格解码失败即报错）；BOM 作为文件属性随文档走，`AtomicSaver` 按 `hasBOM` 写回 | ① 原实现只有一个「切换编码 = 重新读盘解码」，于是「文件是 UTF-8、想改成 GBK 交付」这个最常见诉求会走进解码路径：GBK 解 UTF-8 中文要么得到乱码、要么失败，而旧代码在成功分支里 `markSaved` 之后文档变 Clean——用户以为改好了，实际存下去的是乱码。两件事语义相反，必须由用户显式选择。② 旧「保存后切换」还有一处隐患：先按旧编码落盘、再按新编码读，读歪了同样是「Clean 的乱码」。故脏文件只给「另存为 / 丢弃并重解码 / 取消」，去掉这个组合。③ BOM 不记标记的话，「打开—保存」一轮就把 BOM 抹掉，只认 BOM 的 Windows 工具会改判编码 | ① 菜单项比一个「编码列表」更重（多一行说明 + 一个重新解码项），属于可接受的认知成本；② 严格解码没有兜底，切错编码只能看到报错而不是「看起来能用的乱码」，需要用户再切回去；③ 转为 GB18030 后 BMP 以外的字符是 4 字节，外部 GBK 工具读不了，只能提示不能阻止 |
| D-41 | `restoreViewport()` 一律 `setSelectedRange(cursorOffset, 0)`（clamp 到文本长度） | 症状是「点标签栏切换文件，当前行高亮不跟着切」。根因不在高亮本身：`textView.string = document.cachedText` 之后 **AppKit 把插入点留在文末**，而恢复代码只在 `cursorOffset > 0` 时才设选区 → 光标本在第 0 位的文件（新建文档、会话恢复的非活跃标签都是 0）被跳过恢复，切过去时插入点停在全文末尾，色带自然画到文末（通常在视口外，看起来就是「高亮没动」）。0 是合法位置，不能当哨兵值，语义上要么用 `Optional`，要么无条件设 | 每建一个编辑器都会把插入点显式放到文首（多一次 `setSelectedRange`，无感知）；已挂载过的编辑器不受影响（选区本来就在 textView 里） |
| D-42 | 差异导航的块列表由 `DiffResult` **现场重建**（`hunks` extension：左侧差异行 ∪ 右侧差异行经 `rightToLeftLine` 投影），键位用 ⌥⌘↑/⌥⌘↓ | ① 原始 Myers `blocks` 只在引擎内部，`DiffResult` 已丢失块边界；重建不需要改引擎输出与降级路径，且 `stats.hunks` 可直接当交叉校验。② 纯插入行在左侧没有对应行，映射指向它前一行，若不 `+1` 会导航到插入点之前的相同行、用户看不到任何变化。③ ⌘↓/⌘↑ 是 `NSTextView` 的「到文末/文首」：菜单 key equivalent 在键盘事件进入响应链之前就被消费，注册成 ⌘↓ 会让整个编辑区失去这两个通用键 | ① 重建在「插入块紧邻修改块」时可能合并成一处（`stats.hunks` 会更多），导航粒度略粗但不会漏点；② 块列表要缓存，百万行文件上每次现算两遍 kinds 有明显延迟 |
| D-44 | 右键菜单的**可用性不跟判型挂钩**：「转换为 JSON」只要有选区且非只读就亮着，判型/定位/解析全部推迟到点击之后；菜单侧只保留 O(64) 的标题探测 | ① 判不出就置灰的后果是「用户永远点不到」——日志里带时间戳前缀的选区首字符是 `2`，而它完全可转，灰掉等于把能力藏了。② 成本本来就不是问题：菜单开到关只读 64 个字符，28MB 文档实测 1 µs，真正贵的解析只在点击后发生一次。③ 定位候选必须过解析校验：`[INFO]` 的括号配平得很完美，只靠配对会把它当数组 | ① 点下去可能白点一次（弹「没找到报文」）；② 菜单标题要给两种语义（判出类型 / 在选区里找），文案略长；③ `locate` 要对每个候选跑一次校验，极端情况下（一行里有十几对括号）比纯扫描慢，但仍在毫秒级 |
| D-43 | XML → JSON 用**手写扫描器建保序树**，文本**一律输出字符串**；属性加 `@` 前缀、属性与文本共存时文本进 `#text`、同名兄弟成数组 | ① `XMLService` 只做缩进不建 DOM，复用不了；字典与 `JSONSerialization` 都会丢键序，而报文对照必须保序。② 不做数字/布尔推断：`<Len>007</Len>` 转成数字变 `7`、`<msisdn>13800138000</msisdn>` 会变数值 ID——报文里这两种"聪明"都是错，要数字应由下游转。③ `@` 前缀 / `#text` 是缺省约定里冲突最小的一组（元素名不可能以 `@` 开头） | ① JSON 侧全是字符串，下游要数字得自己转；② 混合内容顺序表达不了（`a<b/>c` 会拼成 `"a c"` 放进 `#text`）；③ 不保留命名空间声明与 DTD 语义，`ns:tag` 只当普通名字 |
| D-45 | **只读阈值只决定「能否编辑」，不决定走不走 TextKit**：另立固定 10MB 硬上限（`EditorDocument.plainTextHardLimitBytes`），`prefersPlainText` 只看它；只读判定取 `min(用户阈值, 硬上限)` | ① 两者的代价完全不同：只读是「不能改」，纯文本面板是「不能选中、不能复制、不能折行、没有高亮」。混成一个开关的后果是阈值调到 1MB 后，1.7MB 的配置文件变成 `less` 面板，用户连内容都复制不出来。② 上限必须硬编码：TextKit 的装载时间跟「一行有多长」强相关（3MB 单行 JSON 卡死、4.6MB 多行 13ms），用户把阈值调到 2GB 并不代表 `NSTextView` 能装下 2GB。③ 只读文档也要高亮与当前行色带——它们原来挂在 `!isReadOnly` 上，本质是借「只读」当「大文件」的代理，解耦后按体积判断即可 | ① 8~10MB 之间的文件会以只读 TextKit 打开，装载 0.4~1s，比面板的即开即用慢；② 阈值语义变了，设置窗口的文案得说清「只决定只读」；③ 面板当时不能折行，只能靠置灰开关说明（v2.9 已补上，见 D-46） |
| D-46 | 纯文本面板自己实现折行：按可用宽度把逻辑行切「视觉段」，**滚动范围与位置用抽样平均段数换算、绘制与命中用真实切段** | ① 面板不能进 TextKit，折行没有现成排版可用；② 预扫全文算精确视觉行前缀和不可行：逐行测宽 15 万行要 1.2s（中文 5s），200MB 文件是分钟级；③ 但滚动刻度是唯一能容忍误差的地方（大文件不靠滚动条精确定位），内容连续与点选准确才是硬要求——所以只让换算用估算，绘制/命中一律从视口顶行按真实段高累加，两者共用同一套起点公式 | ① 滚动条位置与实际内容不是严格线性（混合行宽时中段略有漂移），滚到底是靠末行钳制；② 窗口宽度变化要重估段数（`layout` 里按顶行锚点重排），极宽→极窄拖动时会有一帧抖动；③ 折行每帧要对可见行做二分测量（约 4ms/帧），关掉折行完全走原路径 |
| D-47 | **纯文本面板的画布必须铺在 `scrollView` 内部、并排在 `clipView` 与系统滚动条之下**，`clipView` 换成 `hitTest` 返回 nil 的子类保证点击仍落到画布 | ① 原实现把画布当面板的直接子视图盖在 `scrollView` 之上，而画布宽度取自 `contentView.frame`，`layout` 时 `tile` 还没把滚动条宽度让出去（实测画布 1200pt、内容区 1185pt），于是 15pt 的滚动条被整条压住：`NSScroller.isHidden=false`、`alpha=1`，但一个像素都上不了屏；② 只把画布宽度改小治标不治本——overlay 风格（macOS 默认「滚动时显示」）下滚动条是浮在内容之上的，没有可让的宽度；③ 画布进了 `scrollView` 就会躺在 `clipView` 底下，而 `clipView` 会吃掉命中事件，点击选中/拖选全部失效，所以必须让 `clipView` 透传 | ① 不能再用 `scrollView.drawsBackground`（`clipView` 一画底色就把画布盖成纯色块），背景改由画布自绘；② 画布 frame 仍按 `contentView.frame` 取，`tile` 之前会比内容区宽十几 pt，多出的部分被滚动条槽遮住（两种风格下都不可见），不追求数值精确；③ 滚轮仍由画布自己转发给 `scrollView`（`scrollWheel`），因为命中目标是画布而不是 `scrollView` |




## 四、核心数据模型

### 4.1 领域模型

```swift
/// 一个打开的文档（一个标签 = 一个 EditorDocument）
@Observable
final class EditorDocument: Identifiable {
    let id: UUID
    var fileURL: URL?              // nil = 未落盘新文件
    var textContent: NSTextContentStorage   // TextKit II 文本后端
    var syntaxMode: SyntaxMode      // .json / .xml / .properties / .plain
    var encoding: FileEncoding      // .utf8 / .gbk（展示名映射 GBK / UTF-8）
    var lineEnding: LineEnding      // 写盘用的换行风格（内存恒 \n）
    var hasBOM: Bool                // 保存时是否写 UTF-8 BOM（打开时探测）
    var state: DocumentState        // .clean / .dirty / .readOnly
    var readOnlyReason: ReadOnlyReason?  // .largeFile / .permission
    var scrollPosition: CGFloat
    var cursorOffset: Int
    var fileMeta: FileMeta?         // mtime、size，供外部修改检测
}

enum SyntaxMode: String { case json, xml, properties, plain }
enum DocumentState { case clean, dirty, readOnly }
enum FileEncoding: String, CaseIterable {
    case utf8 = "UTF-8"
    case gbk  = "GBK"               // 内部按 GB18030 解码（GBK 超集）
}
```

**命名规范**：所有 Swift 类型/属性遵循 camelCase；持久化 JSON 字段名一律 camelCase（项目强制规范）。

### 4.2 会话快照存储格式（SessionService 读写）

文件：`~/Library/Application Support/SwiftNote/session.json`（JSON，字段 camelCase）：

```json
{
  "version": 1,
  "savedAt": "2026-11-17T16:00:00Z",
  "activeTabIndex": 2,
  "tabs": [
    {
      "id": "8E3F…-UUID",
      "filePath": "/Users/xx/configs/a.json",
      "hasDraft": true,
      "scrollPosition": 1234.5,
      "cursorOffset": 1300,
      "encoding": "UTF-8",
      "syntaxMode": "json",
      "readOnly": false
    }
  ],
  "recentFiles": ["/Users/xx/configs/a.json", "…"]
}
```

草稿内容单独存 `~/Library/Application Support/SwiftNote/drafts/<docID>.txt`（明文，与应用同生命周期，卸载即清理——满足 PRD 十一节）。`hasDraft` 仅作恢复时的快速判定，真正依据是草稿文件存在性（防标记与文件不一致）。

### 4.3 文档状态机（PRD 9.1 落地）

```
        打开/保存成功            用户输入
┌─────────┐ ────────► ┌─────────┐
│  Clean  │           │  Dirty  │
└─────────┘ ◄──────── └─────────┘
     │ 保存成功              │ 大文件降级/权限
     ▼                      ▼
┌──────────────────────────────┐
│ ReadOnly（查看/复制/另存为）    │ ──另存为──► 新 Clean 文档
└──────────────────────────────┘
```

实现：`DocumentStateMachine` 单一入口 `transition(event:)`，非法迁移断言拦截；脏标记（●）与 `state == .dirty` 强绑定，保存成功原子性地回 Clean（保证 PRD「禁止保存后仍显示脏标记」约束）。注意：**保存动作本身不入撤销栈**（FR-10 GWT）——保存不碰 `NSTextView`，只在成功后让撤销栈断一次段（D-34）；撤销回到磁盘内容时按内容指纹自动转回 Clean（D-36）。

### 4.4 偏好设置（AppSettings）

存储：`UserDefaults`（键名 camelCase，与应用偏好域一致），只存用户选择，不存会话状态（会话状态归 4.2 快照，职责不混）。

| 键 | 类型 | 默认 | 范围 | 说明 | 关联 |
|----|------|------|------|------|------|
| `maxTabRows` | Int | **5** | 1~6 | 标签行数上限；超出后末行横向滚动 + 溢出计数 | FR-02 |
| `minTabWidth` | CGFloat | 160 | 120~220 | 标签最小宽度（M0 校准值 P-3） | FR-02 |
| `tabInsertsSpaces` | Bool | true | — | Tab 键插入空格而非制表符 | FR-04 |
| `largeFileThresholdMB` | Int | 10 | 1~2048 | 大文件只读降级阈值（P-6）。**只决定「能不能编辑」**，不决定走不走 TextKit（后者由 10MB 硬上限固定，见 D-45）。**setter 主动钳制**（越界不回落默认，见下方说明） | FR-12 |
| `draftSnapshotDelaySec` | Double | 2.0 | 0.5~10 | 编辑停止后写草稿快照的延迟 | FR-03 / RV-08 |
| `searchIsRegex` | Bool | false | — | 搜索面板「.*」开关，记忆上次状态 | FR-08 |
| `searchIsCaseSensitive` | Bool | false | — | 搜索面板「Aa」开关 | FR-08 |
| `searchIsWholeWord` | Bool | false | — | 搜索面板「W」开关（整词） | FR-08 |
| `wrapLines` | Bool | true | — | 自动换行开关（「显示 → 自动换行」与状态栏右下角「自动换行 开/关」，两处同一份设置）；关闭后横向滚动。**三种视图都生效**：正常编辑、只读 TextKit、大文件纯文本面板 | FR-10 |
| `highlightCurrentLine` | Bool | true | — | 当前行高亮（「显示 → 高亮当前行」） | FR-10 |
| `shortcut.<action>` | String | 见 5.7 | — | 自定义快捷键，`shift+cmd+d` 形式；**空串 = 显式清除** | 5.7 |

**只读阈值的三个实现细节**（M1 追加）：

1. **范围 1~2048MB，默认 10MB**：下限给到 1MB（有人不想让 3MB 的日志进 TextKit），上限 2GB（纯文本面板还扛得住，只是滚动会迟滞）。
2. **setter 主动钳制，而不是「越界回落默认」**：其余数值设置（如 `maxTabRows`）走的是「越界 → 回落默认」，那是为改 plist 的人准备的；而阈值在设置窗口里**可以直接输入**，写 5000 应该变成 2048，悄悄改成默认 10 会让人以为什么都没发生。
3. **阈值与「进不进 TextKit」解耦**（D-45）：阈值只回答「可否编辑」。超过阈值但 ≤ 10MB 的文件仍是**只读的 TextKit 编辑器**（能选中、能复制、能折行、有高亮），只有超过 10MB 硬上限才换成纯文本面板。两个上限取小的那个做只读判定，所以阈值调到 64MB 也不会让 20MB 文件进 TextKit（21MB 纯文本实测 6s 装不进来）。
4. **改完对已打开文档即时重评估**（`EditorStore.reapplyLargeFilePolicy`）：只改设置不重评估的话，用户把阈值从 10MB 调到 100MB，眼前的 20MB 文件还是只读，只能关掉重开。规则是「超过新阈值 → 改为只读；低于新阈值 → 解除 `.largeFile` 只读并从纯文本面板换回 TextKit；**有未保存修改的一律不动**（变成只读就再也存不下去），只在状态栏说明跳过了几个」。`.permission` 只读与阈值无关，永不解除。

**读写约定**：`AppSettings` 为单一入口（M1 实现为 `final class` + `didChangeNotification`，因为 UI 层是 AppKit 而非 `ObservableObject`，见 D-10），启动时从 `UserDefaults` 装载并做范围钳制（越界值回落到默认并记录日志）。设置窗口（`SettingsWindowController`）任一项改动 → 广播 `didChangeNotification` → `MainWindowController.onSettingsChanged` 更新 `TabBarView.maxTabRows / minTabWidth`、编辑区 Tab 策略并重排布局，**不重启生效**（FR-02 GWT）。`maxTabRows` 改动属于布局参数变更，禁止触发会话重写。快捷键项另需 `MainMenuBuilder.rebuildIfShortcutsChanged(_:)` 重建菜单（见 D-31）。

设置窗口分「通用 / 快捷键」两页（`NSSegmentedControl` 切换，窗口 470×430）：通用页承载上表的数值型偏好，快捷键页按分组列出 20 个可自定义动作，每行一个录制按钮（`ShortcutRecorderButton`），底部固定提示行显示最近一次操作结果（成功 / 被谁占用 / 已清除）。

`resetToDefaults()` 一次性抹掉上表全部键（快捷键按 `shortcut.` 前缀扫描）并广播，供设置窗口「恢复默认值」使用。

---

## 五、模块详细设计

### 5.1 编辑器视图（EditorView）

**职责**：TextKit II 封装，承载显示与交互；映射 FR-10、FR-04/06/07 的渲染载体。

**结构**：M1 实际实现是纯 AppKit 的 `EditorContainerView`（`NSTextView` 由工厂 `EditorTextViewFactory.make` 创建，不做子类化，见 D-1）；下面保留最初的承载关系示意。
```swift
struct EditorView: NSViewRepresentable {
    @Binding var document: EditorDocument
    func makeNSView(context:) -> NSView { EditorTextView() }
}

final class EditorTextView: NSTextView {
    // TextKit II 管线（不显式创建则 macOS 12+ 默认 TextKit II，
    // 显式断言 contentStorage is NSTextContentStorage 防回退）
    var layoutManager: NSTextLayoutManager { … }
    // 撤销：使用 textView 自带 undoManager，自定义 coalescing（连续输入合并为一步）
    // 当前行高亮：selectionChanged 时刷新 NSTextLayoutManager 的 lineFragment 装饰
}
```

**关键设计**：
- **行号**：自定义 `NSRulerView` 子类（`LineNumberRuler`），按 `textLayoutManager` 可见行片段绘制；行号宽度随位数动态调整；50MB 文件只绘制视口内行（TextKit II 天然按需布局）。
- **自动换行开关**：`wrapLines` 为真时 `textContainer.widthTracksTextView = true`、容器宽度跟随视口；关闭时容器宽度无限、`textView.sizeToFit()` 撑到最长行并显示横向滚动条（D-35）。
- **撤销/重做**：**每个文档一条独立 `UndoManager`**（容器重写 `undoManager` 并自己实现 `undo:` / `redo:`，D-32）；分组自己管——`groupsByEvent = false`，编辑前开组、0.4s 空闲或保存/切标签时收口（D-34），因此连续输入合并为一步、保存只断段不消耗撤销步；格式化/全部替换包裹为单一 undo 组（5.3 / 5.4）。撤销/重做不触发 `textDidChange`，界面刷新走 `NSUndoManagerDidUndoChange` / `DidRedoChange`（D-33）；撤销回到磁盘内容时用内容指纹把文档转回 Clean（D-36）。
- **当前行高亮**：按光标所在 `NSTextLayoutFragment` 的 frame 画一条 6% 灰的色带，压在文本视图上层、`hitTest` 返回 nil（不挡点击），见 D-35。
- **Tab 配置**：设置项 `tabInsertsSpaces`，`insertText` 拦截转换。
- **输入联动**：`textDidChange` → ① 标记 Dirty ② SyntaxEngine 增量重词法（0.1s debounce）③ DraftStore 计划快照（2s debounce）。

### 5.2 语法高亮引擎（SyntaxEngine）

**职责**：FR-04 / FR-06 / FR-07 三格式高亮 + 增量更新。

#### 5.2.1 数据结构

```swift
enum TokenType {
    case key, stringValue, number, boolean, nullLiteral, punctuation   // JSON
    case tagName, attrName, attrValue, comment, cdata                  // XML
    case propKey, propValue                                           // Properties
}

struct Token { let range: NSRange; let type: TokenType }

/// 跨行上下文（词法器在行边界携带）
struct LexContext {
    var insideXMLTag = false          // XML：跨行标签
    var inBlockComment = false        // XML <!-- --> 可跨行
    var inCDATA = false
    var continuationDepth = 0         // Properties \ 续行深度
    var inJSONString = false          // JSON 字符串跨行（宽松场景）
}

protocol Lexer {
    /// 单行词法；context 进出传递，用于跨行状态
    func tokenize(_ line: Substring, context: inout LexContext) -> [Token]
}
```

`TokenStore`：`[lineIndex: (tokens: [Token], contextAfter: LexContext)]` 行级缓存。

#### 5.2.2 增量重解析（核心算法）

编辑发生在第 L 行后：
1. 使缓存从 L 行起失效；
2. 从 L 行重新词法，逐行向下，直到某行的 `contextAfter` 与失效前的缓存值**相等**（不动点）即停止——通常 1~2 行内收敛（普通编辑），XML 多行注释等场景会多走几行；
3. 只对失效行区间重新着色（`NSTextContentStorage.addAttributes`）。

**性能口径**：单次增量重词法 O(变更行数)，与文件总行数无关，满足 FR-04 GWT「50MB 文件中修改 1 行仅该区域重新着色」。⚠️ P-1：50MB 实测帧时间以 M0 原型 A 数据校准。

#### 5.2.3 各格式词法要点

| 格式 | 规则 | 对应 FR |
|------|------|---------|
| JSON | key（`"…"` 后跟 `:`）、字符串值、数字、true/false/null、标点各一色 | FR-04（≥4 类分色验收） |
| XML | 标签名、属性名、属性值、`<!-- -->` 注释、CDATA；标签配对错误仅行内着色提示（深度校验 v1.1） | FR-06 |
| Properties | `#`/`!` 注释行、`=`/`:` 分隔的 key/value、`\` 续行（`continuationDepth` 保证续行块继承 key/value 着色逻辑） | FR-07 |

**着色应用**：颜色方案深/浅主题各一套（`SyntaxTheme` 里的 dynamic 色，深浅自动切换）；通过 `NSTextContentStorage` 的 attribute 设置，避开 TextKit 1 的 layoutManager 旧 API。

**`.properties` 的值单独配色**（`propValue`，不跟随 JSON 的 `stringValue`）：JSON 里字符串是少数派，砖红没问题；`.properties` 的值占正文七成以上，整屏发红会压掉键与结构。浅色 `#8A5945`（低饱和褐）、深色 `#C9A28F`，仍与键（蓝）区分但不抢注意力。

### 5.3 JSON / XML 格式化与校验（JSONService + XMLService）

**职责**：FR-05（JSON 格式化与校验），以及 M1 追加的「选中 JSON/XML 片段右键层级化」。

**JSON（`JSONService`）**

- **校验是唯一权威判定**：`JSONSerialization.jsonObject(options: [.fragmentsAllowed])`，失败时把 error userInfo 里的行列信息转成 `JSONValidationError(line:column:message:)`（1-based）。
- **格式化 = 先校验、后词法重排**。校验通过后不再用 `JSONSerialization.data(withJSONObject:.prettyPrinted)`，改自研 `beautify`：只按 `{}[] , :` 与「是否在字符串内」（含 `\` 转义）插入缩进与换行，**不解析值**。换来三件事：
  1. 键值分隔输出 `": "`，而不是系统 API 的 `" : "`（CBM 配置的惯例是前者）；
  2. 数字不经 `NSNumber`，`1234567890123456789` 原样保留（系统 API 会先转 double）；
  3. 键序天然不变，不必在 `.sortedKeys` 上做取舍。
- 空容器（`{}` / `[]`）压成一行，已格式化文本二次格式化幂等。

**XML（`XMLService`）**（M1 追加）

- 只做词法重排：不建 DOM、不动属性顺序与实体、CDATA 原样搬运；
- 输出约定：元素内容只有文本 → 保持一行（`<MsgId>12</MsgId>`）；注释 / CDATA / 处理指令各占一行并跟随当前缩进；标签内部的换行与多余空格压成单空格（`<a\n x="1">` → `<a x="1">`）；属性值里的 `>` 不当作标签结束；
- 完整性检查：结束标签必须与栈顶同名、结束时栈必须为空，否则抛 `XMLFormatError`（标签不匹配 / 多余结束标签 / 元素未闭合）。**选中不完整的片段会明确报错**，而不是输出一段缩进错乱的文本。

**片段入口（`SnippetFormatter`）**：右键菜单与「格式」菜单共用

- 判型只看首个非空白字符：`{` / `[` → JSON，`<` → XML；
- 右键时现算类型（只取选区前 64 个 UTF-16 单元，不拷贝整段），菜单标题随之变成「格式化选中片段（JSON）」，判不出类型就置灰；
- 替换走 `textView.insertText(_:replacementRange:)`，前后各收一次 undo 组 → **⌘Z 一步回退**（实测 191 → 249 字符，撤销回 191）。

**XML → JSON（`XMLToJSON`）**（v2.1 追加，右键「转换为 JSON」）

- 用途：CBM 报文（XML）与解析配置（JSON）对照。选中一段报文右键 → 原地换成 JSON，不必另存文件。
- 自己建树而不是复用 `XMLService`：后者只做缩进、不建 DOM，且 JSON 侧的键序必须与报文一致，字典做不到保序。树的子节点用 `[(name, value)]` 数组保存，同名兄弟按**首次出现位置**聚合成数组。
- 映射规则（刻意"可预测"而非"聪明"）：
  | XML | JSON |
  |---|---|
  | `<Msg><A>1</A></Msg>` | `{"Msg": {"A": "1"}}`（根名不丢） |
  | 同名兄弟 `<I>1</I><I>2</I>` | `"I": ["1", "2"]`；只有一个时不套数组 |
  | 属性 `<A id="7"/>` | `{"@id": "7"}`（`@` 前缀与子元素区分） |
  | 属性 + 文本 `<A id="1">hi</A>` | `{"@id": "1", "#text": "hi"}` |
  | 空元素 `<A/>` | `""` |
  | 注释 / 处理指令 / DOCTYPE | 丢弃；CDATA 当普通文本 |
- **文本一律输出字符串，不做数字/布尔推断**。`<Len>007</Len>` 若转数字会变 `7`、`<msisdn>13800138000</msisdn>` 会变数值 ID——报文对照场景里这两种"聪明"都是错。要数字由下游自己转。
- 解析是手写扫描器（非 `XMLParser`）：跳过引号内的 `>`（`<a b="1>2">` 不能截断）、实体解码（`&amp;` `&lt;` `&#x4e2d;` 等）、未闭合/不匹配/无元素都抛 `XMLToJSON.Failure` 并带行号。
- 输出由 `render` 直接拼（不经过 `JSONSerialization`）：2 空格缩进、`": "` 分隔、键序等于报文顺序；已用 `JSONService.validate` 交叉校验产物合法。
- 入口只有一个：`EditorContainerView.convertSelectionToJSON`。选中 JSON 时走 `JSONService.format` 重排，选中 XML 时走结构转换。**不切 `document.syntaxMode`**——用户可能只是在 `.txt` 里处理一段片段。

**判型时机与选区定位（`SnippetExtractor`）**（v2.6 追加）

分三层，越往下越贵，且都只在必要时执行：

| 时机 | 做什么 | 成本 |
|---|---|---|
| 菜单开合（`menuNeedsUpdate` + `validateMenuItem`） | 只取选区**前 64 个 UTF-16 单元**，看首个非空白字符判型，用来改标题 | O(64)，与文件大小无关。28MB 文档实测 **1 µs/次** |
| 点击「转换为 JSON」后 | ① 整段当报文试一次；② 失败则 `SnippetExtractor.locate` 在选区内找第一段结构完整的报文 | 200 字符选区 **0.1 ms** |
| ②命中后 | 真正解析：`JSONService.format` / `XMLToJSON.convert` | 100 万字符 JSON **≈186 ms** |

三条关键取舍：

1. **可用性不跟判型挂钩**。「转换为 JSON」只要有选区且非只读就亮；判不出类型时标题写「（在选区里定位报文）」，点击后再决定。原来判不出就置灰，日志里带时间戳前缀的选区（`2026-11-20 12:00:00 [INFO] resp={...}`）首字符是 `2`，整项灰掉——用户根本点不到，也就永远不知道「其实能转」。
2. **定位必须带一次解析校验**。括号配平不足以判断「这是不是报文」：日志里的 `[INFO]` / `[WARN]` 配平得完美，会被当成数组。`locate` 对每个候选跑一次 `JSONService.validate`（XML 走 `XMLService.format`），不合格就把起点往后挪接着找。
3. 命中后**只替换报文那一段**，前缀与尾巴原样保留（实测 `...resp={"code":0,...} cost=12ms` → 前缀、` cost=12ms` 都在，仅中间变多行）；选中态落在新报文上，方便再按一次。

### 5.4 搜索替换引擎（SearchEngine）

**职责**：FR-08（含 RV-06 落地：视口高亮 + 滚动条标记 + 全量计数）。

```swift
struct SearchQuery {
    var term: String
    var isRegex: Bool
    var isCaseSensitive: Bool
    var isWholeWord: Bool
    func compiledRegex() throws -> NSRegularExpression?   // 正则开时编译一次
}

enum SearchEngine {
    /// 后台全量扫描（Task.detached，分块 8MB，避免主线程阻塞）
    static func findAll(in text: String, query: SearchQuery) async -> [NSRange]
    /// 全部替换：返回新文本 + 替换数（调用方单 undo 组替换）
    static func replaceAll(in text: String, query: SearchQuery, with: String) async throws -> (String, Int)
}
```

**关键设计**（v1.3 按 M1 实际实现回填）：

- **视口优先**：查询变更 → 先同步扫描「视口 ± 2000 字符」并立刻上色，后台 Task 再算全量；计数期间显示「统计中…」，完成后显示 `当前 / 总数`。视口范围取 `textLayoutManager.textViewportLayoutController.viewportRange`，用 `textContentStorage.offset(from:to:)` 换算成 `NSRange`（不依赖 TextKit 1 的 `characterRange(for:)`）。
- **扫描策略**：非正则且非整词走 `NSString.range(of:options:range:)` 字面量快路径；其余走 `NSRegularExpression`（正则原文，或 `escapedPattern` + 可选 `\b(?:…)\b`）。**不做 8MB 分块**——正则命中可能跨块，分块需重叠与去重，收益不抵复杂度；改为整串单次遍历 + 后台线程 + generation token 丢弃过期结果（D-13）。
- **高亮载体**：`NSTextLayoutManager.setRenderingAttributes(.backgroundColor, for:)` 渲染属性，不写 `textStorage`——既不污染词法着色与撤销栈，也能在文本变更前一次性整体撤掉（D-14）。
- **滚动条标记**：`MatchMarkersView`（自绘，宽 8pt，贴编辑区右缘），按「命中偏移 ÷ 文本总长」换算位置；命中数多于可用像素时按「每像素是否命中」聚合成矩形带，当前命中用强调色短条；点击刻度跳到相对位置最近的命中。
- **导航语义**：`nextIndex(from:forward:)` —— 光标落在命中内部时先选中该命中，落在命中末尾时前进到下一条，越过末尾回卷；`Cmd+G` / `Shift+Cmd+G` 走同一函数。
- **正则开关**：关闭时按字面量（`NSRegularExpression.escapedPattern` 转义）；整词 = `\b(?:…)\b` 包裹。
- **全部替换单撤销**：`replaceAll` 在后台算出新文本，主线程一组 `insertText` + `beginUndoGrouping/endUndoGrouping` 落盘，`Cmd+Z` 一步回退。字面量模式替换串按字面量插入（`$1` 不展开），正则模式保留模板语义。
- **只读模式**：搜索可用、替换置灰并提示「只读模式」（见 5.10）。

### 5.5 双屏对比（CompareView + DiffEngine）

**职责**：FR-09。入口：文件菜单「对比文件…」（`Cmd+Shift+D`）→ 选择两个文件；对比窗口内每一栏的下拉框还能直接改选「已打开的文档」或另选磁盘文件。

**DiffEngine 两阶段**（D-8，`Sources/SwiftNoteKit/Core/Diff/DiffEngine.swift`）：
1. **行级 Myers**（O(ND)）：先按行内容映射成**同域整数 ID**（左右共用一张表，CRLF 归一化），再做前后缀剪枝，最后对中间段跑带编辑距离上限（默认 600）的 Myers；连续 delete+insert 合并成一个替换块，`min(删除数, 新增数)` 行配成 `changed`，余量分别为 `deleted` / `inserted`；编辑距离超上限 → 整段视作替换并记 `.tooManyChanges`；
2. **行内字符级**：对每个 `changed` 行对先剪公共前后缀，再对中间段做 UTF-16 上的 LCS；得到的片段**向两侧扩到 ASCII 词边界并合并**——纯 LCS 会把 `3000 → 5000` 只标出 `3`/`5`（`000` 是公共子序列），对配置阅读者等于没提示；超过 40 万格规模则整段标差异。

**降级机制**（FR-09 GWT 硬性要求，`DiffDegradeReason`）：
- 预检：任一文件 > 10MB → 直接跳过行内阶段（`.largeFile`）；
- 运行时：行内阶段每处理一对行检查一次 3s 预算，超时**丢弃已算出的行内结果**并回退纯行级（`.timeout`）；
- 行级阶段本身有编辑距离上限兜底（`.tooManyChanges`），不设硬超时——它是「降级目标」本身，且全程在后台队列，不存在阻塞主线程的路径；
- 降级原因与统计一起显示在标题栏（橙色），文案见 `DiffDegradeReason.displayText`。

实测（82MB / 70 万行 × 70 万行，两侧各改 2 行、插 2 行、删 1 行）：读盘 + 解码 0.75s/侧，diff 引擎 1.87s，**从打开到出结果 2.7s**，进程 RSS 417MB，行内标差正常（未降级）。

**差异导航**（工具栏 `chevron.up/down` + `n / N` 计数，快捷键 ⌥⌘↑ / ⌥⌘↓）：

- 块列表 `DiffResult.hunks`（Core，可单测）：扫 `leftKinds` 得左侧差异行，再把 `rightKinds` 的差异行按 `rightToLeftLine` 投影回左侧，合并成连续区间取起点。**纯插入行**在左侧没有对应行，映射指向它前一行，导航要落在 `+1`（插入点之后）才看得见新增内容；
- 跳转时两侧**各自按行号定位**（各留 2 行上下文），不复用同步滚动的行映射——差异行在另一侧可能就是没有对应行，用映射会把两侧带到不同位置；
- 块列表缓存在控制器里：百万行文件上 `hunks` 要扫两遍 kinds，不能放在按钮回调里每次现算；
- 无差异时两个按钮置灰、计数显示 `— / —`；重新对比后块数变小则回到未定位；
- 键位用 ⌥⌘ 而不是 ⌘↓/⌘↑：后者是 `NSTextView` 的「到文末/文首」，被菜单抢走后整个编辑区都会失去通用按键。

**大文件纯文本模式**（`PlainTextPaneView`，超过 **10MB 硬上限**才切换，与用户阈值无关，见 D-45）：

日志动辄上百 MB，而 `NSTextView` 会把整篇文本全量排版一次——对比栏两栏各来一遍就是几十秒、上 GB 内存。因此超硬上限时**完全不进 TextKit**，当 `less` 用：
- 固定行高、只绘制可见的几十行，打开耗时与内存都不随文件增长（82MB 实测 0.75s/侧）；
- 行号带冻结在左侧、不参与横向滚动；
- **支持自动换行**（v2.9 追加，见 D-46）：关＝长行向右溢出、横向滚动；开＝按可用宽度把逻辑行切成若干「视觉段」，每段占一个行高、从行首重新对齐，行号只标在该逻辑行的第一段。切段用真实宽度二分（等宽字体里 CJK 双宽，不能用字符数除），只对可见的几十行做，所以打开耗时与内存仍不随文件增长；
- 只读、无光标编辑、不做语法高亮（与 FR-12「大文件只读」一致）；
- **支持拖选任意范围**（v2.8 追加）：`mouseDown` 记 anchor、`mouseDragged` 挪 head（拖出视口按行自动滚动）、`Shift+点击` 从原选区起点扩展、`Cmd+A` 全选、`Cmd+C` 或右键「复制」取选区文本（跨行用换行拼接）；没有范围选区时仍回退到「复制整行」的老行为；
- 命中测试与绘制必须互逆：绘制用 `offsetWidth(inRow:offset:)`（前缀宽度），命中用 `textPoint(atCanvasPoint:)` 对同一前缀宽度二分。等宽字体里 CJK 是双宽，**不能拿单字宽度去除**，否则选中的字整体偏移；
- 差异底色与行内片段照常绘制（diff 结果按行号查表）；
- 同步滚动、外部修改监视、重新对比与常规模式共用同一套接口。
- **右侧滚动条必须能看见**（v2.10 追加，见 D-47）：面板的画布铺在 `scrollView` 内部、且排在 `clipView` 与系统滚动条**之下**，`clipView` 换成不吃事件的子类保证点击仍落到画布上。

**「大文件面板能不能做成可编辑」的实测结论（M1，不做的理由）**：

用 release 构建，把阈值调大后强制让文件走 TextKit，量 `EditorContainerView.setup` 的耗时（读盘+解码之外的那一步）：

| 文件 | 体积 | 形态 | TextKit 装载 |
|---|---|---|---|
| `.log` 纯文本 | 4.6MB | 28 万行 | **13ms** |
| `.json`（已缩进） | 2.0MB | 15 万行 | **436ms** |
| `.json`（**压缩成一行**） | 3.2MB | 1 行 | **>10s 未完成** |
| `.log` 纯文本 | 21MB | 56 万行 | **>6s 未完成** |

- 结论一：**体积不是唯一变量，形态才是**。同一个 3MB 文件，多行 436ms、单行直接卡死——TextKit 的排版对「一行有多长」比对「文件多大」敏感得多。
- 结论二：10MB 阈值是站得住的（21MB 纯文本 6s 都装不进来），所以「让 plain pane 可编辑」等于自己重写一套光标 / 选区 / 输入法 / 撤销 / 剪贴板，工作量约等于重写 `NSTextView`，收益却只是「编辑超大文件」这种低频诉求。
- 结论三：~~出口是阈值本身~~ → **已修正（v2.8 / D-45）**。当时把「用户阈值」和「进不进 TextKit」当成同一件事，结果阈值调到 1MB 时，一份 1.7MB 的配置文件被降级成 `less` 面板：不能选中、不能复制、不能折行。现在阈值只决定只读，面板由固定 10MB 硬上限决定——20MB 文件即使把阈值调到 30MB 也仍是面板（见上表：21MB 纯文本 6s 装不进来）。
- 遗留观察：3.2MB 单行 JSON 今天会卡住主线程，说明「只读判定只看体积」在单行超长文件上会失效。是否要加「超长行也按纯文本打开」的判据待定，加的话必须同时解释「为什么这个 3MB 文件是只读的」。

**UI 与交互**（`CompareWindowController` + `ComparePaneView`）：
- **不插占位行**：两侧保持原文与可编辑性，各自给差异行贴底色（新增绿 / 删除红 / 修改黄，行内片段用同色系深一档），因此插入/删除后两栏行号会自然错位——由**行映射同步滚动**补偿（`leftToRightLine` / `rightToLeftLine`，删除行继承最近有效行，滚动按「行号 + 行内比例」换算），实测左侧顶行 60 ↔ 右侧顶行 63（中间插入 3 行）；
- **不折行**：`widthTracksTextView = false` + 有限宽容器（10 万字符），长行走横向滚动。折行会让像素高度与行号失去线性关系，同步滚动必然错位；
- **可编辑 + 实时刷新**：编辑停 0.5s 后在后台重算（generation token 丢弃过期结果），脏标记显示在窗口标题与下拉框；
- **保存**：`Cmd+S` 经响应者链落到对比窗口，保存焦点所在栏（只对磁盘文件开口；原子写后重挂监视，避免自写被当成外部修改）；
- **外部修改**：每栏一个 `FileWatcher`；干净时静默重载并重算，有未保存修改时先问「保留本地 / 重新加载」，删除则只在标题栏提示；
- **只读参与**：超过大文件阈值或无写权限的文件以只读身份参与（FR-12）；从「已打开文档」取的是**内存副本**（含未保存修改），因此该栏固定只读且不监视磁盘——避免两个编辑区争同一份文本。

### 5.6 编码服务（EncodingService）

**职责**：FR-10 编码识别与切换（v1.2 用户变更：编码切换提前至 MVP）。

**探测流程**（打开文件时）：
```
Data ──► UTF-8 BOM？(EF BB BF) ── 有则剥掉并记 hasBOM
      ├─ UTF-8 严格解码（String(data:encoding:.utf8)，失败即非合法 UTF-8）
      │    ├─ 成功 → UTF-8
      │    └─ 失败 → GB18030 解码（CFStringConvertEncodingToNSStringEncoding(.GB_18030_2000)）
      │               ├─ 成功 → GBK（状态栏显示「GBK」）
      │               └─ 失败 → 按 UTF-8 容错解码（lossy）+ 状态栏标注，用户可手动切换纠正
```

**切换流程**：菜单里是**两个正交动作**，不做「点一下就猜用户想干什么」：

```
UTF-8（当前）            ← 点编码名 = 转为该编码保存
GBK
写入 UTF-8 BOM           ← 仅 UTF-8 下出现，勾选即保存时写 BOM
────────────
以 GBK 重新解码…          ← 按该编码重读磁盘
```

| 动作 | 语义 | 是否读盘 | 是否丢内容 |
|---|---|---|---|
| **转为 X**（点编码名） | 改「以后按什么编码写盘」，文本一个字节不动，标脏等保存 | 否 | 不丢（无损） |
| **以 X 重新解码** | 从磁盘原始字节按 X 解码，整体替换文本（单 undo 组） | 是 | 脏文件时三选确认 |

- 为什么必须拆开：`文件其实是 GBK、却被显示成乱码`（要重解码）与 `文件是 UTF-8、想改成 GBK 交付`（要转为）落在同一个菜单项上，合并实现必然有一半场景是错的——前者按「转为」处理只会把乱码存回去，后者按「重新解码」处理会把正常内容解成乱码并在 `markSaved` 之后让用户以为保存成功。
- **脏文件走重新解码**：三选「用 X 另存为… / 丢弃修改并重新解码 / 取消」。第一项写副本、原文件不动，是唯一不丢内容的出口，因此放在主按钮。
- **严格解码，不兜底**：`EncodingService.decode(_:as:)` 解不出来返回 `nil`，不像探测链那样退化到容错解码——切错编码要明确报「不是合法的 X」并保持文档不变，而不是给一屏 `\u{FFFD}` 还标成已保存。
- 未命名文件（无 `fileURL`）只能「转为」，菜单里的「重新解码」置灰；大文件纯文本面板与只读文件各给独立提示，不静默失败。

**BOM**（M1 追加）

- BOM 是**文件属性**而非编码：`DecodedFile.hasBOM` 一路带到 `LoadedFile` → `EditorDocument.hasBOM` → `TabSnapshot.hasBOM`（可选字段，旧 session 解码不受影响），保存时经 `AtomicSaver.save(..., bom:)` 写回。
- 不记这个标记的后果很具体：打开一个带 BOM 的 UTF-8 文件、原样保存一次，BOM 就被静默抹掉，某些只认 BOM 的 Windows 工具（记事本早期版本、部分脚本解释器）会改判成 GBK。
- 只有 UTF-8 才谈得上 BOM：菜单里该项在 GBK 下不出现，`encode(..., bom:)` 对 GBK 直接忽略；转为 GBK 时 `hasBOM` 值保留不删，切回 UTF-8 能恢复原状。
- 状态栏显示 `UTF-8 BOM` / `UTF-8`，tooltip 写明带不带 BOM。

**GB18030 的两个现实结论**

- 用的是 GB18030（GBK 超集）而不是严格的 CP936，因此**理论上能编下全部 Unicode**——`canEncode(_:as:.gbk)` 几乎恒为 true，「GBK 编不了这个字」这条分支实际是兜底。
- 真正的风险在另一端：BMP 以外的字符（emoji、生僻扩展汉字）会被写成 **4 字节**序列，SwiftNote 自己读得回来，但只认 GBK 双字节区的工具（不少 Java / MFC 报文程序）会读错。故转 GBK 前用 `hasSupplementaryPlaneCharacters` 检查并给出警告（仍允许转换）。

**扩展性**：`FileEncoding` enum + `cfEncoding` 映射表，新增编码只需加 case（v1.1+ 可扩 Shift-JIS 等）。

**换行符（EOL）**（M1 追加）

- 三种风格：`LF`（Unix/macOS）、`CRLF`（Windows）、`CR`（Classic Mac）。`LineEnding` 在 Core，纯逻辑、可单测。
- **内存里一律 `\n`**：读盘时 `detect` 数三种换行各出现多少次、取多数派（混合换行不报错），再用 `normalized` 归一。行号栏、搜索、diff 只认一种分隔符，`\r` 不进 textStorage——否则行号栏会多算一列、正则 `$` 也不匹配。
- 写盘时 `applied(to:)` 换回目标风格。**`applied` 内部先归一一次**：`"\r\n"` 在 Swift 里是单个 Character，`contains("\r")` 对纯 CRLF 文本返回 false，忘了归一就会写出 `\r\r\n`（踩过，见 D-38）。
- 状态栏右下角显示当前风格（`LF` / `CRLF` / `CR`），点击切换；切换**只改文档元数据并标脏，文本本身不动**（Notepad++ 同款），保存时才落盘。
- 会话快照里带 `lineEnding`（可选字段，旧 session.json 解码不受影响）；外部重载、编码切换都会重新探测。
- `Save As` 沿用当前文档的风格，新建文档默认 `LF`。

### 5.7 多行标签控件（TabBarView）

**职责**：FR-01 / FR-02（核心差异化）。

**视觉细节（2026-11-20 UI 评审后定稿）**：

- 非活跃标签底色 `windowBackgroundColor` 55% + 0.5pt `quaternaryLabelColor` 描边：35% 在十几个标签时与底色几乎同色、糊成一片，描边是「块面感」的兜底；
- 活跃标签底部强调条 `y: 0.5`、高 2pt：填充与描边都 `insetBy(0.5)`，强调条贴 0 会顶出圆角边框、视觉「悬空」；
- 图标统一 SF Symbols（`lock.fill` 只读、`exclamationmark.triangle.fill` 冲突、`arrow.left.arrow.right` 交换），不再混用 emoji 与文本字符。**自绘路径**（`TabItemView.draw`）里 `NSImage.draw` 不会给模板图上色，要自己 `sourceAtop` 染一遍；
- 非末行两端对齐：行内剩余宽度摊给标签，上限仍 `maxTabWidth`；末行要横向滚动，不参与拉伸；
- **右上角「＋」新建按钮**（v2.7）：固定在第一行右侧、垂直居中，26×26，自绘（两条线 + hover 时 `quaternaryLabelColor` 圆角底）。走自绘而不是 `NSButton` 的理由同上面的图标：无边框按钮上模板图的 `contentTintColor` 不可靠，两条线在任何外观下都确定；
  - reflow 的可用宽度先扣掉 `newTabButtonArea`（26 + 8 + 8），否则标签会铺到按钮底下被压住；
  - 点击走 `store.newDocument()`，与 ⌘N 完全同一条路径；空标签时也常驻显示。

**布局算法**（`TabLayoutEngine`，纯函数可单测）：
```
输入：tabs: [TabItem], windowWidth: CGFloat,
      minTabWidth: 160,                          // ⚠️ P-3
      maxRows: AppSettings.maxTabRows            // 默认 5，范围 1~6（4.4）
容量 = floor(windowWidth / minTabWidth)
行分配：顺序装箱，行数上限 maxRows
  - 行数 ≤ maxRows：全部可见，行高 = 28px（估算）
  - 达上限且末行溢出：末行内横向滚动 + 行尾溢出徽标「+N」（自绘裁剪容器，不用 NSScrollView）
输出：[(tab, row, xInRow)] + overflowCount
```

⚠️ 载体约束（M0 原型 B 实测结论）：**末行横向滚动不能用 `NSScrollView`**——传统滚动条固定占约 15pt，28pt 行高会被吃掉一半；浮层滚动条又会直接绘制在标签上。改用 `NSView` + `layer.masksToBounds` 自绘裁剪容器处理 `scrollWheel`，滚动不占行高。同理，行 y 坐标必须基于 `isFlipped` 容器自上而下计算，禁止用 `frame.height` 反推（否则父视图高度更新滞后会导致整组行错位）。

**交互**：
- 拖拽排序：按下 0.1s 进入拖拽态（与点击区分），拖拽过程中实时重排（目标位置占位动画）；松手写回 `EditorStore.tabs` 顺序 → 持久化到 session（重启保持，FR-02 GWT）；
- 每标签独立关闭按钮；关闭 `.dirty` 标签弹「保存 / 不保存 / 取消」；
- 行高变化用 `NSAnimationContext` 平滑过渡（B-4 验收）；`maxTabRows` 设置变更同样走这条动画路径；
- ⚠️ P-4：实现载体（AppKit 自绘 vs SwiftUI Layout）以 M0 原型 B 的 B-1~B-6 实测为准；M0 原型已验证 1~6 行均能正确重排/跨行拖拽，行数上限不再写死。

**快捷键路由**（App 层统一派发）：默认集为 Cmd+N 新建、Cmd+O 打开、Cmd+Shift+O 快速打开最近文件、Cmd+S / Cmd+Shift+S 保存 / 另存为、Cmd+R 从磁盘重新加载、Cmd+Shift+D 对比文件、Cmd+W 关闭标签、Cmd+Shift+[ / ] 前后切换、Cmd+, 设置。

**快捷键自定义**（设置 → 快捷键，见 4.4）：

- 可自定义范围限定在**文件 / 格式 / 查找 / 标签 / 应用**五组业务动作（`ShortcutAction` 枚举，共 20 项）；撤销/重做/剪切/拷贝/粘贴/全选与窗口、应用菜单保持系统约定，不开放修改——它们要么有 macOS 强制习惯，要么与文本控件内建行为冲突；
- 键位存 `UserDefaults`，键名 `shortcut.<action>`，值为 `shift+cmd+d` 这种固定顺序的序列化串；**空串表示用户显式清除**（区别于「没改过 → 取默认」，两者行为不同，必须能分辨）；
- 修改后重建整个 `NSApp.mainMenu`：`NSMenuItem` 的键位是拷贝进去的，改设置不会自动生效；
- 冲突策略：新组合已被别的动作占用时**拒绝写入并提示占用人**，不做「抢占」（抢占会让被抢的那项静默失效，用户很难发现）；
- 录制交互：点按钮 → 本地事件监听吞掉按键（⌘ 组合会先被菜单截走，必须在这一层拦），Esc 取消、Delete 清除；不接受无 ⌘/⌃/⌥ 的组合（否则会抢走正常输入）。

**标签栏鼠标操作**：鼠标中键点击标签 = 关闭该标签（Notepad++/Chrome 习惯，与 `Cmd+W` 走同一条 `closeTab` 路径，脏文档同样弹保存提示）。

**标签右键菜单**：`TabItemView.menu(for:)` 现建菜单，作用于被点的那个标签（不切换激活标签）：

| 菜单项 | 可用条件 | 行为 |
|---|---|---|
| 复制文件路径 | 文档已有磁盘路径 | 绝对路径写入 `NSPasteboard.general`（不缩成 `~`，直接可粘到终端） |
| 在访达中显示 | 路径存在 | `NSWorkspace.activateFileViewerSelecting`，在 Finder 里选中该文件 |
| （提示行，置灰） | — | 未命名 →「未保存的文档没有路径」；运行中文件被删 →「文件已不在磁盘上」 |

路径来自 `TabBarItem.path`（`refreshTabs` 从 `document.fileURL` 灌入），不额外 stat 全表；「是否存在」在菜单弹出时判一次，所以运行中删掉文件也会立刻置灰。

### 5.8 文件管理与外部修改监视（FileIO）

**职责**：FR-11 + 异常 #3 / #4。M1 已落地。

- **打开**：Cmd+O / 拖拽到窗口或 Dock 图标（`onDrop` / `application(_:open:)`）；拖入多个文件逐个异步加载（禁止串行阻塞主线程），超阈值大文件**合并为一次汇总弹窗**（异常 #7：列明哪些文件以只读打开）；
- **保存**：Cmd+S / Cmd+Shift+S（另存为）→ 原子写（见 6.2）。保存成功后**重挂监视**——原子写换了 inode，旧 vnode 源已失效（D-17）；
- **最近文件**：`recentFiles` 最多 20 条（`SessionService.maxRecentFiles`，存 session.json，打开/保存/另存为时置顶去重）。入口两个：文件菜单「最近打开」子菜单（`NSMenuDelegate.menuNeedsUpdate` 现建现用，列前 10 条并标出已失效文件，超出部分引导到面板；末尾「清除最近记录」）与 **⌘⇧O 快速打开面板**（见 5.11）；
- **主动重载**：Cmd+R「从磁盘重新加载」；本地脏时先确认，默认按钮为「保留本地版本」。

**外部修改监视**（双保险，PRD 9.2）：

1. `FileWatcher`（`Infrastructure/FileIO`）：每文档一个 `DispatchSource.makeFileSystemObjectSource`（.vnode，事件 `.write/.extend/.attrib/.delete/.rename`）。事件在私有串行队列汇总、debounce 0.15s 后回主线程——一次保存常伴随多个事件，不合并会触发多轮提示；
2. `EditorStore.verifyExternalChanges()`：窗口 `didBecomeActive` 时对全部文档比对 mtime / size，防监视源失效漏报（网络卷、inode 被换、路径重建）。

**事件不可直接采信**（D-17）。处理顺序固定为：

- 收到 `.delete` / `.rename` 先判路径是否还在：**在** → 视为「原子写换了 inode」，按内容变更处理并**重新挂载**；**不在** → 视为真删除，丢弃监视源（等待激活兜底或文件重新出现）；
- 无论事件类型，最终结论一律由 `EditorDocument.refreshExternalState()` 复核当前磁盘状态得出（`FileChangeDetector` 比对 mtime + size，二者任一变化即视为修改）。

**冲突处理**（`EditorStore+ExternalChanges`）：

| 本地状态 | 提示文案 | 按钮顺序 |
|---|---|---|
| Clean | 磁盘内容与编辑器不一致，请选择保留哪一份 | 重新加载 / 保留本地版本 |
| Dirty | 本地有未保存修改，重新加载会丢弃且无法撤销 | 保留本地版本 / 重新加载（丢弃本地修改） |

- 不丢数据的动作必须是默认按钮；Dirty 时弹窗样式降为 `.warning`；
- **保留本地**：只更新基线（否则每次激活重复提示）并置 `hasExternalConflict` → 标签画 ⚠、状态栏橙色常驻说明「保存将覆盖磁盘」，保存成功后自动清除；
- **重新加载**：重走 `FileLoader`（含编码探测）→ `rebaseOnDisk()` → 清草稿 → 重挂监视 → 编辑区 `reloadFromDocument()`；
- 批量冲突**先扫完全部文档再逐条弹窗**：`runModal` 会嵌套事件循环，边扫边弹会让后续探测与 UI 状态脱节。

**文件被外部删除 / 移动**（异常 #3）：标签保留内存内容 + 标题追加「（已删除）」+ 状态栏提示「请另存为」，允许另存为找回；文件重新出现时自动清标记。


### 5.9 会话恢复与草稿快照（SessionService + DraftStore）

**职责**：FR-03 + 可靠性（崩溃恢复）。**单一机制**（D-6）：会话恢复与崩溃恢复共用同一份存储，无第二套代码路径。

**快照触发**（PRD RV-08 裁决的时机）：
- 编辑停止 2s（debounce，可配置）→ 写该文档草稿；
- 切换标签时 → 立即写前一个文档草稿；
- 应用正常退出（applicationWillTerminate）→ 写全部脏文档草稿 + session.json；
- 崩溃 → 依赖前两类触发点留下的最新快照（最坏丢 2s 内输入，可接受口径）。

**草稿写入**：`drafts/<docID>.txt` 临时文件 + rename（原子，防快照写一半损坏）。

**恢复流程**（见 6.3 时序）：文件在 → 从磁盘加载；文件不在但草稿在 → 从草稿恢复 + 标注「原文件已被删除」；两者皆失败 → 静默跳过。**所有失败汇总为一次提示**（异常 #5），禁止启动阻断、禁止逐个弹窗。

### 5.10 大文件保护（ReadOnlyPolicy）

**职责**：FR-12。

```
打开文件 → size > 阈值（默认 20MB ⚠️ P-6，可配置）？
  ├─ 否 → 正常打开
  └─ 是 → 弹窗「文件 X.XMB，以只读模式打开？」（只读打开 / 取消）
          批量打开时并入 5.8 的汇总弹窗，一次列明
```

**只读模式功能矩阵**（ReadOnlyPolicy 统一管控，违反即断言）：

| 功能 | 只读下状态 |
|------|-----------|
| 查看 / 滚动 | ✅ |
| 复制 | ✅ |
| 搜索（FR-08 查找） | ✅ |
| 编辑 / 粘贴 / 拖入文本 | ❌ 置灰（textView editable=false） |
| 保存 / 全部替换 | ❌ 置灰 + 状态栏提示「只读模式」 |
| 格式化 | ❌ 置灰，悬停提示原因 |
| 双屏对比 | ✅ 只读参与 |
| 另存为 | ✅（写出全量副本，可再编辑） |

**着色降级**：只读模式下语法高亮默认关闭（保证 200MB 滚动流畅，FR-12 GWT）；用户可在状态栏手动开启高亮（自担性能）。

### 5.11 快速打开面板（QuickOpen + QuickOpenWindowController）

**职责**：FR-11「最近文件 ≥20 条 + `Cmd+Shift+O` 快速打开」。M1 已落地。

分层与理由见 D-37：**匹配规则在 Core（可单测），面板只管画与键盘**。

**候选合成**（`QuickOpen.items(openPaths:recentPaths:existing:)`）：

- 已打开文档（按标签顺序）在前、最近文件（按最近优先）在后，**按路径去重**，同一路径只出现一次并打「已打开」标记——用户按 ⌘⇧O 的常见意图是「切回某个已开着的文件」或「重开刚关掉的」；
- 上限 40 条（`QuickOpen.maxItems`）；
- 每条记录 `exists`（打开时 `stat` 一次）：文件已被删/移动时**仍列出但压暗 + 「不存在」橙标**，回车不打开而是就地提示，避免用户在弹窗里迷路；
- 家目录前缀缩成 `~` 显示，文件名与目录分两行（13pt / 11pt）。

**匹配与排序**（`QuickOpen.filter(_:query:)`）：

- 空格分词，**全部命中才算匹配**（顺序无关），匹配范围是完整路径——所以「`cfg cbm`」既能用目录词过滤也能用文件名词过滤；
- 分档排序（同档保持传入顺序）：文件名完全相同 → 文件名前缀命中 → 文件名内含全部词 → 仅目录命中。这解决了「输入 `cbm` 时 `cbm-types.json` 应该排在 `old-cbm.json` 前面」。

**面板交互**：

- `NSPanel`（`.titled` + `fullSizeContentView` + 透明标题栏 + 隐藏红绿灯），贴主窗口居中偏上，并 `addChildWindow`，主窗口收起时一起走；失焦即关（Spotlight 习惯），但无头/未激活时不自杀；
- **高度随命中数收缩**：`chromeHeight(88) + min(命中数, 8) × 行高(44)`，1 条命中时是 132pt 而不是固定 404pt；输入过滤时顶边固定、向下动画收缩（`setFrame(_:animate:)`）。固定高度会让「只命中 1 条」的面板中间空掉三分之二；
- 行右侧的状态徽标（已打开 / 不存在）用**半透明胶囊底**：选中行是白色 18%，普通行是自身语义色 12%——选中行整条是纯色系统蓝，白字直接压上去扫视时读不出来；
- 搜索框常驻焦点，`NSTableView` 选中态自绘（`.none` 高亮 + 圆角内缩底色），因为系统整行高亮在这种「两行一卡」布局里太宽；
- 键盘：↑↓ 换行、↩ 打开、⎋ 关闭（`control(_:textView:doCommandBy:)` 拦在搜索框这一层，否则方向键会被 NSTextView 吃掉）；双击行同样打开；⌘⇧O 再按一次收起——面板为 key 时响应链走的是面板自己，因此 `QuickOpenWindowController` 也实现同名 `quickOpenRecent:`，否则菜单项会变灰；
- 打开动作交回 `MainWindowController`：已打开的路径走 `store.open` 命中去重分支（激活标签），存在的文件走异步加载，不存在的弹「从列表移除 / 取消」。

**卡片底色**：内容视图自己 `draw` 填充 `windowBackgroundColor`，不用 `NSVisualEffectView`、也不依赖 `layer.backgroundColor`——`fullSizeContentView` + 透明标题栏的窗口，其窗口背景本身就是透明的，内容视图不自己画就会「透」出背后的编辑区（实测踩到，见 D-37）。

---

## 六、关键流程设计

### 6.1 打开文件（含大文件分支）

```
用户打开（Cmd+O / 拖拽 / Dock）
  │
  ▼
后台读 Data（不占主线程）──► 文件大小检查 ──► >20MB ──► 汇总弹窗（批量时合并）
  │                                              │只读
  ▼ <20MB                                        ▼
EncodingService.detect ──► 解码 ──► LineEnding.detect ──► 归一成 LF
  │
  ▼
语法模式判定（扩展名优先：.txt/.log/.md 直接纯文本，不参与嗅探；
             未知扩展名才兜底：{}[]→JSON、<?xml→XML、含 = →Properties）
  ▼
创建 EditorDocument + 标签 ──► TextKit II 装载 ──► 首屏高亮（仅视口）
  │
  ▼
FileWatcher 挂载 vnode 监视 ──► 进入编辑
```

### 6.2 保存（原子写）

```
Cmd+S
  │
  ▼
取出当前文本 ──► 按当前编码编码（UTF-8 直写 / GB18030 转换）
  │
  ▼
写入同目录临时文件 .swiftnote-<uuid>.tmp ──► fsync
  │                                             │失败 → 保留内容 + 错误弹窗（异常 #4）
  ▼ 成功                                        ▼
FileManager.replaceItemAt（原子 rename，保留原文件权限/扩展属性）
  │
  ▼
状态机回 Clean · 更新 mtime 缓存（防误报外部修改）· 保存动作不入 undo 栈
```

### 6.3 会话恢复 / 崩溃恢复

```
应用启动
  │
  ▼
读 session.json ──不存在──► 全新启动
  │存在
  ▼
逐 tab：文件存在？──► 读盘 + 编码探测（按快照记录的 encoding 优先）
  │不存在
  ├─ 草稿存在？──► 从草稿恢复 + 标注「原文件已删除」
  │                │
  │                └─ 恢复 scrollPosition / cursorOffset / 标签顺序
  ▼
失败项汇总 ──► 单次 toast「已恢复 N 个标签，M 个文件已失效被跳过」
  │
  ▼
清空已消费的草稿（避免下次误恢复）──► 正常进入
```

### 6.4 编码切换（含未保存保护）

```
状态栏点击编码名 → EncodingPicker（UTF-8 / GBK，可扩展）
  │
  ▼
state == .dirty？
  ├─ 是 → 三选弹窗：保存后切换 / 放弃修改并切换 / 取消
  │        （保存后切换 = 6.2 流程 + 继续；放弃 = 丢弃内存修改）
  └─ 否 ↓
  ▼
重新读磁盘字节 → 按新编码解码 → 单 undo 组整体替换 → 状态栏更新编码名
```

### 6.5 退出合并确认（FR-01 / RV-05）

```
Cmd+Q / 关闭窗口
  │
  ▼
统计 .dirty 文档数
  ├─ 0 → 直接退出（先写会话快照）
  └─ ≥1 → 单次列表式弹窗（列出全部未保存文件名 + 全选复选）
          [全部保存] [全部不保存] [取消]
          全部保存逐个走 6.2（失败项列出，禁止静默跳过）
```

---

## 七、非功能设计

### 7.1 性能设计（指标 → 技术手段映射）

| PRD 指标 | 技术手段 | 验证方式 |
|----------|----------|----------|
| 冷启动 ≤1s | 无第三方依赖；首屏只加载活跃标签（其余懒加载）；快照读取异步 | Instruments App Launch |
| 50MB 打开 ≤2s | 后台读盘 + TextKit II 按需布局；首屏只高亮视口（D-4 同策略） | M0 A-1（P-1） |
| 滚动无可感知卡顿 | 行号/高亮/搜索标记全部视口化；TokenStore 增量 | M0 A-2 + Time Profiler |
| 1MB 格式化 ≤0.5s | JSONSerialization 单趟 | M0 A-7（P-5） |
| 跳转间隔 ≤100ms | 视口命中同步计算，全量计数后台化 | M3 冒烟 |
| 10 标签 ≤500MB | TextKit II 懒布局；非活跃标签只保留文本不保留布局视图 | M4 实测（M0 A-5 单文件口径） |

### 7.2 安全设计（PRD 十一节落地）

- **沙盒**：开启 App Sandbox，仅 `user-selected-file` 读写权限（拖拽/打开对话框按会话授予）；不申请网络与全盘磁盘访问， entitlements 中不声明 network client/server；
- **XXE 防护**：`XMLParser` delegate `parser(_:resolveExternalEntity:)` 返回 nil 且 `shouldResolveExternalEntities = false`；不加载 DTD 外部引用；
- **无远程资源**：全应用不发起任何网络请求（链接也没有）；
- **数据不出本机**：日志仅本地 debug 级，写入 `Application Support/SwiftNote/logs/`，只记耗时/异常类型，不记文件内容。

### 7.3 可靠性设计（异常清单 #1~#8 落地映射）

| 异常 # | 场景 | 设计落点 |
|--------|------|----------|
| 1 | JSON/XML 解析失败 | 行内标红 + 跳转（5.3）；**不阻止打开**（打开与校验解耦） |
| 2 | 编码识别失败 | UTF-8 容错打开 + 状态栏标注 + 手动切换纠正（5.6） |
| 3 | 文件被外部删除/移动 | 标签保留内容 + 提示 + 另存为找回（5.8） |
| 4 | 磁盘写满/权限失败 | 原子写失败路径保留内存内容 + 明确报错（6.2） |
| 5 | 会话恢复失败 | 跳过 + 单次汇总提示（6.3） |
| 6 | 对比文件之一被修改 | 编辑实时刷新 diff；外部修改走 5.8 提示重对比 |
| 7 | 批量大文件拖拽 | 逐个异步加载 + 一次汇总弹窗（5.8 / 5.10） |
| 8 | 标签 100+ | 行数上限（默认 5，设置可调 1~6）+ 末行横向滚动 + 溢出计数（5.7 / 4.4） |

### 7.4 可访问性

- 全快捷键集（PRD FR-01/05/08/10/11 定义）经菜单 `keyEquivalent` 声明（保证系统键盘导航可用）；
- 标签/按钮接 `accessibilityLabel`（含脏状态朗读「已修改」）；
- 颜色方案保证对比度（深浅主题各一套），差异标色同时附加符号标记（+/−/~）辅助色弱识别。

---

## 八、测试与验证策略

| 层 | 范围 | 工具/方式 | 对齐里程碑 |
|----|------|-----------|-----------|
| 单元测试 | Lexer 三格式（含跨行/续行/嵌套边界）、JSON 错误定位换算、DiffEngine 正确性 + 超时降级、EncodingService 探测矩阵（UTF-8/GBK/乱码/空文件）、TabLayoutEngine 装箱、SearchEngine 正则/整词/大小写 | **CLT 环境无 XCTest**（`unable to resolve module dependency: 'XCTest'`），改用 `Tests/CoreTests` 自带断言 runner：`swift run CoreTests`（M1 已覆盖 43 项）；装 Xcode 后可平滑切回 XCTest | M1~M3 持续 |
| 集成测试 | 原子写（含写失败注入）、会话恢复（含草稿/文件删除/部分失败）、编码切换全流程、外部修改弹窗 | XCTest + 临时目录 | M2/M3 |
| 性能测试 | PRD 第八节全指标实测 | XCTest measure + Instruments；数据回填 PRD | M4（+M0 前置） |
| 验收测试 | PRD 15.2 RTM 全部 GWT（FR-01~12 共 24 条） | 手测走查脚本（按 GWT 逐步执行打勾） | M2/M3 走查 + M4 终验 |

**冒烟基线**（每个里程碑出口必跑）：启动 → 开 15 标签 → 三格式各编辑/高亮 → JSON 格式化+撤销 → 搜索替换+撤销 → 双屏对比 → 退出确认 → 重启恢复。

---

## 九、需求追踪矩阵（FR → 模块 → 设计章节）

| 需求 | 核心模块 | 设计章节 | 关键验收点 |
|------|----------|----------|-----------|
| FR-01 多标签管理 | TabBarView / EditorStore | 5.7 / 6.5 | 退出合并确认单弹窗 |
| FR-02 多行标签 | TabLayoutEngine / TabBarView / AppSettings | 5.7 / 4.4 | 行数上限可配（默认 5）、溢出计数、拖拽持久化 |
| FR-03 会话恢复 | SessionService / DraftStore | 5.9 / 6.3 | 草稿单机制、失败汇总提示 |
| FR-04 JSON 高亮 | SyntaxEngine/JSONLexer | 5.2 / 6.1 | ≥4 类分色、增量着色；`.txt`/`.log`/`.md` 按纯文本打开（不嗅探，可在状态栏手动切换） |
| FR-05 格式化校验 | JSONService / XMLService / SnippetFormatter | 5.3 | 单步撤销、错误行列跳转、1MB≤0.5s；XML 报文层级化、选中片段右键格式化、右键「转换为 JSON」（XML→JSON / JSON 重排，M1 落地） |
| FR-06 XML 高亮 | SyntaxEngine/XMLLexer | 5.2 | 标签/属性/注释/CDATA 分色 |
| FR-07 Properties 高亮 | SyntaxEngine/PropertiesLexer | 5.2 | 续行块着色连续 |
| FR-08 搜索替换 | SearchEngine / SearchPanelView / MatchMarkersView | 5.4 | 视口高亮+滚动条标记+全量计数、替换单撤销（M1 已落地，Cmd+F / Cmd+Option+F / Cmd+G / Shift+Cmd+G） |
| FR-09 双屏对比 | DiffEngine / CompareWindowController / ComparePaneView / PlainTextPaneView | 5.5 | 三色标差、行内字符级、行映射同步滚动、可编辑实时刷新；**超 10MB 自动切纯文本只读模式**，82MB×2 打开 2.7s（M1 已落地，Cmd+Shift+D） |
| FR-10 编辑核心 | EditorView / EncodingService / LineEnding | 5.1 / 5.6 | 「转为 X」与「以 X 重新解码」分离、脏文件三选（另存为/丢弃/取消）、UTF-8 BOM 原样写回、保存不入 undo、换行符 LF/CRLF/CR 可切且保存按所选风格写盘 |
| FR-11 文件管理 | FileIO / FileWatcher / FileChangeDetector / QuickOpen | 5.8 / 5.11 | 原子写、外部修改双保险（vnode + 激活兜底）、删除标记、Cmd+R 主动重载、最近文件 ≥20 条与 ⌘⇧O 快速打开（M1 已落地） |
| FR-12 大文件保护 | ReadOnlyPolicy | 5.10 | 只读功能矩阵、200MB 不冻结 |

---

## 十、遗留与待定项

| # | 条目 | 责任节点 |
|---|------|----------|
| 1 | 最低 macOS 版本（建议 14+） | 开发确认（PRD 遗留 #1），随 M0 结论定 |
| 2 | P-1 ~ P-6 全部 M0 校准项回填 | M0 完成后本说明书升版 v1.1 |
| 3 | ~~对比栏大文件首次装载卡顿~~ → 已由纯文本模式解决（D-23）。剩余：主编辑器打开 100MB+ 仍走 TextKit（82MB 实测 3s 内可渲染、316MB），规模再大一档需同样切纯文本面板 | M2 |
| 4 | 对比结果不做并排严格对齐（D-21），如后续需要「左右同高」视图，需引入虚拟占位行的只读渲染层 | v1.1+ |
| 3 | 对比视图「差异内编辑同步回原文件」细粒度交互 | M3 时定（PRD 遗留 #3） |
| 4 | XML/Properties 词法器的嵌套边界用例集 | M1 单元测试阶段补全 |
| 5 | SwiftUI Layout vs AppKit 自绘标签最终裁决 | M0 原型 B（P-4） |

---

本设计说明书为产品设计参考，具体实施请结合公司合规与法务要求确认。
