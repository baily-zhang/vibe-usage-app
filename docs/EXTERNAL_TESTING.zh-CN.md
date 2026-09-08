# Vibe Usage Test 外测说明

这是未公证的临时外测包，与正式版 Vibe Usage 分开安装和保存界面偏好。
它不会读取其他 macOS 用户的数据，也不会把订阅配额或诊断日志上传到 Vibe Usage。

## 运行条件

- macOS 14 或更新版本。
- 已安装 Node.js 20 或更新版本，并且 `npx` 可用。
- 需要测试的 Codex、Claude Code、Kimi Code、Grok 或 Cursor 已由测试者本人安装、登录和使用。

## 首次打开

1. 解压 `VibeUsage-Test.zip`。
2. 按住 Control 点击 `Vibe Usage Test.app`，选择“打开”。
3. 再次点击系统提示中的“打开”。
4. 如果仍被拦截，请到“系统设置 → 隐私与安全性”，点击对应的“仍要打开”。

请勿覆盖或删除正式版 `Vibe Usage.app`。外测包名为 `Vibe Usage Test.app`。

## 配额测试

- 设置页的“订阅配额”会自动识别本机产品，最多选择两个显示。
- Codex、Claude Code、Kimi Code 使用测试者本人的官方客户端登录状态。
- Grok 只读取官方 CLI 普通日志中已经写入的结构化配额记录；如未显示，请先打开 Grok CLI 使用一次再重新检测。
- Cursor 目前只识别安装状态，等待官方稳定配额接口，不读取 Token、Cookie 或数据库。
- ZCode 只有在测试者主动输入 BigModel 或 Z.ai Coding Plan API Key 后才读取配额；Key 仅保存在外测包独立的本机钥匙串项中。

## 反馈问题

在设置页选择“导出诊断日志…”，把导出的 JSONL 文件发给测试组织者即可。
日志只包含时间、Provider、状态、错误码、计量项数量、应用版本与系统版本，不包含路径、账号、Token、Cookie、API Key、响应正文或聊天内容。

不要发送任何产品的凭据文件、浏览器 Cookie、登录二维码、密码或完整终端日志。
