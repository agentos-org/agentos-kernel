## 0.1.1

- Separate vector store and embedding model API keys while preserving backward
  compatibility for existing embeddings configurations.

## 0.1.0

- Initial public release.
- Add `KernelService` and `KernelAdminService` APIs for memory, preference,
  RAG, cron, and health monitoring workflows.
- Use Drift / SQLite for local persistence.
- Support LiteAgent, LiteEmbeddings, and OpenTool daemon integration.
