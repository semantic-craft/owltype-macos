# MiniMax 接入核实（2026-10-01）

本文核实官方文档与官方 MCP 源码，不代表账户权限、质量或时延已经通过真实调用验证。研究阶段未读取凭据。动态文档可能继续更新。

## 可实施结论

- 准确模型 ID 为 `MiniMax-M3.1-Flash-Preview`；1,000,000 token 上下文，文本、图像和视频输入。当前仅通过 M Plan / MiniMax Code 提供，不能推定普通按量 Key 可用。[Model Invocation](https://platform.minimax.io/docs/guides/text-generation)
- M3.1 **不能关闭思考**：`thinking.type=disabled` 或 `reasoning_effort=none` 返回 HTTP 400。可用深度为 `low / medium / high / xhigh / max`，默认 `max`。交互式短任务可先用 `low`，但它是否更快且质量足够须实测。`MiniMax-M3` 才支持关闭思考；M2.x 接收关闭参数但忽略。[OpenAI SDK](https://platform.minimax.io/docs/api-reference/text-openai-api)
- 老 Token Plan 可以继续使用 M3.1，不必为了该模型升级套餐；新购入口已转 M Plan。升级会改变历史折扣等权益，不属于代码接入前提。[Existing Token Plan subscribers](https://platform.minimax.io/docs/m-plan/token-plan-notice)

## 端点和鉴权

| 项目 | 已核实参数 |
| --- | --- |
| 国际 Chat | `POST https://api.minimax.io/v1/chat/completions` |
| 国内 Chat | `POST https://api.minimax.cn/v1/chat/completions` |
| 国际 Responses | `POST https://api.minimax.io/v1/responses` |
| 国际 Anthropic | `POST https://api.minimax.io/anthropic/v1/messages` |
| 鉴权 | `Authorization: Bearer <Subscription Key>` |
| M3.1 Chat 思考参数 | `reasoning_effort: "low"` |
| M3.1 Responses 思考参数 | `reasoning: {"effort": "low"}` |
| M3.1 Anthropic 思考参数 | `output_config: {"effort": "low"}` |

来源：[调用指南](https://platform.minimax.io/docs/guides/text-generation)、[国内 OpenAI SDK](https://platform.minimax.cn/docs/api-reference/text-openai-api)、[Responses](https://platform.minimax.io/docs/api-reference/responses-create)。国内文档的旧 `platform.minimaxi.com` 链接目前重定向至 `platform.minimax.cn`；MCP README 仍列旧 API host，不能从文档跳转推断旧 API 已停用。

Subscription Key 与按量 API Key 不能互换；Key 存在不等于已有有效套餐/额度。[Token Plan Quick Start](https://platform.minimax.io/docs/token-plan/quickstart) Key 必须匹配国内/国际 host。[官方 MCP README](https://github.com/MiniMax-AI/MiniMax-Coding-Plan-MCP)

## Chat 输出和 JSON 能力边界

M3.1 的最终文本在 `content`，思考在 `reasoning_content`；流式对应 `delta.content` / `delta.reasoning_content`。`reasoning_split:true` 仅分离输出，不能关闭思考；M3.1 不接受 `false`。多轮工具调用需保留完整 assistant 消息（含思考和工具调用）。新接入使用 `max_completion_tokens`；预算包括思考，过小可能产生 `finish_reason:length` 与空正文。[Chat Completions](https://platform.minimax.io/docs/api-reference/text-chat-openai)、[OpenAI SDK](https://platform.minimax.io/docs/api-reference/text-openai-api)

读取官方原始 schema 后：

- Chat 请求未列 `response_format` 或 `json_object`，不能承诺强制 JSON 模式。[Chat OpenAPI](https://platform.minimax.io/docs/api-reference/text/api/openapi-chat-openai.json)
- Responses 的 `text.format.type` 枚举只有 `text`，未声明 `json_object`；`store` 出现在响应和示例（`false`），未在请求属性中声明。文档确认 SSE，但未给出逐事件的 `response.output_text.delta` 协议保证。[Responses OpenAPI](https://platform.minimax.io/docs/api-reference/text/api/openapi-responses.json)
- 因此，既有应用 JSON 契约应继续由提示词和应用解析验证，不应把未经证明的 OpenAI 参数兼容性当作既成事实。Responses 适配若复用现有栈，需要独立验证上述差异。

## 联网：两种路径

**独立检索 REST 更贴合当前 `OwlWebSearch`。** 官方 MCP 的 `web_search` 实际调用 `POST /v1/coding_plan/search`，请求 JSON 为 `{"q":"检索词"}`，Bearer 鉴权。返回 `organic:[{title,link,snippet,date}]`、`related_searches` 和 `base_resp`；须检查 HTTP 状态及 `base_resp.status_code == 0`。可直接通过 Swift HTTP 客户端适配，无需运行 Python MCP 进程。该结论来自官方开源实现，不是单独发布的稳定 REST 契约。[server.py（固定提交）](https://github.com/MiniMax-AI/MiniMax-Coding-Plan-MCP/blob/5dbf3494d7dac35d154958e0c1dab03910b89bbd/minimax_mcp/server.py)、[client.py](https://github.com/MiniMax-AI/MiniMax-Coding-Plan-MCP/blob/5dbf3494d7dac35d154958e0c1dab03910b89bbd/minimax_mcp/client.py)

**原生服务端搜索**处于 Beta，只列 Anthropic Messages 和 Responses；Chat Completions 没有该原生工具。Responses 用 `tools:[{"type":"web_search"}]`，Anthropic 用 `{"type":"web_search_20250305","name":"web_search"}`。服务端完成搜索循环，客户端读取最终答案。Responses 示例含 `web_search_call.action.query`、`message.content[].annotations[]`，引用类型 `url_citation` 提供 `title/url/start_index/end_index/content`。工具指南示例使用 M3；M3.1 与具体套餐的运行组合仍需实测。搜索可能增加单次请求时间。[Server Tools](https://platform.minimax.io/docs/guides/server-tools)

文档存在同步差异：Server Tools 指南明确展示 `web_search`，Responses OpenAPI 的工具枚举仍只有 `function`。以专门指南确认功能存在，以实测确认当前部署与返回格式。[Server Tools](https://platform.minimax.io/docs/guides/server-tools)、[Responses OpenAPI](https://platform.minimax.io/docs/api-reference/text/api/openapi-responses.json)

## 模型组合与项目能力

以下“搭配”是基于接口与本仓库现状的工程建议，不是模型质量结论。

| Owltype 场景 | 合适组合 | 接入判断 |
| --- | --- | --- |
| 划词润色、翻译、提示词优化、结构化草稿 | M3.1 `low`；M3 关闭思考作延迟对照 | 复用文本通道；验收保真、格式和首个正文延迟 |
| 问一问、带来源回答 | 独立 MiniMax 搜索 + M3.1 | 复用独立检索/回答结构；保留来源链接和检索错误 |
| 复杂长文分析 | M3.1 `medium/high` | 可选扩展；输入法不能因此自动上传额外上下文 |
| 显式图片问答 | M3.1 原生 `image_url` | API 可用；项目需新增显式图片输入，不自动采屏 |
| 语音输入 | `asr-1.0` → M3.1 文本整理 | 独立新能力，不能把音频直接交给 M3.1 Chat |
| 朗读/语音回答 | `speech-2.8-turbo` 或 `speech-2.8-hd` | 独立 TTS 模块，当前文本接入不自动带来播放能力 |
| 图像/视频生成 | 图像模型 / H3 | 与输入法当前核心流程关联弱，暂不扩大实施范围 |

项目依据：[README 隐私边界](../README.md)、[OwlWebSearch](../sources/Lane/OwlWebSearch.swift)、[选中润色](../sources/Lane/OwlSelectionPolish.swift)。模型依据：[模型总览](https://platform.minimax.io/docs/guides/models-intro)、[OpenAI 多模态](https://platform.minimax.io/docs/api-reference/text-openai-api)。

图片支持 JPEG/PNG/GIF/WEBP，单图上限 10 MB；视频 URL/base64 上限 50 MB，Files API 上限 512 MB；Chat 当前不支持音频输入。[国内 OpenAI SDK](https://platform.minimax.cn/docs/api-reference/text-openai-api)

ASR 官方提供 `asr-1.0`，可通过按量或 M Plan 使用：`POST https://api.minimax.cn/v1/speech_to_text`，multipart `model/file`，支持中英混说；最长 500 秒、最大 50 MB。`stream:true` 是**上传完整音频后的 SSE 输出**，不是持续输入音频；不支持裸 PCM。`verbose_json` 可返回说话人和时间戳，但不能与流式输出并用。真正边录边转仍需客户端分段与 VAD。[Speech-to-Text](https://platform.minimax.io/docs/guides/speech-to-text)

## 实测清单及未确认事项

1. M3.1 `low` / `max` 与 M3 `thinking.disabled` 使用相同显式测试文本，记录首个正文时间、总时延、JSON/格式合规、改写保真与 token 用量；不能用第一段思考的到达时间替代正文时延。
2. 请求 M3.1 `disabled` 仅验证预期拒绝；不能把拒绝称作“关闭后效果差”。
3. 验证 Subscription Key 对所选区域、模型、独立搜索和 ASR 的实际权限；不能仅凭套餐宣传推定全功能可用。
4. 验证预算耗尽、限流、HTTP 200 业务错误、空正文和 SSE 仅思考分片能否正确处理。
5. 目前未确认 JSON mode、Responses 请求 `store:false`、逐事件 SSE 完整兼容；未测 M3.1 搜索质量、中文改写质量和延迟。


## 本次落地与验证

已修改工作区代码，未提交、未安装或发布：

- MiniMax 新建档案预设为 M3.1 Flash Preview，模型列表提供 M3 和 M2.7-highspeed；已有档案的选择保持原值。
- 普通问答、润色、提示词优化和任务书共用思考策略：M3.1 `low`、M3 `disabled`；MiniMax 显式分离思考与正文，不发送未经文档保证的 JSON mode。
- 连通性探测为需要思考的 MiniMax 模型保留 4096 token 输出预算，避免沿用 16 token 导致空正文。
- 独立搜索新增“MiniMax 搜索（国内站）”，使用单独保存的同一订阅 Key；保留标题、链接、摘要、日期，检查 HTTP 和业务状态。国际站独立搜索尚未增加设置入口；模型端点可以手工填写国际地址。
- MiniMax Chat 仍不注册为内置联网模型；搜索通过上述独立后端配合默认作答模型。来源核验没有因此自动升级为原生联网核验。

本地 Xcode 构建与相关 185 项测试通过（2026-10-01），覆盖供应商配置、流式正文、结构化任务、检索解析和回退顺序。测试日志：`/tmp/owltype-minimax-tests.log`；使用 `xcodebuild -project Owltype.xcodeproj -scheme Owltype -configuration Debug -derivedDataPath /tmp/owltype-minimax-tests CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test`，以 `-only-testing` 选择 ProviderProfileStoreTests、OwlStreamingChatClientTests、OwlPolishPromptCatalogTests、OwlPromptOptimizerTests、OwlGoalBriefTests、OwlWebSearchTests、OwlMiniMaxSearchTests、OwlAskSearchResolverTests、OwlAskAnythingModuleTests、CandidateStoreTests。

真实调用未完成：本次未找到可用 MiniMax 订阅凭据，也未收到用户补充的配置位置。不能据此宣称模型质量、低思考延迟、账户权限或搜索结果质量已验证。

[`scripts/probe-minimax.py`](../scripts/probe-minimax.py) 提供可重放的合成文本对照：M3.1 low / max、M3 关闭思考，每组润色、翻译、短问答，默认三轮并轮换调用顺序，记录首个正文延迟、总时长、token、JSON 合规与答案。仅统计格式，不自动裁定改写质量。支持进程内 `MINIMAX_API_KEY`，或 `--keychain-account` 从现有应用 Keychain 读取；不把 Key 写进报告或命令行。默认国内站，国际订阅用 `--region global`。报告默认 `/tmp/owltype-minimax-probe.json`。无凭据运行已确认在联网前退出。
