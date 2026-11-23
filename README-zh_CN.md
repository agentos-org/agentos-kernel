# AgentOS Kernel

AgentOS Kernel 是一个面向 Service 的 Dart 包，当前主要能力是：

- 将原始记忆存为 `MemoryItem`
- 将原始记忆提炼为 `MemorySummary`
- 从原始记忆中提取用户偏好为 `PreferenceEntry`
- 在运行时按用户指令检索相关上下文
- 运行基于 LiteAgent 的 cron 任务
- 持续监控 LiteAgent / OpenTool daemon 健康状态

对外建议使用 `KernelService` 和 `KernelAdminService`。kernel 内部模块不作为公开 API。

## 快速开始

安装依赖：

```bash
dart pub get
```

运行示例：

```bash
dart run example/service_example.dart
```

## 当前架构

### Memory

- 原始层：`MemoryItem`
- 提炼层：`MemorySummary`
- 持久化：Drift / SQLite
- 检索使用本地关键词匹配

memory summary 由原始 memory 在后台生成；只有当 LLM 队列空闲时才会执行。长时间无操作会被视为活跃段边界，不会被硬合并进同一段 summary。

### Preference

- 原始来源：部分 `MemoryItem`
- 提炼层：`PreferenceEntry`
- 持久化：Drift / SQLite
- 检索使用本地关键词匹配

preference 提取同样是后台 LLM 任务。新的 user/app memory 只会先入队，等 LLM 空闲时再处理。

### Cron

cron 任务通过 LiteAgent SDK session 执行，不再经过已移除的 perception / planning / job 流程。

## Public API

### 创建

先创建一个空 kernel：

```dart
final service = await KernelService.create();
```

此时本地持久化和 supervision 会启动，但外部服务还未配置。

### 运行时配置

启动后再更新外部服务：

- `updateLiteAgentSdk(LiteAgentSDK sdk, {List<PresetOpenSpec>? presetOpenSpecList})`
- `updateLlmModels(List<KernelLlmModel> models, {bool refreshServices = false})`
- `updateLlmServices()`
- `updateOpenToolDaemon({required String host, required int port})`
- `startOpenToolDaemonPresetSync({required String daemonApiKey, Duration debounce, DaemonPresetFilter? presetFilter})`
- `stopOpenToolDaemonPresetSync()`
- `getOpenToolDaemonPresetSyncSnapshot()`
- `setPresetOpenSpecList(List<PresetOpenSpec> presetOpenSpecList)`
- `setMode(KernelMode mode)` / `getMode()`

### Memory 输入

追加原始 agent/session 记忆：

- `appendAgentMemoryMessage({required String sessionId, required String taskId, required String actorId, required AgentMemoryActorType actorType, required List<String> content, DateTime? timestamp})`

这会写入一个 `MemoryItem`，同时：

- 标记 memory summary 为 dirty
- 对 user/app 类型消息入队 preference 提取任务

### 运行时检索

按用户指令检索相关上下文：

- `retrieveRelevantMemorySummaries(String instruction, {int limit = 6, int candidateLimit = 24})`
- `retrieveRelevantPreferences(String instruction, {String? userId, int limit = 3, int candidateLimit = 12})`
- `retrieveRelevantContext(String instruction, {String? userId, int memoryLimit = 6, int memoryCandidateLimit = 24, int preferenceLimit = 3, int preferenceCandidateLimit = 12})`

`retrieveRelevantContext(...)` 返回：

- `memorySummaries`
- `preferences`


检索直接读取 SQLite 中已有的摘要和偏好。英文按词匹配，忽略大小写。中文匹配连续的双字组合，单字也可以作为查询词。候选项按命中的不同关键词数量排序，再考虑更新时间。记忆摘要还使用时间分桶，偏好按用户筛选。空指令、无命中或对应的限制值小于等于 0 时返回空列表。

### 健康状态 / Readiness

- `getReadiness({bool requireLlm = true, bool requireLiteAgent = true, bool requireOpenToolDaemon = false})`
- `isReady(...)`
- `getExternalServiceHealth()`
- `onExternalServiceHealthChange(...)`
- `getModelHealth()`
- `getAvailableLlmConfig({String purpose = 'external_llm'})`
- `createLlmMetrics(...)`

### Cron

- `createCronTask(...)`
- `updateCronTask(...)`
- `deleteCronTask(...)`
- `getCronTask(...)`
- `listCronTasks(...)`
- `pauseCronTask(...)`
- `resumeCronTask(...)`
- `runCronTaskNow(...)`
- `getCronRun(...)`
- `deleteCronRun(...)`
- `listCronRuns(...)`
- `listCronRunMessages(...)`
- `getCronSchedulerSnapshot()`
- `startCronScheduler()`
- `stopCronScheduler()`

## Admin API

使用 `KernelAdminService` 做存储查看和维护：

- `listMemoryItems(...)`
- `deleteMemoryItem(...)`
- `listMemorySummaries(...)`
- `deleteMemorySummary(...)`
- `triggerMemorySummarization()` 返回 `MemorySummarizationTriggerResult`
- `listPreferences(...)`
- `triggerPreferenceExtraction()` 返回 `PreferenceExtractionTriggerResult`
- `deletePreference(...)`
- `clearPreferences({String userId = 'default'})`

`KernelService` 面向运行时行为。`KernelAdminService` 面向存储查看和维护。

## 后台触发策略

### Memory Summary

- 原始 memory 写入后只标记 dirty
- 只有当 LLM 队列空闲时才执行 summarization
- summary 使用低优先级 LLM 任务

### Preference Extraction

- 新的 user/app memory 只会入队
- 只有当 LLM 队列空闲时才执行提取
- preference extraction 使用低优先级 LLM 任务

这样可以保证面向用户的交互任务优先于后台摘要/偏好提取。

## 外部服务健康

Adaptive supervision 会监控：

- LiteAgent
- OpenTool daemon
- LLM 模型健康

## 存储

当前这个仓库自己的持久化已经统一到 Drift / SQLite：

- memory
- preference
- cron
- model profiler

本仓库代码已经不再直接使用 Hive。依赖树里如果还看到 Hive，是因为 `opentool_daemon` 这个外部依赖当前仍然依赖它。

默认数据库路径：

- `.hive/kernel_memory.sqlite`
- `.hive/kernel_preference.sqlite`
- `.hive/kernel_model_profiles.sqlite`
- `.hive/kernel_cron.sqlite`

可以通过 `KernelRuntimeConfig` 覆盖这些路径。

## 最小示例

```dart
import 'package:agentos_kernel/agentos_kernel.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

Future<void> main() async {
  final service = await KernelService.create();

  await service.updateLiteAgentSdk(
    LiteAgentSDK(
      baseUrl: '<LITEAGENT_BASE_URL>',
      apiKey: '<LITEAGENT_API_KEY>',
    ),
  );

  service.updateLlmModels([
    KernelLlmModel(
      baseUrl: '<LITEAGENT_BASE_URL>',
      apiKey: '<LITEAGENT_API_KEY>',
      model: '<LITEAGENT_MODEL>',
      description: 'runtime model',
      parameters: 'unknown',
      paramsB: 0,
      quantization: 'unknown',
      sizeGB: 0,
    ),
  ]);
  service.updateLlmServices();

  await service.appendAgentMemoryMessage(
    sessionId: 'session-1',
    taskId: 'task-1',
    actorId: 'user-1',
    actorType: AgentMemoryActorType.user,
    content: ['Please keep answers concise and remove deprecated code directly.'],
  );

  final context = await service.retrieveRelevantContext(
    'Update the old kernel API and keep the response concise.',
  );

  print('memorySummaries=${context.memorySummaries.length}');
  print('preferences=${context.preferences.length}');
}
```
