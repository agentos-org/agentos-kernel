# AgentOS Kernel (Service)

This repo exposes a service-first API for the kernel flow (perception → planning → execution).
Only `KernelService` is intended for external use; kernel internals are not part of the public API.

Note: planning-driven intent handoff is being phased out. Deprecated planning APIs remain available
for compatibility, but new integrations should prefer direct execution-oriented APIs and
`ingestAgentMessageForLearning(...)` for external agent transcripts.

## Quick start

Install dependencies:

```
dart pub get
```

Run the service example (edit the placeholders first):

```
dart run example/service_example.dart
```

## KernelService API

Create:
- `KernelService.create(KernelServiceConfig)`
  - Builds the full kernel with LiteAgent perception/planning/learning, OpenTool execution,
    Drift memory (SQLite3), Hive job manager, and Hive preference store with LiteEmbeddings
    vector store.
  - If `llm` is null or `llm.models` is empty, the kernel starts without LLM support. LLM-dependent
    operations (perception/planning/learning/summarization) throw `StateError`.
  - If embeddings cannot be configured, the vector store throws `StateError` when used.

Runtime:
- `subscribeConfirmation({jobId, onNeedsConfirmation})` → `ConfirmationListener`
  - Listen for `NEEDS_CONFIRMATION` updates only. Call `cancel()` to stop listening.
- `createLlmMetrics({requestId, baseUrl, model, apiKey, jobId, userId})` → `LlmMetrics`
  - Report external LLM performance metrics into supervision.
- `ingestAgentMessageForLearning({userId, bundleId, agentMessage})`
  - Record an external `AgentMessage` into memory and forward it into preference learning.
- Cron tasks:
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

Deprecated runtime APIs:
- `recordAgentMessage({userId, bundleId, agentMessage})`
  - Deprecated. Only records the external `AgentMessage` into memory.
- `suggestNextAction({source, allowedActions, memoryLimit})` → `IntentResponseDto`
  - Deprecated. Legacy planning-oriented intent suggestion API.
- `submitRaw({source, content, data})` → `JobHandle`
  - Deprecated. Legacy intent flow entrypoint.
- `submitIntent({source, intent})` → `JobHandle`
  - Deprecated. Legacy direct intent submission API.
- `confirmJob(jobId, confirmed: bool)` → `JobHandle`
  - Deprecated. Legacy confirmation API for planning-driven jobs.

Tools (Planning/Execution):
- `registerLocalOpenTool(Tool tool)`
  - Register local OpenTool callbacks.
- `registerRemoteOpenTool(OpenTool spec, {serverUrl, apiKey})` → `String`
  - Register a remote OpenTool server.
- `updateAppInfoList(List<AppInfo>)`
  - Update the app list used to build the `callApp` OpenTool spec.
- `setAppCalledHandler(AppCalledHandler handler)`
  - Set the app call handler for the `callApp` OpenTool.

Model Configuration:
- `updateLlmModels(List<KernelLlmModel>)`
  - Replace the LLM model list (and enable LLM components if they were not configured).
- `setPresetOpenSpecList(List<PresetOpenSpec>)`
  - Update LiteAgent preset OpenSpec list (called explicitly by external code after init).
- `startOpenToolDaemonPresetSync({daemonApiKey, debounce, presetFilter})`
  - Subscribe to OpenTool daemon tool changes; by default all running tools are
    synchronized into the LiteAgent preset list.
  - Use `presetFilter` to manually choose which daemon tools enter LiteAgent
    presets; filtered-out tools are still registered in the kernel
    `OpenToolDirectory` for planning/execution.
- `setMode(KernelMode mode)` / `getMode()` → `KernelMode`
  - Switch the active routing mode at runtime: `economy`, `balanced` (default), or `performance`.

Read-only Info:
- `getModelHealth()` → `Map<String, ModelHealthSnapshot>`
  - Read model availability (only when AdaptiveSupervision is enabled).
- `getAvailableLlmConfig()` → `LLMConfig?`
  - Read the model that can accept a new request now (health + current model load/concurrency).
  - Returns `null` when no model is currently available.
- `getExternalServiceHealth()` → `ExternalServiceHealthSnapshot`
  - Read LiteAgent/OpenTool/LLM health snapshots.
- `onExternalServiceHealthChange((ExternalServiceHealth) onChange)`
  - Subscribe to external service health updates. Call `cancel()` on the returned
    subscription to stop listening.
- `getMemorySnapshot({scope, limit})` → `MemorySnapshot`
  - Read memory snapshot for a scope (recent records only).
- `getPreferenceSnapshot()` → `PreferenceSnapshot`
  - Read preference snapshot for the default user.
- `getCurrentUserId()` → `String`
  - Return the current user id (currently the default user).


## LLM routing

### Model sources

Each `KernelLlmModel` declares a `source` that indicates where it runs:

| Source | Description | Cost |
|--------|------------|------|
| `LlmModelSource.local` | On-device model (e.g. llama.cpp, Ollama) | Free |
| `LlmModelSource.remote` | Platform-provided cloud model, billed per token | Paid |
| `LlmModelSource.custom` | User-provided endpoint (baseUrl/apiKey/model) | Varies |

### Kernel modes

Users select a mode (like a computer power plan) to control model routing:

| Mode | Priority | Behaviour |
|------|----------|-----------|
| `KernelMode.economy` | local → custom → remote | Avoids remote models except for planning (saves tokens) |
| `KernelMode.balanced` | local → custom → remote | Default; skips local models < 14B for planning |
| `KernelMode.performance` | remote → custom → local | Prefers the most capable model first |

Set the mode at init via `KernelRuntimeConfig(mode: KernelMode.economy)` or
switch at runtime with `service.setMode(KernelMode.performance)`.

### Model profiler

The kernel automatically profiles every LLM call (TTFT, TPS, success rate per purpose).
After 10 calls to a model for a given purpose, models with a success rate below
`profileSuccessRateThreshold` (default 0.4) are skipped in balanced/performance modes.
Profile data is persisted via Hive so it survives restarts.

### Fallback

If no LLM models are provided, LLM-dependent operations throw `StateError`
until `updateLlmModels` is called.
Within each mode the resolver falls back through the source priority list.
If all models are filtered out, the pool returns the first model as a last resort.

## External service health

Adaptive supervision polls external services:
- LiteAgent `/version` (via SDK) every 10s
- OpenTool Daemon `/version` (via SDK) every 10s
- LLM `/health` (baseUrl + `/health`) every 10s after `updateLlmModels`
- LiteEmbeddings `/version` (via SDK) every 10s

Use `getExternalServiceHealth()` for a snapshot and
`onExternalServiceHealthChange(...)` for updates.

## Modules

- Perception: turns raw user input into intent candidates. Uses LiteAgent + LLM; reads memory and preference snapshots for context (no direct persistence).
- Planning: selects the next action based on intent candidates and available tools. Uses LiteAgent + LLM; no direct persistence.
  This module is deprecated and retained for compatibility with legacy intent flows.
- Execution: executes the chosen intent, typically via OpenTool. Emits tool call events; tool calls can be persisted via Drift when enabled.
- Cron: schedules recurring tasks and dispatches them into LiteAgent Auto Multi-Agent sessions via the LiteAgent SDK.
  Current implementation uses an in-memory task store and run log.
- Memory: stores and retrieves long-term records (Drift/SQLite3). Older records can be summarized into `MEMORY_SUMMARY` entries via LiteAgent.
  Planning uses summaries plus recent detailed records for context. Preference learning is deferred and runs when LLM is idle by default.
- Preference: stores user preference signals (Hive) and embeddings (LiteEmbeddings vector DB). Used during perception enrichment.
- Jobs: tracks job lifecycle/status (Hive). Used by all flows that submit work and await completion/confirmation.
- Supervision: monitors LLM calls and tool performance, adjusts concurrency and model health; uses in-memory metrics only.

## Module Flow

High-level call flow:

1. Input → Perception → Planning → Execution
2. Jobs track status through all stages (CREATED → QUEUED → RUNNING → DONE/FAILED/NEEDS_CONFIRMATION)
3. Memory & Preference snapshots are read before planning; new records are written throughout execution
4. OpenTool execution emits ToolCall events; optional Drift storage persists tool call records
5. Supervision observes LLM calls and tool events, adjusts concurrency and model health

## Storage & Persistence

- Hive: stores preference data and job tracking (`.hive/` by default).
- SQLite3 (Drift, memory): `DriftMemory` persists memory records; override `KernelRuntimeConfig.memoryDbPath` to change the SQLite location.
- SQLite3 (optional via Drift): `DriftToolCallStore` persists tool call records when enabled; independent of the main memory/job flow.
- Vector DB (LiteEmbeddings): stores and queries preference embeddings; used for preference enrichment during perception.
- Cron tasks/runs: currently in-memory only. They are not restored after process restart yet.

## Cron Tasks

Use cron tasks when the host application wants to schedule recurring LiteAgent Auto Multi-Agent jobs.

Each cron task contains:
- A cron expression such as `0 */1 * * *`
- A service-level source/user/session identity
- An `AgentCronSpecDto` that maps to LiteAgent `Capability + UserTask`

`AgentCronSpecDto` fields:
- `systemPrompt`: root system prompt for the LiteAgent session
- `content`: LiteAgent `UserTask.content`, allowing text and image inputs
- `timeoutSeconds`: max end-to-end execution time

Model selection:
- Cron tasks do not accept external `llmConfig` or `llmConfigList`.
- The executor resolves the current model from the kernel's available LLM pool at run time.
- Auto mode is always enabled for cron execution.
- Cron tasks do not accept external `openSpecList` or `callbackOpenTool`.
- Tool availability is loaded dynamically from OpenTool daemon at run time.
- Call `setCronOpenToolDaemonApiKey(...)` before running cron tasks that need daemon tools.

Minimal example:

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

Current behavior and limits:
- Cron execution uses LiteAgent SDK sessions directly. It does not go through the deprecated kernel planning flow.
- LLM model selection comes from the kernel's currently available LLM list, not from per-task input.
- Cron tool availability is resolved dynamically from OpenTool daemon for each run.
- Each scheduled run creates a fresh LiteAgent session.
- `skipIfRunning` is the default concurrency policy.
- `replace` is not implemented yet and is reported as a cancelled run.
- The final run result is derived from the last received LiteAgent message.

## Example configuration

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
        // On-device model (free)
        KernelLlmModel(
          baseUrl: 'http://127.0.0.1:11434/v1',
          model: 'qwen2.5:32b',
          description: 'Qwen 2.5 32B local',
          parameters: '32B',
          paramsB: 32,
          quantization: 'Q4_K_M',
          sizeGB: 19.9,
          contextWindowSize: 32768,
          source: LlmModelSource.local,   // default
        ),
        // Platform cloud model (paid per token)
        KernelLlmModel(
          baseUrl: '<REMOTE_API_URL>',
          apiKey: '<REMOTE_API_KEY>',
          model: 'gpt-4o',
          description: 'GPT-4o via platform',
          parameters: '~200B',
          paramsB: 200,
          quantization: 'none',
          sizeGB: 0,
          source: LlmModelSource.remote,
        ),
        // User-provided endpoint (cost varies)
        KernelLlmModel(
          baseUrl: '<CUSTOM_BASE_URL>',
          apiKey: '<CUSTOM_API_KEY>',
          model: '<CUSTOM_MODEL>',
          description: 'User custom model',
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
      apiKey: '<LITE_EMBEDDINGS_API_KEY>', // optional
      docsName: '<LITE_EMBEDDINGS_DOCS_NAME>',
      model: '<EMBEDDINGS_MODEL>', // optional
      llmModel: '<EMBEDDINGS_LLM_MODEL>', // optional
    ),
    runtime: KernelRuntimeConfig(
      mode: KernelMode.balanced,          // optional: economy | balanced | performance
      memoryDbPath: '.hive/kernel_memory.sqlite', // optional: override memory DB path
      memorySummaryEnabled: true,         // optional: auto summarize when LLM is idle
      learningDeferredEnabled: true,      // optional: run preference learning when idle
      opentoolDaemonHost: '127.0.0.1',   // optional
      opentoolDaemonPort: 19627,         // optional
    ),
  ),
);

// Switch mode at runtime
service.setMode(KernelMode.economy);
```

To start without LLM:

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
