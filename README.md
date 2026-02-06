# AgentOS Kernel (Service)

This repo exposes a service-first API for the kernel flow (perception → planning → execution).
Only `KernelService` is intended for external use; kernel internals are not part of the public API.

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

Runtime (Intent Flow):
- `submitRaw({source, content, data})` → `JobHandle`
  - Main entry: submit user content and optional structured data.
- `submitIntent({source, intent})` → `JobHandle`
  - Submit a chosen intent candidate directly (bypasses perception).
- `confirmJob(jobId, confirmed: bool)` → `JobHandle`
  - Confirm or reject a job that requires confirmation.
- `subscribeConfirmation({jobId, onNeedsConfirmation})` → `ConfirmationListener`
  - Listen for `NEEDS_CONFIRMATION` updates only. Call `cancel()` to stop listening.
- `createLlmMetrics({requestId, baseUrl, model, apiKey, jobId, userId})` → `LlmMetrics`
  - Report external LLM performance metrics into supervision.
- `recordAgentMessage({userId, bundleId, agentMessage})`
  - Record an external AgentMessage into memory under the bundle scope.
- `suggestNextAction({source, allowedActions, memoryLimit})` → `IntentResponseDto`
  - Suggest an intent candidate when there is no user input.

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

`KernelServiceConfig` accepts a list of LLM models (or `null` to disable LLM).
The runtime resolver picks the first available model (based on supervision health),
so if the preferred model is unhealthy it falls back to the next model.
For external callers that need the current runnable model, use
`getAvailableLlmConfig()` (health + live concurrency check).
If no LLM models are provided, LLM-dependent operations throw `StateError`
until `updateLlmModels` is called.

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
- Execution: executes the chosen intent, typically via OpenTool. Emits tool call events; tool calls can be persisted via Drift when enabled.
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

## Example configuration

```dart
final service = await KernelService.create(
  KernelServiceConfig(
    liteAgent: LiteAgentConfig(
      baseUrl: '<LITEAGENT_BASE_URL>',
      apiKey: '<LITEAGENT_API_KEY>', // optional
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
          contextWindowSize: 32768, // optional
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
          contextWindowSize: 16384, // optional
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
      memoryDbPath: '.hive/kernel_memory.sqlite', // optional: override memory DB path
      memorySummaryRecentWindow: Duration(hours: 24), // optional
      memorySummaryMaxRecords: 200, // optional
      memorySummaryMinRecords: 20, // optional
      memorySummaryLimit: 5, // optional
      memorySummaryEnabled: true, // optional: auto summarize when LLM is idle
      memorySummaryInterval: Duration(minutes: 5), // optional
      memorySummaryMaxScopesPerRun: 1, // optional
      learningDeferredEnabled: true, // optional: run preference learning when idle
      learningInterval: Duration(minutes: 5), // optional
      learningMaxPerRun: 1, // optional
      learningQueueLimit: 500, // optional
      opentoolDaemonHost: '127.0.0.1', // optional
      opentoolDaemonPort: 19627, // optional
    ),
  ),
);
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
