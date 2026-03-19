# AgentOS Kernel（Service）

本仓库对外仅提供 Service 入口，核心流程为（感知 → 规划 → 执行）。
外部只建议使用 `KernelService`，kernel 内部实现不作为公开 API。

说明：基于 planning 的意图中转流程正在逐步淘汰。为兼容保留了已弃用 API，
但新的集成应优先使用面向直接执行的接口，以及
`ingestAgentMessageForLearning(...)` 来接入外部 agent 对话。

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

运行时：
- `subscribeConfirmation({jobId, onNeedsConfirmation})` → `ConfirmationListener`
  - 仅订阅 `NEEDS_CONFIRMATION` 更新；通过 `cancel()` 取消订阅。
- `createLlmMetrics({requestId, baseUrl, model, apiKey, jobId, userId})` → `LlmMetrics`
  - 将外部 LLM 性能指标上报给 supervision。
- `ingestAgentMessageForLearning({userId, bundleId, agentMessage})`
  - 将外部 `AgentMessage` 写入 memory，并继续送入偏好学习流程。
- 定时任务：
  - `createCronTask({name, schedule, spec, source, userId, sessionId, timezone, concurrency, enabled})` → `Future<CronTaskDto>`
  - `updateCronTask({cronId, name, schedule, spec, timezone, concurrency, enabled})` → `Future<CronTaskDto>`
  - `deleteCronTask(cronId)` → `Future<void>`
  - `getCronTask(cronId)` → `Future<CronTaskDto>`
  - `listCronTasks({enabled, source, offset, limit})` → `Future<List<CronTaskListItemDto>>`
  - `pauseCronTask(cronId)` / `resumeCronTask(cronId)` → `Future<CronTaskDto>`
  - `runCronTaskNow(cronId, {scheduledAt})` → `Future<CronRunDto>`
  - `getCronRun(runId)` → `Future<CronRunDto>`
  - `listCronRuns({cronId, after, before, offset, limit})` → `Future<List<CronRunListItemDto>>`
  - `listCronRunMessages(runId, {offset, limit})` → `Future<List<CronRunMessageDto>>`
  - `getCronSchedulerSnapshot()` → `Future<CronSchedulerSnapshotDto>`
  - `startCronScheduler()` / `stopCronScheduler()` → `Future<void>`

已弃用运行时 API：
- `recordAgentMessage({userId, bundleId, agentMessage})`
  - 已弃用。仅将外部 `AgentMessage` 写入 memory。
- `suggestNextAction({source, allowedActions, memoryLimit})` → `IntentResponseDto`
  - 已弃用。旧的、面向 planning 的意图建议接口。
- `submitRaw({source, content, data})` → `JobHandle`
  - 已弃用。旧的意图流提交入口。
- `submitIntent({source, intent})` → `JobHandle`
  - 已弃用。旧的直接提交意图接口。
- `confirmJob(jobId, confirmed: bool)` → `JobHandle`
  - 已弃用。旧的、服务于 planning 流程的确认接口。

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
- `startOpenToolDaemonPresetSync({daemonApiKey, debounce, presetFilter})`
  - 订阅 OpenTool daemon 的工具变化；默认同步全部 running 工具到 preset。
  - 可通过 `presetFilter` 手工筛选哪些 daemon 工具进入 LiteAgent preset；
    不匹配的工具仍会注册进 kernel 的 `OpenToolDirectory` 供规划/执行使用。
- `setMode(KernelMode mode)` / `getMode()` → `KernelMode`
  - 运行时切换路由模式：`economy`（省电）、`balanced`（均衡，默认）、`performance`（性能）。

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

### 模型来源

每个 `KernelLlmModel` 通过 `source` 字段声明其运行位置：

| 来源 | 说明 | 费用 |
|------|------|------|
| `LlmModelSource.local` | 本地模型（如 llama.cpp、Ollama） | 免费 |
| `LlmModelSource.remote` | 平台提供的云端模型，按 token 计费 | 付费 |
| `LlmModelSource.custom` | 用户自定义端点（baseUrl/apiKey/model） | 不确定 |

### 内核模式

用户选择一种模式（类似电脑的电源计划）来控制模型路由：

| 模式 | 优先级 | 行为 |
|------|--------|------|
| `KernelMode.economy` | local → custom → remote | 除规划外尽量避免使用远端模型（节省 token） |
| `KernelMode.balanced` | local → custom → remote | 默认；规划阶段跳过小于 14B 的本地模型 |
| `KernelMode.performance` | remote → custom → local | 优先使用最强模型 |

通过 `KernelRuntimeConfig(mode: KernelMode.economy)` 在初始化时设定，
或通过 `service.setMode(KernelMode.performance)` 在运行时切换。

### 模型画像

内核会自动记录每次 LLM 调用的性能画像（TTFT、TPS、各用途的成功率）。
当某模型在某用途上的调用次数 ≥ 10 次且成功率低于 `profileSuccessRateThreshold`
（默认 0.4）时，在 balanced/performance 模式下该模型会被自动跳过。
画像数据通过 Hive 持久化，重启后仍然生效。

### 降级策略

若未配置任何 LLM 模型，依赖 LLM 的逻辑会抛出 `StateError`，直到调用 `updateLlmModels`。
在每种模式下，resolver 按来源优先级依次尝试；
如果所有模型都被过滤，则兜底返回列表中的第一个模型。

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
  该模块已弃用，当前仅为兼容旧意图流而保留。
- 执行（Execution）：执行已选意图，通常通过 OpenTool；产生工具调用事件；工具调用记录可通过 Drift 持久化（可选）。
- 定时（Cron）：负责定时调度任务，并通过 LiteAgent SDK 把任务提交为 LiteAgent Auto Multi-Agent 会话执行。
  当前实现的任务存储和运行记录为内存态。
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
- 定时任务/运行记录：当前仅内存态，不会在进程重启后恢复。

## 定时任务

当宿主应用需要按 cron 表达式定时执行 LiteAgent Auto Multi-Agent 任务时，可使用定时任务接口。

每个定时任务包含：
- 一个 cron 表达式，例如 `0 */1 * * *`
- 一组 service 级别的 `source / userId / sessionId`
- 一个 `AgentCronSpecDto`，内部会映射为 LiteAgent 的 `Capability + UserTask`

`AgentCronSpecDto` 关键字段：
- `systemPrompt`：LiteAgent 根系统提示词
- `content`：LiteAgent 的 `UserTask.content`，可直接支持文字和图片输入
- `timeoutSeconds`：单次任务最长执行时间

模型选择：
- 定时任务不接受外部传入的 `llmConfig` 或 `llmConfigList`。
- 执行时会从 kernel 当前可用的大模型列表中解析并选择模型。
- cron 执行固定走 Auto Multi-Agent，`auto` 不对外暴露。
- 定时任务不接受外部传入的 `openSpecList` 或 `callbackOpenTool`。
- 工具能力会在每次执行时动态从 OpenTool daemon 拉取。
- 若 cron 任务需要 daemon 工具，请先调用 `setCronOpenToolDaemonApiKey(...)`。

最小示例：

```dart
final service = await KernelService.create(
  KernelServiceConfig(
    liteAgentSdk: LiteAgentSDK(
      baseUrl: '<LITEAGENT_BASE_URL>',
      apiKey: '<LITEAGENT_API_KEY>',
    ),
    embeddings: const EmbeddingsConfig(
      baseUrl: '<LITE_EMBEDDINGS_BASE_URL>',
      docsName: 'kernel',
    ),
  ),
);

final task = await service.createCronTask(
  name: 'Nightly CRM Sync',
  schedule: '0 2 * * *',
  source: KernelSources.api,
  spec: AgentCronSpecDto(
    systemPrompt: 'You are an Auto Multi-Agent operator.',
    content: const [
      Content(
        type: ContentType.text,
        message: 'Sync CRM records and summarize failures.',
      ),
    ],
  ),
);

service.startCronScheduler();

final run = await service.runCronTaskNow(task.cronId);
print(run.status);
```

当前行为与限制：
- 定时执行直接走 LiteAgent SDK 会话，不经过已弃用的 kernel planning 流程。
- 大模型选择来自 kernel 当前可用模型列表，而不是单任务输入。
- cron 工具可用性会在每次 run 时动态从 OpenTool daemon 解析。
- 每次触发都会新建一个 LiteAgent session。
- 默认并发策略是 `skipIfRunning`。
- `replace` 暂未实现，当前会记录为 cancelled run。
- 单次运行结果取自最后一条收到的 LiteAgent message。

## 示例配置

```dart
final service = await KernelService.create(
  KernelServiceConfig(
    liteAgent: LiteAgentConfig(
      baseUrl: '<LITEAGENT_BASE_URL>',
      apiKey: '<LITEAGENT_API_KEY>', // 可选
      presetOpenSpecList: const [], // 可选
    ),
    llm: LlmConfigGroup(
      models: const [
        // 本地模型（免费）
        KernelLlmModel(
          baseUrl: 'http://127.0.0.1:11434/v1',
          model: 'qwen2.5:32b',
          description: 'Qwen 2.5 32B 本地',
          parameters: '32B',
          paramsB: 32,
          quantization: 'Q4_K_M',
          sizeGB: 19.9,
          contextWindowSize: 32768,
          source: LlmModelSource.local,   // 默认值
        ),
        // 平台云端模型（按 token 计费）
        KernelLlmModel(
          baseUrl: '<REMOTE_API_URL>',
          apiKey: '<REMOTE_API_KEY>',
          model: 'gpt-4o',
          description: 'GPT-4o 平台云端',
          parameters: '~200B',
          paramsB: 200,
          quantization: 'none',
          sizeGB: 0,
          source: LlmModelSource.remote,
        ),
        // 用户自定义端点（费用不确定）
        KernelLlmModel(
          baseUrl: '<CUSTOM_BASE_URL>',
          apiKey: '<CUSTOM_API_KEY>',
          model: '<CUSTOM_MODEL>',
          description: '用户自定义模型',
          parameters: 'unknown',
          paramsB: 14,
          quantization: 'unknown',
          sizeGB: 0,
          source: LlmModelSource.custom,
        ),
      ],
    ),
    embeddings: EmbeddingsConfig(
      baseUrl: '<LITE_EMBEDDINGS_BASE_URL>',
      apiKey: '<LITE_EMBEDDINGS_API_KEY>', // 可选
      docsName: '<LITE_EMBEDDINGS_DOCS_NAME>',
      model: '<EMBEDDINGS_MODEL>', // 可选
      llmModel: '<EMBEDDINGS_LLM_MODEL>', // 可选
    ),
    runtime: KernelRuntimeConfig(
      mode: KernelMode.balanced,          // 可选：economy | balanced | performance
      memoryDbPath: '.hive/kernel_memory.sqlite', // 可选：修改记忆数据库路径
      memorySummaryEnabled: true,         // 可选：LLM 空闲时自动摘要
      learningDeferredEnabled: true,      // 可选：LLM 空闲时做偏好学习
      opentoolDaemonHost: '127.0.0.1',   // 可选
      opentoolDaemonPort: 19627,         // 可选
    ),
  ),
);

// 运行时切换模式
service.setMode(KernelMode.economy);
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
