# AgentOS Kernel

AgentOS Kernel is a service-first Dart package for:

- storing raw memory as `MemoryItem`
- generating summarized memory as `MemorySummary`
- extracting user preferences as `PreferenceEntry`
- indexing memory/preferences into LiteEmbeddings
- retrieving relevant context for runtime agent prompts
- running cron-driven LiteAgent jobs
- monitoring LiteAgent / OpenTool daemon / embeddings health

External callers should use `KernelService` and `KernelAdminService`. Kernel internals are not public API.

## Quick Start

Install dependencies:

```bash
dart pub get
```

Run the example:

```bash
dart run example/service_example.dart
```

## Current Architecture

### Memory

- Raw layer: `MemoryItem`
- Derived layer: `MemorySummary`
- Persistence: Drift / SQLite
- Retrieval: LiteEmbeddings + local rerank

Memory summaries are generated from raw memory in the background when the LLM queue is idle. Long idle gaps are treated as activity boundaries and are not forced into the same summary segment.

### Preference

- Raw source: selected `MemoryItem` records
- Derived layer: `PreferenceEntry`
- Persistence: Drift / SQLite
- Retrieval: LiteEmbeddings + local rerank

Preference extraction is also a background LLM task. New preference candidates are queued and processed only when the LLM queue is idle.

### Embeddings / VDB

- Memory summaries are indexed into a single docs collection: `memory_summaries`
- Preferences are indexed into a single docs collection: `preferences`
- Embeddings health is monitored continuously
- If embeddings are unavailable:
  - memory/preference generation still continues locally
  - VDB indexing is skipped
  - runtime retrieval returns empty results
- When embeddings recover, the kernel automatically rebuilds missing indexes

### Cron

Cron tasks are persisted in Drift and executed through LiteAgent SDK sessions. They do not use the removed perception/planning/job pipeline.

## Public API

### Create

Bootstrap an empty kernel:

```dart
final service = await KernelService.create();
```

This starts the kernel with local persistence and supervision, but without configured external services.

### Runtime Configuration

Update external services after startup:

- `updateLiteAgentSdk(LiteAgentSDK sdk, {List<PresetOpenSpec>? presetOpenSpecList})`
- `updateLlmModels(List<KernelLlmModel> models, {bool refreshServices = false})`
- `updateLlmServices()`
- `updateEmbeddingsConfig(EmbeddingsConfig config)`
- `updateOpenToolDaemon({required String host, required int port})`
- `startOpenToolDaemonPresetSync({required String daemonApiKey, Duration debounce, DaemonPresetFilter? presetFilter})`
- `stopOpenToolDaemonPresetSync()`
- `setPresetOpenSpecList(List<PresetOpenSpec> presetOpenSpecList)`
- `setMode(KernelMode mode)` / `getMode()`

### Memory Input

Append raw agent/session memory:

- `appendAgentMemoryMessage({required String sessionId, required String taskId, required String actorId, required AgentMemoryActorType actorType, required List<String> content, DateTime? timestamp})`

This writes a `MemoryItem`, marks memory summarization as dirty, and enqueues preference extraction for user/app messages.

### Runtime Retrieval

Retrieve relevant derived context for a user instruction:

- `retrieveRelevantMemorySummaries(String instruction, {int limit = 6, int candidateLimit = 24})`
- `retrieveRelevantPreferences(String instruction, {String? userId, int limit = 3, int candidateLimit = 12})`
- `retrieveRelevantContext(String instruction, {String? userId, int memoryLimit = 6, int memoryCandidateLimit = 24, int preferenceLimit = 3, int preferenceCandidateLimit = 12})`

`retrieveRelevantContext(...)` returns:

- `embeddingsAvailable`
- `memorySummaries`
- `preferences`

If embeddings are down, it returns empty derived results with `embeddingsAvailable == false`.

### Health / Readiness

- `getReadiness({bool requireLlm = true, bool requireLiteAgent = true, bool requireOpenToolDaemon = false, bool requireEmbeddings = false})`
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

Use `KernelAdminService` for raw data inspection and deletion:

- `listMemoryItems(...)`
- `deleteMemoryItem(...)`
- `listMemorySummaries(...)`
- `deleteMemorySummary(...)`
- `triggerMemorySummarization()` returns `MemorySummarizationTriggerResult`
- `listPreferences(...)`
- `triggerPreferenceExtraction()` returns `PreferenceExtractionTriggerResult`
- `deletePreference(...)`
- `clearPreferences({String userId = 'default'})`

`KernelService` is for runtime behavior. `KernelAdminService` is for storage inspection and maintenance.

## Background Trigger Strategy

### Memory Summary

- raw memory writes mark summarization as dirty
- summarization only runs when the LLM queue is idle
- summarization uses low-priority LLM work

### Preference Extraction

- new user/app memory enqueues preference extraction work
- extraction only runs when the LLM queue is idle
- extraction uses low-priority LLM work

This ensures user-facing agent work stays ahead of background summarization/extraction.

## External Service Health

Adaptive supervision monitors:

- LiteAgent
- OpenTool daemon
- embeddings
- LLM model health

Embeddings health affects:

- VDB indexing for memory summaries
- VDB indexing for preferences
- runtime retrieval for relevant memory/preferences

## Storage

This repository now uses Drift / SQLite for its own persistence:

- memory
- preference
- cron
- model profiler

Hive is no longer used directly in this repository. It may still appear as a transitive dependency because `opentool_daemon` currently depends on it.

Default local DB paths:

- `.hive/kernel_memory.sqlite`
- `.hive/kernel_preference.sqlite`
- `.hive/kernel_model_profiles.sqlite`
- `.hive/kernel_cron.sqlite`

These can be overridden via `KernelRuntimeConfig`.

## Minimal Example

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

  await service.updateEmbeddingsConfig(
    const EmbeddingsConfig(
      baseUrl: '<LITE_EMBEDDINGS_BASE_URL>',
      docsName: '<LITE_EMBEDDINGS_DOCS_NAME>',
      model: '<EMBEDDINGS_MODEL>',
      llmModel: '<EMBEDDINGS_LLM_MODEL>',
    ),
  );

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

  print('embeddingsAvailable=${context.embeddingsAvailable}');
  print('memorySummaries=${context.memorySummaries.length}');
  print('preferences=${context.preferences.length}');
}
```
