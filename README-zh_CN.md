# AgentOS Kernel（Service）

本仓库对外仅提供 Service 入口，核心流程为（感知 → 规划 → 执行）。
外部只建议使用 `KernelService`，kernel 内部实现不作为公开 API。

## 快速开始

安装依赖：

```
dart pub get
```

运行 service 示例（先编辑占位符）：

```
dart run example/service_example.dart
```

## KernelService API

创建：
- `KernelService.create(KernelServiceConfig)`
  - 组装完整 kernel：LiteAgent 感知/规划/学习、OpenTool 执行、
    使用 Drift 记忆（SQLite3）、Hive 任务管理、
    Hive 偏好存储 + LiteEmbeddings 向量检索。
  - 当 `llm` 为 null 或 `llm.models` 为空时，kernel 可启动但不启用 LLM；
    感知/规划/学习/摘要等依赖 LLM 的逻辑会抛出 `StateError`。
  - embeddings 无法配置时，向量存储在调用时会抛出 `StateError`。

运行时（意图流程）：
- `submitRaw({source, content, data})` → `JobHandle`
  - 主入口：提交用户内容和可选结构化数据。
- `submitIntent({source, intent})` → `JobHandle`
  - 直接提交已选定意图（跳过感知）。
- `confirmJob(jobId, confirmed: bool)` → `JobHandle`
  - 对需要确认的任务进行确认/拒绝。
- `subscribeConfirmation({jobId, onNeedsConfirmation})` → `ConfirmationListener`
  - 仅订阅 `NEEDS_CONFIRMATION` 更新；通过 `cancel()` 取消订阅。
- `createLlmMetrics({requestId, baseUrl, model, apiKey, jobId, userId})` → `LlmMetrics`
  - 将外部 LLM 性能指标上报给 supervision。
- `recordAgentMessage({userId, bundleId, agentMessage})`
  - 记录外部 AgentMessage 到 memory（按 bundle 归档）。
- `suggestNextAction({source, allowedActions, memoryLimit})` → `IntentResponseDto`
  - 在无用户输入时给出意图候选建议。

工具（规划/执行）：
- `registerLocalOpenTool(Tool tool)`
  - 注册本地 OpenTool 回调。
- `registerRemoteOpenTool(OpenTool spec, {serverUrl, apiKey})` → `String`
  - 注册远程 OpenTool Server。
- `updateAppInfoList(List<AppInfo>)`
  - 更新 App 列表并重建 `callApp` OpenTool 规格。
- `setAppCalledHandler(AppCalledHandler handler)`
  - 设置 `callApp` OpenTool 的 App 调用处理器。

模型配置：
- `updateLlmModels(List<KernelLlmModel>)`
  - 替换 LLM 模型列表（若之前未配置 LLM，将启用 LLM 组件）。
- `setPresetOpenSpecList(List<PresetOpenSpec>)`
  - 更新 LiteAgent 的预置 OpenSpec 列表（初始化后由外部显式调用）。

只读信息：
- `getModelHealth()` → `Map<String, ModelHealthSnapshot>`
  - 获取模型可用性（仅在 AdaptiveSupervision 下生效）。
- `getAvailableLlmConfig()` → `LLMConfig?`
  - 获取当前可立即接入新请求的模型（综合健康状态 + 当前并发占用判断）。
  - 若当前没有可用模型，返回 `null`。
- `getExternalServiceHealth()` → `ExternalServiceHealthSnapshot`
  - 获取 LiteAgent/OpenTool/LLM 的健康状态快照。
- `onExternalServiceHealthChange((ExternalServiceHealth) onChange)`
  - 订阅外部服务健康变更；通过返回的 subscription `cancel()` 取消订阅。
- `getMemorySnapshot({scope, limit})` → `MemorySnapshot`
  - 获取指定 scope 的记忆快照（仅返回最近记录）。
- `getPreferenceSnapshot()` → `PreferenceSnapshot`
  - 获取默认用户的偏好快照。
- `getCurrentUserId()` → `String`
  - 获取当前 userId（当前实现为默认用户）。


## LLM 路由

`KernelServiceConfig` 支持一个模型列表（也可传 `null` 来禁用 LLM）。
运行时会选择第一个“可用”的模型（基于 supervision 健康状态），
如果首选模型不可用则自动降级到下一个模型。
如果外部需要查询“此刻可接单”的模型，可使用 `getAvailableLlmConfig()`
（健康状态 + 实时并发能力综合判断）。
如果未提供 LLM 模型，依赖 LLM 的逻辑会抛出 `StateError`，
直到调用 `updateLlmModels` 为止。

## 外部服务健康

Adaptive supervision 会轮询外部服务：
- LiteAgent `/version`（SDK）每 10s
- OpenTool Daemon `/version`（SDK）每 10s
- LLM `/health`（baseUrl + `/health`）在 `updateLlmModels` 之后每 10s
- LiteEmbeddings `/version`（SDK）每 10s

使用 `getExternalServiceHealth()` 获取快照，
使用 `onExternalServiceHealthChange(...)` 订阅更新。

## 模块说明

- 感知（Perception）：将用户输入转换为意图候选，使用 LiteAgent + LLM；读取记忆/偏好快照做上下文补充（不直接持久化）。
- 规划（Planning）：基于意图候选与可用工具选择下一步动作，使用 LiteAgent + LLM（不直接持久化）。
- 执行（Execution）：执行已选意图，通常通过 OpenTool；产生工具调用事件；工具调用记录可通过 Drift 持久化（可选）。
- 记忆（Memory）：长期记录存取（Drift/SQLite3），较早记录可通过 LiteAgent 摘要成 `MEMORY_SUMMARY`，
  规划时同时使用摘要与近期细节作为上下文。偏好学习默认在 LLM 空闲时延迟执行。
- 偏好（Preference）：偏好信号存储（Hive）+ 向量检索（LiteEmbeddings），用于感知阶段的偏好 enrich。
- 任务（Jobs）：任务生命周期与状态跟踪（Hive），供提交/确认/查询流程使用。
- 监督（Supervision）：监控 LLM 调用与工具表现，调整并发与模型健康状态（内存态，不持久化）。

## 模块调用关系

高层流程：

1. 输入 → 感知 → 规划 → 执行
2. Jobs 贯穿全流程（CREATED → QUEUED → RUNNING → DONE/FAILED/NEEDS_CONFIRMATION）
3. 规划前读取 Memory/Preference 快照；执行过程中持续写入记录
4. OpenTool 执行产生 ToolCall 事件；可选 Drift 持久化工具调用记录
5. Supervision 观察 LLM 调用与工具事件，调整并发与模型健康

## 存储与持久化

- Hive：用于偏好数据、任务状态持久化（默认 `.hive/`）。
- SQLite3（Drift，记忆）：`DriftMemory` 持久化记忆记录；可通过 `KernelRuntimeConfig.memoryDbPath` 修改 SQLite 路径。
- SQLite3（可选，Drift）：`DriftToolCallStore` 持久化工具调用记录，仅在启用时使用，独立于主流程存储。
- 向量库（LiteEmbeddings）：用于存储与检索偏好 embedding；在感知阶段的偏好检索/enrich 时使用。

## 示例配置

```dart
final service = await KernelService.create(
  KernelServiceConfig(
    liteAgent: LiteAgentConfig(
      baseUrl: '<LITEAGENT_BASE_URL>',
      apiKey: '<LITEAGENT_API_KEY>', // optional
      presetOpenSpecList: const [], // optional
    ),
    llm: LlmConfigGroup(
      models: const [
        KernelLlmModel(
          baseUrl: '<LLM_BASE_URL>',
          apiKey: '<LLM_API_KEY>',
          model: '<LLM_MODEL>',
          description: '<LLM_DESCRIPTION>',
          parameters: '<LLM_PARAMETERS>',
          paramsB: 32,
          quantization: '<LLM_QUANTIZATION>',
          sizeGB: 19.9,
          contextWindowSize: 32768, // 可选
        ),
        KernelLlmModel(
          baseUrl: '<LLM_BASE_URL_2>',
          apiKey: '<LLM_API_KEY_2>',
          model: '<LLM_MODEL_2>',
          description: '<LLM_DESCRIPTION_2>',
          parameters: '<LLM_PARAMETERS_2>',
          paramsB: 14,
          quantization: '<LLM_QUANTIZATION_2>',
          sizeGB: 8.0,
          contextWindowSize: 16384, // 可选
        ),
      ],
    ),
    embeddings: EmbeddingsConfig(
      baseUrl: '<LITE_EMBEDDINGS_BASE_URL>',
      apiKey: '<LITE_EMBEDDINGS_API_KEY>', // optional
      docsName: '<LITE_EMBEDDINGS_DOCS_NAME>',
      model: '<EMBEDDINGS_MODEL>', // optional
      llmModel: '<EMBEDDINGS_LLM_MODEL>', // optional
    ),
    runtime: KernelRuntimeConfig(
      memoryDbPath: '.hive/kernel_memory.sqlite', // optional: 修改记忆数据库路径
      memorySummaryRecentWindow: Duration(hours: 24), // optional
      memorySummaryMaxRecords: 200, // optional
      memorySummaryMinRecords: 20, // optional
      memorySummaryLimit: 5, // optional
      memorySummaryEnabled: true, // optional: LLM 空闲时自动摘要
      memorySummaryInterval: Duration(minutes: 5), // optional
      memorySummaryMaxScopesPerRun: 1, // optional
      learningDeferredEnabled: true, // optional: LLM 空闲时做偏好学习
      learningInterval: Duration(minutes: 5), // optional
      learningMaxPerRun: 1, // optional
      learningQueueLimit: 500, // optional
      opentoolDaemonHost: '127.0.0.1', // optional
      opentoolDaemonPort: 19627, // optional
    ),
  ),
);
```

无 LLM 启动示例：

```dart
final service = await KernelService.create(
  KernelServiceConfig(
    liteAgent: LiteAgentConfig(baseUrl: '<LITEAGENT_BASE_URL>'),
    embeddings: EmbeddingsConfig(
      baseUrl: '<LITE_EMBEDDINGS_BASE_URL>',
      docsName: '<LITE_EMBEDDINGS_DOCS_NAME>',
    ),
  ),
);
```
