## 0.1.2

- Upgrade `liteagent_sdk_dart` to 0.3 and adapt cron execution to the updated
  SDK.
- Add strict limits to background LLM work to prevent runaway memory summary
  and preference extraction loops.
- Disable daemon preset publishing while preserving explicit daemon
  configuration.

## 0.1.1

- Separate vector store and embedding model API keys while preserving backward
  compatibility for existing embeddings configurations.

## 0.1.0

- Initial public release.
- Add `KernelService` and `KernelAdminService` APIs for memory, preference,
  RAG, cron, and health monitoring workflows.
- Use Drift / SQLite for local persistence.
- Support LiteAgent, LiteEmbeddings, and OpenTool daemon integration.
