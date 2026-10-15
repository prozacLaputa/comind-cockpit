简体中文 | [English](README_EN.md)

# CoMind 驾驶舱

![macOS](https://img.shields.io/badge/macOS-14%2B-black) ![SwiftUI](https://img.shields.io/badge/SwiftUI-native-orange) ![License](https://img.shields.io/badge/license-MIT-blue)

**把长期主题、Codex 会话和已有笔记连成一个原生 Mac 工作台。**

围绕长期关注的「阵地」组织工作：接着上次的会话继续，把值得保留的信息整理回原笔记，再让后续聊天按需读到最新内容。笔记始终是 Markdown 原文件，驾驶舱负责引用、工作过程与核对入口。

![工作总览](docs/screenshots/overview.jpg)

*真实原生界面，截图使用隔离的合成内容；不代表预置资料或真实账户。首次启动为空。*

## 能做什么

- **长期阵地**：主题目标、职责配置、拖拽排序、进展与下一步集中查看。
- **Codex 对话**：关联或新建本机会话、选择可用模型与推理档位、使用 Skills、图片附件、消息排队、回车发送、按问答轮次定位。
- **一份原笔记**：关联已有 Markdown / Obsidian 文件，选择用于聊天的范围，保存整条回复或选中文字时写回已有原件。
- **有依据的整理**：明确新信息与待核对内容分开；支持默认写回目标、版本检查、同源历史与核对后的后续读取。
- **更可靠的日常操作**：草稿恢复、原文件编辑草稿、失败提示与恢复入口、资料搜索、断链重定位、保守的图片清理。
- **桌面体验**：浅色和深色主题、字体大小、悬停反馈、键盘快捷键、中文输入法与长会话浏览。

## 下载

当前为 **v0.2.0 实验版**，支持 **Apple Silicon、macOS 14 或更新系统**。

[下载 CoMind-Cockpit-v0.2.0-macos-arm64.zip](https://github.com/prozacLaputa/comind-cockpit/releases/download/v0.2.0/CoMind-Cockpit-v0.2.0-macos-arm64.zip)

解压后将 `CoMind.app` 移入「应用程序」。此版本为本地 ad-hoc 签名，**未经过 Apple 公证**，系统可能拦截首次打开；可在检查来源后使用 macOS「隐私与安全性」中的允许入口。源码构建见下方。

聊天需要本机可用并已登录的 Codex CLI / Codex 桌面客户端；笔记桥接需要 Python 3。打开文件时按需授权 macOS 文件访问。iCloud Drive 不可用时应用会提示存储问题，请先解决再编辑。

## 第一次使用

1. 创建一个阵地，写下它负责什么；AI 拟出的职责可以调整后确认。
2. 在「工作」中关联现有 Codex 会话，或新建会话。
3. 按 [笔记接入说明](docs/notes.md) 绑定自己的现有笔记库与协作目录，再在阵地「资料」中选择原笔记及聊天使用范围。
4. 保存摘录时选择已有原件；整理结果和待核对项也保留来源。首次接入建议用自己的试用笔记验证流程。

应用**不会安装后台定时任务**。定时增量整理需要另外配置的执行器；本仓库提供手动整理、写回规则和桥接能力，不包含作者的私人自动化、路由或笔记。无需把自己的整个笔记库放进这个代码仓库。

## 与 Codex 的关系

这是独立的第三方客户端，不是 OpenAI 官方产品。应用通过本机 `codex app-server` 使用现有登录和会话；会话关联保存 ID，不复制出另一条聊天。发送消息、生成职责和 AI 进展、AI 整理会发起模型请求，消耗该 Codex 账户的额度。查看、搜索本地文件、修改主题和复制文字不会自行调用模型。

额度与模型按本机服务返回的内容展示，可能随账户与版本变化。应用不附赠额度、不内置 API key；发送给 AI 的授权资料会通过 Codex 使用的服务处理，不能把「文件在本机」理解成模型完全离线。app-server 仍在演进，兼容性问题请附版本和脱敏复现步骤。

## 数据与恢复

- 原笔记留在现有笔记库；协作规则留在自己选择的工作目录。
- 应用布局、引用、草稿等工作状态保存在 iCloud Drive 的 `CoMind 驾驶舱` 目录；云端同步进度由系统管理。
- 编辑原件保留同域修改历史，保存前核对版本；冲突时保留草稿，不静默覆盖外部修改。
- 图片清理只针对可确认未发送、无引用且超过保留期的本应用副本，不删除原始图片。
- 参考 [存储与恢复](docs/storage.md)。GitHub 仓库不包含任何真实账户、会话、笔记或 iCloud 状态。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 发送消息 / 换行 | Enter / Shift + Enter |
| 新建阵地 | ⌘N |
| 记录到原笔记 | ⇧⌘N |
| 打开本地文件 | ⌘O |
| 搜索 | ⇧⌘F |
| 设置 | ⌘, |
| 关闭应用内弹窗 | Esc，或点击遮罩 |

## 开发

需要 macOS、Xcode Command Line Tools 和 Python 3。无需 npm 或网页容器。

```bash
git clone https://github.com/prozacLaputa/comind-cockpit.git
cd comind-cockpit
bash macos/build.sh
open macos/build/CoMind.app
```

构建脚本当前输出 arm64。应用图标随源码提供，界面图标使用 SF Symbols。

```bash
python3 macos/Tests/run-workflow.py
python3 macos/Tests/run-daily.py
python3 -m unittest discover -s tools/scripts/knowledge-bridge -p 'test_*.py'
python3 -m unittest discover -s tools -p 'test_init_workspace.py'
```

测试使用临时目录与模拟 app-server，不读取真实笔记，也不调用模型。更多说明见 [验收范围](docs/testing.md)。

[MIT](LICENSE) · [更新记录](CHANGELOG.md) · [作者作品集](https://prozaclaputa.github.io/)
