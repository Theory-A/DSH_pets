# DSH Pets · DSH 萌宠

**Your agents, with paws. / 让任务多一点陪伴。**

![DSH Pets: three pets reading, waiting, resting and walking above a mock window, with subagent and background-job minis / 三只萌宠及子代理、后台任务迷你宠物的动态演示](<docs/pets-demo.gif>)

*Actual shipped sprites above an illustrated UI—not a screen recording. / 使用实际像素素材制作的模拟界面演示，非屏幕录制。*

[English](#english) · [简体中文](#简体中文)

---

## English

A grey/white Siberian, tuxedo cat and Sheltie perch **outside the native DSH Desktop window**, with their paws on its top edge. They turn chat, subagent and background-job activity into little pixel-art companions.

### Install

**Apple Silicon Mac · macOS 13+ · DSH Desktop**

Tell DSH:

> Install the plugin bundle `@dlwj/dsh-pets`.

1. Allow the plugin installation when DSH asks.
2. Grant **DSH Window Cat** permission in **System Settings → Privacy & Security → Accessibility**. Its menu-bar menu opens settings and lets you retry.
3. Move your DSH window down a little so there is room for the pets above it.

The helper is prebuilt: **no Xcode, Python, npm account or build step needed to use it**. A plain `npm install` does not activate a DSH plugin; install through DSH's plugin manager.

**Beta limitations:** Apple Silicon/macOS only; no Intel, Windows or browser-only/remote DSH support. The helper is ad-hoc signed, not Apple-notarized, so macOS may require additional approval. An upgrade can require Accessibility permission again. Disable any development copy of Window Pet Colony before enabling this package.

### Read the pets

| What you see | What it means |
|---|---|
| Full-size pet reading a book | An active root chat |
| Forward-facing pet with `?` | A chat waiting for your question/approval response |
| Mini pet with `...` | One running local subagent, including nested subagents |
| Mini pet with `*` | One running/stopping Harness-managed background job |
| Wandering, resting, sleeping or stretching | An unassigned resident |

Minis inherit their parent chat's breed and color when ownership is known. **More than three active chats** get extra pets, cycling the breeds with hue-shifted repeats. Existing assignments stay stable. The three original residents remain; extra slots retire when their chat finishes. Dense colonies shrink together to fit the ledge.

Pets stay on focus loss, but foreground windows cover them normally. They hide with minimized/hidden/off-Space/fullscreen DSH, a locked screen, or insufficient space above the window.

### Disable or remove

Disable **DSH Pets** in DSH's Plugins settings to stop the helper. Remove the bundle there to uninstall it. No login item, browser extension, additional server or OS-wide process scanner is installed.

### Privacy and trust

Accessibility is a powerful macOS permission. This helper uses it only for DSH window identity, geometry and lifecycle—not messages, titles, documents, screenshots or job output. Real chat/job identifiers stay inside the Host process; only anonymous pet identities, roles, styles, modes and counts cross a private pipe.

There are **no third-party npm runtime dependencies or install scripts**. Artwork was generated with Codex; no generation or model calls occur at runtime. Code and artwork use the [MIT license](<LICENSE>). DSH plugins execute local code, so install only packages/publishers you trust.

Bounded diagnostics live in the current user's OS temporary directory at `dsh-pets/<host-pid>/status.json`, not inside the installed package. Only live local subagents and Harness-managed jobs are represented—not arbitrary OS processes. Jobs owned by unknown/non-live sessions before activation cannot all be enumerated through the current API; newly observed unknown/unowned jobs get unparented minis. Very small ledges may hide the colony instead of overlapping or dropping individual counts.

### Development

The repository includes Swift source, the prebuilt helper, production sprite atlases and Host tests. Changes are not automatically installed into your active DSH profile.

```sh
npm test
npm run test:native
# Optional rebuild with the Xcode selected by xcode-select / DEVELOPER_DIR:
npm run build:native
# Rebuild the documentation GIF (development only: Python + Pillow + a CJK font):
python3 scripts/render-demo.py
# Pack a release; use a public image URL in the npm README:
npm run pack:release
```

The helper accepts `--validate-fixtures menagerie/native-fixtures.json` without opening normal UI. Stop a running copy before rebuilding its executable. The prebuilt release targets arm64/macOS 13; DSH must provide the `agents`, `jobs` and `subprocess` Host services. The GIF renderer uses a macOS CJK font by default; set `DSH_PETS_FONT` to another suitable font if needed. The GIF is illustrative, not an automated recording of your workspace.

---

## 简体中文

灰白西伯利亚猫、黑白燕尾服猫和喜乐蒂牧羊犬，蹲坐在 **DSH 桌面应用原生窗口的外侧上沿**。它们把对话、子代理和后台任务的工作状态，变成一群可爱的像素伙伴。

### 安装

**Apple Silicon Mac · macOS 13 或更新版本 · DSH 桌面应用**

对 DSH 说：

> 安装插件包 `@dlwj/dsh-pets`。

1. DSH 请求安装授权时，确认允许。
2. 在 **系统设置 → 隐私与安全性 → 辅助功能** 中，允许 **DSH Window Cat**。菜单栏中的萌宠菜单可以打开设置并重试。
3. 把 DSH 窗口稍微向下移动，为顶部的萌宠留出空间。

已包含编译好的原生助手，**使用时无需 Xcode、Python、npm 账号或手动编译**。单独运行 `npm install` 不会启用 DSH 插件，请通过 DSH 的插件管理器安装。

**测试版限制：** 目前仅支持 Apple Silicon Mac，不支持 Intel Mac、Windows、纯浏览器或远程 DSH。助手使用临时签名，尚未经过 Apple 公证，macOS 可能要求额外确认；升级后也可能需要重新授权辅助功能。如果已经安装开发版 Window Pet Colony，请先停用旧版，避免同时运行两套萌宠。

### 看懂萌宠状态

| 看到的状态 | 含义 |
|---|---|
| 大萌宠正在读书 | 一个活跃的主对话 |
| 面向你并显示 `?` | 对话正在等待你的提问或审批回复 |
| 显示 `...` 的迷你萌宠 | 一个运行中的本地子代理，也包括嵌套子代理 |
| 显示 `*` 的迷你萌宠 | 一个运行中或正在停止的 Harness 托管后台任务 |
| 散步、休息、睡觉或伸懒腰 | 尚未分配任务的常驻萌宠 |

能够确定归属时，迷你萌宠会继承主对话的品种和配色。**活跃对话超过三个时**，会按顺序循环使用猫、猫、狗，并为重复轮次调整色相。已有分配保持稳定，不会因其他对话结束而随意换位或变色。三只原始萌宠始终保留，额外位置在对应对话结束后收回；数量较多时会一起缩小以适应窗口上沿。

切换到其他应用后，萌宠仍然存在，但前景窗口会正常遮住它们。DSH 最小化、隐藏、切换到其他桌面空间、进入全屏、屏幕锁定或窗口上方空间不足时，萌宠会隐藏。

### 停用或卸载

在 DSH 的插件设置中停用 **DSH Pets / DSH 萌宠**，即可关闭助手；移除插件包即可卸载。不会安装登录启动项、浏览器扩展、额外服务器或系统级进程扫描器。

### 隐私与信任

辅助功能是一项权限较大的 macOS 授权。本助手仅用它获取 DSH 窗口标识、位置、大小和生命周期信息，**不读取消息、窗口标题、文档、屏幕截图或任务输出**。真实对话和任务标识仅保留在 Host 进程中，通过私有管道传递的只有匿名萌宠标识、角色、配色、状态和数量。

**没有第三方 npm 运行时依赖，也没有安装脚本。** 美术素材由 Codex 生成，运行时不会调用模型或生成图片。代码与素材采用 [MIT 许可证](<LICENSE>)。DSH 插件会执行本地代码，请只安装你信任的来源。

容量受限的诊断信息存放在当前用户的系统临时目录 `dsh-pets/<host-pid>/status.json`，而不是安装包内。仅显示运行中的本地子代理和 Harness 托管任务，不扫描其他系统进程。对于插件启用前已存在、但所属会话未知或已不在运行时中的任务，当前 API 无法完整枚举；新观察到的无归属任务会显示为独立迷你萌宠。窗口上沿实在太小时，会隐藏整群萌宠，而不是重叠显示或悄悄减少数量。

### 开发

仓库包含 Swift 源码、预编译助手、正式精灵图和 Host 测试。修改仓库不会自动改变当前 DSH 配置中的已安装插件。

```sh
npm test
npm run test:native
# 可选：用 xcode-select / DEVELOPER_DIR 指定的 Xcode 重新编译
npm run build:native
# 重新生成说明文档 GIF（仅开发需要 Python、Pillow 和中文字体）
python3 scripts/render-demo.py
# 打包发布文件，为 npm README 使用公开的图片地址
npm run pack:release
```

助手支持 `--validate-fixtures menagerie/native-fixtures.json`，不会启动常规 UI。重新编译前，请先停止正在运行的对应助手。预编译版本面向 arm64/macOS 13，DSH 需要提供 `agents`、`jobs` 和 `subprocess` 服务。GIF 渲染脚本默认使用 macOS 中文字体，也可通过 `DSH_PETS_FONT` 指定其他合适字体。演示 GIF 使用模拟界面，不是对你工作区的录屏。
