# 云山修习录 · Yunshan Journal

一个修仙风格的 macOS 个人记录应用：日记、习惯打卡、日程、作息、目标、记账，坚持下来会“涨修为、升境界”。用原生 SwiftUI + SwiftData 编写，数据只存在你自己的电脑上。

> **English summary** — *Yunshan Journal* is a native macOS (SwiftUI + SwiftData) personal journal with a Chinese xianxia ("cultivation") theme. It combines a diary, habit tracker, calendar, weekly routine, goals and a bank-statement-based expense ledger; consistent logging earns XP that advances you through nine cultivation realms. Everything is stored locally. An optional file-based "inbox" lets AI assistants such as Claude Code add entries for you, and every delivery can be undone in one click. The UI is in Simplified Chinese. Requires macOS 14+ and Xcode 16+ to build. MIT licensed.

## 能做什么

| 页面 | 作用 |
|---|---|
| 今日洞府 | 首页：今天要落的笔、待打卡的功课、接下来的日程、目标进度 |
| 修行录 | 日记 / 灵感 / 复盘，带心境；心境月历、往日回看（一周前、一年前的今天）、七日小卷、导出 Markdown / PDF |
| 修士名帖 | 个人档案与目标 |
| 时辰卷 | 日程：周视图、重复规则、单次改期 |
| 起居有常 | 一周固定作息图 |
| 每日功课 | 习惯打卡：每天 / 每周 N 次 / 指定星期，可设数量目标 |
| 灵石账簿 | 导入银行 CSV（按 CommBank 格式）自动分类，月度统计、预算、固定账单检查，也可手记现金 |
| 岁月长卷 | 年度、季度回看 |
| 问道灵枢 | 把记录整理成摘要（可隐去姓名），复制给任意 AI 求建议 |
| 洞府设置 | 外观、提醒、备份与恢复、导出 |

另外还有：

- **随手记**：任何地方按 `⌥⌘J`，或点菜单栏的笔形图标，记一句话
- **修为与境界**：打卡、落笔得修为，从炼气到渡劫共九境，有对应的仪式动画
- **提醒**：落笔时辰、功课时辰、日程开始前、那年今日、周复盘（默认全关）
- **自动备份**：可从备份一键恢复
- **飞剑传书**：让 AI 替你记录（见下文）

## 编译运行

需要 **macOS 14 Sonoma 或更新版本**，以及 **完整的 Xcode 16 或更新版本**（只装 Command Line Tools 不够，SwiftData 的宏要用 Xcode）。

1. 克隆仓库，双击打开 `APT.xcodeproj`
2. 选 scheme「APT」→ My Mac，按 ⌘R

命令行编译：

```bash
xcodebuild -project APT.xcodeproj -scheme APT -configuration Release -derivedDataPath build build
```

编好的应用在 `build/Build/Products/Release/APT.app`（显示名是「云山修习录」），可以拖进“应用程序”文件夹。项目用本机临时签名，不需要开发者账号；从别处下载的 .app 第一次打开时，macOS 可能会拦截，右键 →“打开”即可。

- 数据位置：`~/Library/Application Support/APT-SwiftUI/APT.store`
- 应用没有开启 App 沙盒
- 调试时可设环境变量 `APT_STORE_DIR=/某个空文件夹`，应用会改用那里的数据库和一份独立的偏好设置，不碰正式数据

### 先看看效果：演示数据

调试版可以生成一位虚构用户「青岚」的多年记录，方便试用各个页面：

```bash
APT_STORE_DIR=/tmp/yunshan-demo build/Build/Products/Debug/APT.app/Contents/MacOS/APT --seed-demo 2
```

（`2` 是年数；写 `14d` 则是“刚用了 14 天的新手”。然后同样设着 `APT_STORE_DIR` 打开应用。）

## 飞剑传书：让 AI 替你记录

应用会监视数据目录下的 `AI/inbox/` 文件夹。AI（或任何脚本）把 JSON 放进去，应用几秒内收录，回执写到 `AI/processed/` 或 `AI/failed/`。应用还会维护 `AI/snapshot.md`（数据快照）和 `AI/README.md`（投递格式说明），供 AI 阅读。每一封传书都能在「修行录 → 飞剑传书」里整批撤销。

也可以用命令行投递：

```bash
APT.app/Contents/MacOS/APT --add '{"from":"Claude","items":[{"type":"note","body":"先完成，再完美"}]}'
```

可投递的类型：`diary` / `note` / `review`（修行录）、`expense`（记账）、`event`（日程）、`checkin`（打卡）、`habit`、`goal`、`profile`。

仓库里的 `.claude/skills/apt-record/` 是一个 [Claude Code](https://claude.com/claude-code) 技能。在 Claude Code 里打开这个仓库的文件夹，直接说“帮我记一下：午饭现金 18”“我今天冥想了 10 分钟”“陪我复盘今天”，它会按上面的格式投递或读取快照。

> 隐私提示：使用这个功能时，你的记录会被你选用的 AI 服务读到。应用本身不联网，也不会主动把数据发给任何人。

## 检查与测试

```bash
# 运行时自检（真正的 SwiftData、临时数据目录，不碰正式数据）
APT.app/Contents/MacOS/APT --self-test

# 核心逻辑自检，不需要 Xcode
swiftc APT/Core/*.swift Tools/CoreCheck/main.swift -o /tmp/corecheck && /tmp/corecheck

# 没有 Xcode 时的全量类型检查（用存根替代 SwiftData 宏）
./Tools/typecheck.sh

# 把每个页面在浅色 / 深色下离屏渲染成 PNG（演示数据只在调试版里有）
APT_RENDER_DEMO=2 build/Build/Products/Debug/APT.app/Contents/MacOS/APT --render-pages /tmp/apt-pages
```

（`typecheck.sh` 在 `$TMPDIR/apt-typecheck` 里工作。如果 `TMPDIR` 路径里有中文等非 ASCII 字符，swiftc 会直接崩溃，换成纯英文路径即可。）

## 代码结构

```
APT/
  APTApp.swift     入口
  Core/            纯逻辑，不依赖 SwiftData，可用 Tools/CoreCheck 单独测试
                   （日期与重复规则、修为、统计、记账分类 FinanceEngine、传书格式 Courier、隐去姓名 IdentityRedactor ……）
  Models/          SwiftData 模型
  Services/        数据库、备份恢复、传书收件、提醒、AI 摘要、导出、演示数据、运行时自检 SelfTest+*
  Theme/           配色、字号、山水插画、灵气 / 流云 / 仪式等特效
  Views/           十个页面与共用组件
  Scenery/         插画素材（webp）
Tools/
  CoreCheck/       核心逻辑自检
  typecheck.sh     无 Xcode 时的类型检查
```

### 接入 AI API

「问道灵枢」默认只生成摘要让你复制。若想直接调用某个 AI 接口：在 `APT/Services/AIAdvisor.swift` 里新建一个遵循 `AIAdvisor` 协议的类型（实现 `requestAdvice(prompt:summary:)`），加进 `AIAdvisorRegistry.all`，再把 `AppSettings.aiProvider` 设为它的 `id`。API Key 请存进钥匙串，不要写进代码。

### 记账分类规则

`APT/Core/FinanceEngine.swift` 里的 `rules` 按银行流水描述里的商户名自动分类，目前收的是澳大利亚常见连锁商户。认不出的会进“待确认”，你确认一次后应用会记住这个商户。欢迎按自己所在地区修改规则。

## 素材说明

`APT/Scenery/` 和应用图标中的插画均由 AI 图像生成工具制作，不含第三方图库素材，随本仓库以同一许可证发布。

## 许可证

[MIT](LICENSE)
