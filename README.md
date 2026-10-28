# OmniChat

一款原生 SwiftUI 的 iPhone / iPad 聊天 App,用**你自己的** API 接口对话,同时支持 **OpenAI 协议**(Chat Completions / Responses)和 **Anthropic 协议**(Messages),可自由调节思考程度,支持联网搜索、文件与图片上传。

- 不依赖任何第三方 SDK,网络层基于 `URLSession` 异步字节流自行解析 SSE。
- API Key 只保存在本机钥匙串(Keychain),请求直接从手机发往你填写的地址,不经过任何中转服务器。
- 界面以中文为主,同时提供英文本地化(跟随系统语言)。

## 功能

| 模块 | 说明 |
| --- | --- |
| 多服务商 | 每个服务商包含名称、协议、Base URL、API Key、模型列表;可从 `/models` 拉取模型,也可手动添加 |
| 协议 | OpenAI 兼容 Chat Completions、OpenAI Responses、Anthropic Messages |
| 对话 | 流式输出、Markdown 与代码块渲染(一键复制)、停止生成、重新生成、编辑历史消息并重发、删除消息、多会话(SwiftData 本地存储)、会话搜索与重命名 |
| 随时切换模型 | 对话顶部标题处的菜单可在任意服务商 / 模型间切换 |
| 参数 | 系统提示词、温度(可选是否发送)、最大输出 Tokens |
| 思考程度 | 七档思考:关闭 / 极简 / 低 / 中 / 高 / 超高(xhigh)/ 最大(max),Anthropic 另有「自定义预算」。输入框上方的「🧠 思考」胶囊按钮显示当前档位与冷→暖色强度条,点开为分段滑块(带触感反馈、渐变色、每档中英文说明);档位按协议与模型自动适配,可在服务商模型设置中按模型覆盖;按会话保存,设置里可设全局默认;iPad 快捷键 ⌘⇧T。模型返回的思考内容(Anthropic `thinking_delta`、兼容接口的 `reasoning_content` / `reasoning`、`<think>` 标签、Responses 的推理摘要)以可折叠区块显示 |
| 图片输入 | 相册多选或文件选择,自动压缩到 1568px 以内 |
| 文件上传 | 文本 / 代码 / Markdown / CSV / JSON / PDF(PDFKit 抽取文字),内容会作为附件拼入消息 |
| 联网搜索 | 对话中一键开关。开启后向模型提供 `web_search` 工具(函数调用),App 执行搜索并把结果回传给模型,可多轮调用;后端支持 Tavily(需 Key)和 DuckDuckGo(免 Key) |
| 导出 | 分享为文本、导出 Markdown 文件或 JSON 文件 |
| 外观 | 跟随系统 / 浅色 / 深色 |
| iPad | `NavigationSplitView` 侧边栏布局、支持全部方向、分屏 / 台前调度(Stage Manager)、多窗口;键盘快捷键见下表 |

### 键盘快捷键(iPad 外接键盘)

| 快捷键 | 功能 |
| --- | --- |
| ⌘ N | 新对话 |
| ⌘ ↩ | 发送 |
| ⌘ . | 停止生成 |
| ⌘ R | 重新生成 |
| ⌘ K | 对话设置 |
| ⌘ , | 设置 |

## 下载 IPA

每次推送到 `main` 分支,GitHub Actions 都会在 macOS 机器上自动构建,并发布到 [Releases](../../releases):

- `OmniChat-unsigned.ipa`:**未签名**的 IPA,需要用你的 Apple 开发者账号签名后才能安装。
- `OmniChat-signed.ipa`:只有在你配置了下方的签名 Secrets 后才会出现,可直接安装到已登记的设备上。

打开 [最新 Release](../../releases/latest),在 Assets 中下载即可。

## 安装到 iPhone / iPad

由于 iOS 只允许安装签过名的 App,你可以任选以下一种方式。

### 方式 A:Sideloadly(最简单,Windows / macOS)

1. 安装 [Sideloadly](https://sideloadly.io/),用数据线连接 iPhone / iPad。
2. 把 `OmniChat-unsigned.ipa` 拖进 Sideloadly,输入你的 Apple ID(付费开发者账号签名有效期 1 年,免费账号 7 天)。
3. 点击 Start,完成后在设备的「设置 → 通用 → VPN 与设备管理」中信任你的开发者证书。
4. iOS 16 及以上需要打开「设置 → 隐私与安全性 → 开发者模式」。

### 方式 B:在 CI 中自动签名(推荐付费开发者账号使用)

在 [Apple Developer](https://developer.apple.com/account) 中:

1. 创建 App ID:`com.luodi66.omnichat`(或你自己的 Bundle ID)。
2. 登记要安装的设备 UDID(Ad Hoc / Development 需要)。
3. 创建证书(Apple Distribution 或 Apple Development),在 Mac 的钥匙串中导出为 `.p12` 并设置密码。
4. 创建对应的描述文件(Ad Hoc 或 Development),包含上面的 App ID、证书和设备,下载 `.mobileprovision`。

然后在本仓库「Settings → Secrets and variables → Actions → New repository secret」中添加:

| Secret | 必填 | 内容 |
| --- | --- | --- |
| `BUILD_CERTIFICATE_BASE64` | 是 | `.p12` 文件的 base64:`base64 -i cert.p12 \| pbcopy` |
| `P12_PASSWORD` | 是 | 导出 `.p12` 时设置的密码 |
| `BUILD_PROVISION_PROFILE_BASE64` | 是 | 描述文件的 base64:`base64 -i profile.mobileprovision \| pbcopy` |
| `TEAM_ID` | 是 | 10 位 Team ID(Apple Developer 账户页面可见) |
| `BUNDLE_ID` | 否 | 不填则从描述文件中读取;通配符描述文件时默认 `com.luodi66.omnichat` |
| `EXPORT_METHOD` | 否 | `ad-hoc` / `development` / `app-store` / `enterprise`,不填则根据描述文件自动判断 |

配置后,在 Actions 页面手动运行一次 **Build IPA**(Run workflow),或推送任意提交。构建完成后 Release 中会多出 `OmniChat-signed.ipa`,可通过 Apple Configurator、Finder / iTunes 拖入、或 [Diawi](https://www.diawi.com/) 等方式安装到已登记的设备。使用 App Store 描述文件导出的 IPA 可以用 Transporter 上传到 TestFlight。

> 仓库中不包含任何证书或密钥,所有签名材料都只存在于 GitHub Secrets 中。

### 方式 C:其他重签名工具

也可以使用 [AltStore](https://altstore.io/)、[iOS App Signer](https://dantheman827.github.io/ios-app-signer/)、`fastlane resign` 等工具,用你的证书和描述文件对 `OmniChat-unsigned.ipa` 重签名。

### 方式 D:自己用 Xcode 构建

```bash
brew install xcodegen
xcodegen generate
open OmniChat.xcodeproj
```

在 Xcode 的 Signing & Capabilities 中选择你的 Team,连接设备后直接运行。

## 配置服务商

打开 App → 左上角「设置」→「添加服务商」:

| 字段 | 示例 |
| --- | --- |
| 名称 | OpenAI / DeepSeek / 我的中转 |
| 协议 | OpenAI 兼容 (Chat Completions)、OpenAI Responses、Anthropic Messages |
| Base URL | 见下表 |
| API Key | 你的密钥(保存在钥匙串) |
| 模型 | 点「从服务器获取模型列表」,或手动输入模型 ID |

常见 Base URL:

| 服务 | 协议 | Base URL |
| --- | --- | --- |
| OpenAI | Chat Completions / Responses | `https://api.openai.com/v1` |
| Anthropic | Anthropic Messages | `https://api.anthropic.com` |
| DeepSeek | Chat Completions | `https://api.deepseek.com/v1` |
| OpenRouter | Chat Completions | `https://openrouter.ai/api/v1` |
| 本地 Ollama / LM Studio | Chat Completions | `http://192.168.x.x:11434/v1` |

请求地址拼接规则:

- OpenAI Chat:`{Base URL}/chat/completions`
- OpenAI Responses:`{Base URL}/responses`
- Anthropic:`{Base URL}/v1/messages`(如果 Base URL 已经以 `/v1` 结尾,则拼接 `/messages`)
- 模型列表:OpenAI 为 `{Base URL}/models`,Anthropic 为 `{Base URL}/v1/models`

## 思考程度说明

| 档位 | OpenAI(`reasoning_effort` / Responses `reasoning.effort`) | Anthropic(`thinking.budget_tokens`) |
|---|---|---|
| 关闭 | 不发送 | 不发送 `thinking` |
| 极简 minimal | `minimal` | 1024 |
| 低 low | `low` | 4096 |
| 中 medium | `medium` | 10000 |
| 高 high | `high` | 24000 |
| 超高 xhigh | `xhigh` | 48000 |
| 最大 max | `xhigh`(接口报不支持时自动降为 `high` 重试一次,并在回复下方提示) | 64000 |
| 自定义 | — | 1024–128000 滑块 |

- **自动适配模型**:控件只显示当前模型支持的档位。自动规则:`gpt-5*` 支持 极简~最大;`o1/o3/o4` 等推理模型支持 低/中/高/最大;`gpt-4*`、`gpt-3.5*` 等非推理模型只有「关闭」;Anthropic 支持全部档位(`claude-3-*` 旧模型除外,`claude-3-7` 支持)。如果会话里选的档位当前模型不支持,会自动使用最接近的较低档位并提示。
- **按模型覆盖**:「设置 → 服务商 → 编辑 → 模型列表 → 点某个模型」可手动勾选该模型支持的档位,或恢复自动。
- **默认值**:「设置 → 默认思考程度」决定新会话的初始档位;每个会话单独保存自己的档位。
- OpenAI 开启思考时使用 `max_completion_tokens` 并不发送温度;Responses 接口同时请求 `summary: "auto"`。
- Anthropic 开启思考时自动去掉温度,并确保 `max_tokens` 大于预算;若预算超过模型输出上限,会根据错误信息自动调小并重试。多轮工具调用时会原样回传 thinking 块及其签名。
- 返回的思考内容显示在回复上方的「思考过程」折叠区块中。

## 联网搜索说明

- 在输入框左侧点地球图标开启。模型需要支持函数调用(tools / function calling)。
- 「设置 → 联网搜索」中选择后端:
  - **自动**:填了 Tavily Key 就用 Tavily,否则用 DuckDuckGo。
  - **Tavily**:效果最好,需要在 [tavily.com](https://tavily.com) 申请免费 API Key。
  - **DuckDuckGo**:免 Key,通过解析 `html.duckduckgo.com` 网页实现,可能被限流。
- 搜索的关键词和结果链接会显示在回复上方的「联网搜索」折叠区块中。

## 项目结构

```
project.yml                 XcodeGen 工程描述(CI 中生成 .xcodeproj)
OmniChat/App                App 入口
OmniChat/Models             SwiftData 模型(服务商、对话、消息)
OmniChat/Services           协议客户端(OpenAI Chat / Responses、Anthropic)、SSE、搜索、文件解析、钥匙串、对话引擎
OmniChat/Views              SwiftUI 界面
OmniChat/Resources          图标与本地化
.github/workflows/build.yml CI:构建未签名 IPA、可选签名 IPA、发布 Release
```

## 已知限制

- 需要 iOS / iPadOS 17 及以上。
- 联网搜索依赖模型的函数调用能力;不支持工具调用的模型开启后可能报错,关闭开关即可。
- DuckDuckGo 网页解析可能因页面改版或限流失效,建议使用 Tavily。
- PDF 仅抽取文字,扫描件(纯图片 PDF)无法识别文字;Word / Excel 等二进制格式暂不支持。
- Markdown 渲染为轻量实现,支持标题、列表、引用、代码块、行内格式与链接;表格以等宽文本显示,不渲染 LaTeX 公式。
