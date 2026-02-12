import 'dart:async';

import 'package:agentos_kernel/agentos_kernel.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'mock_crud_tool.dart';

Future<void> main() async {
  // Phase 1+: fill these values when external services are actually up.
  final liteAgentBaseUrl = '<LITEAGENT_BASE_URL>';
  final liteAgentApiKey = '<LITEAGENT_API_KEY>'; // optional
  final liteAgentModel = '<LITEAGENT_MODEL>';
  final embeddingsBaseUrl = '<LITE_EMBEDDINGS_BASE_URL>';
  final embeddingsApiKey = '<LITE_EMBEDDINGS_API_KEY>'; // optional
  final embeddingsDocsName = '<LITE_EMBEDDINGS_DOCS_NAME>';
  final embeddingsModel = '<EMBEDDINGS_MODEL>'; // optional
  final embeddingsLlmModel = '<EMBEDDINGS_LLM_MODEL>'; // optional
  final opentoolDaemonHost = '<OPENTOOL_DAEMON_HOST>';
  const opentoolDaemonPort = 8080;

  final service = await KernelService.create();
  service.registerLocalOpenTool(MockCrudTool());

  final healthSubscription = service.onExternalServiceHealthChange((health) {
    print(
      '[health] ${health.type} ${health.id} available=${health.available} '
      'version=${health.version ?? '-'}',
    );
  });
  final healthSnapshot = service.getExternalServiceHealth();
  print('Initial health items: ${healthSnapshot.items.keys.join(', ')}');
  _printReadiness(service, 'after create');

  print('Phase 0: kernel is up, but external services are not configured yet.');
  try {
    await service.suggestNextAction(source: KernelSources.cli);
  } catch (error) {
    print('Expected error (LLM not configured): $error');
  }

  if (_isConfigured(opentoolDaemonHost)) {
    service.updateOpenToolDaemon(
      host: opentoolDaemonHost,
      port: opentoolDaemonPort,
    );
    print('Phase 1: OpenTool daemon updated.');
    _printReadiness(service, 'after opentool daemon');
  }

  if (_isConfigured(liteAgentBaseUrl)) {
    await service.updateLiteAgentSdk(
      LiteAgentSDK(
        baseUrl: liteAgentBaseUrl,
        apiKey: _optionalValue(liteAgentApiKey),
      ),
    );
    print('Phase 2: LiteAgent SDK updated.');
    _printReadiness(service, 'after liteagent sdk');
  }

  if (_isConfigured(liteAgentBaseUrl) && _isConfigured(liteAgentModel)) {
    service.updateLlmModels([
      KernelLlmModel(
        baseUrl: liteAgentBaseUrl,
        apiKey: _optionalValue(liteAgentApiKey),
        model: liteAgentModel,
        description: 'runtime model',
        parameters: 'unknown',
        paramsB: 0,
        quantization: 'unknown',
        sizeGB: 0,
      ),
    ], refreshServices: false);
    print('Phase 3: LLM model pool updated only (services not refreshed).');
    service.updateLlmServices();
    print('Phase 4: LLM-driven services refreshed.');
    _printReadiness(service, 'after llm services');
  }

  if (_isConfigured(embeddingsBaseUrl) && _isConfigured(embeddingsDocsName)) {
    final ok = await service.updateEmbeddingsConfig(
      EmbeddingsConfig(
        baseUrl: embeddingsBaseUrl,
        apiKey: _optionalValue(embeddingsApiKey),
        docsName: embeddingsDocsName,
        model: _optionalValue(embeddingsModel),
        llmModel: _optionalValue(embeddingsLlmModel),
      ),
    );
    print('Phase 5: embeddings updated: $ok');
    _printReadiness(
      service,
      'after embeddings',
      requireEmbeddings: true,
      requireOpenToolDaemon: true,
    );
  }

  // Optional remote OpenTool endpoint hot switch example:
  // service.updateRemoteOpenToolEndpoint(
  //   '<TOOL_ID>',
  //   serverUrl: '<NEW_OPENTOOL_SERVER_URL>',
  // );

  if (_isConfigured(liteAgentBaseUrl) && _isConfigured(liteAgentModel)) {
    final suggest = await service.suggestNextAction(source: KernelSources.cli);
    print('Suggest candidates: ${suggest.candidates.length}');
  }

  healthSubscription.cancel();
}

bool _isPlaceholder(String value) =>
    value.startsWith('<') && value.endsWith('>');

bool _isConfigured(String value) =>
    value.trim().isNotEmpty && !_isPlaceholder(value);

String? _optionalValue(String value) {
  if (value.trim().isEmpty || _isPlaceholder(value)) {
    return null;
  }
  return value;
}

void _printReadiness(
  KernelService service,
  String phase, {
  bool requireEmbeddings = false,
  bool requireOpenToolDaemon = false,
}) {
  final readiness = service.getReadiness(
    requireEmbeddings: requireEmbeddings,
    requireOpenToolDaemon: requireOpenToolDaemon,
  );
  print('[readiness][$phase] ready=${readiness.ready}');
  if (!readiness.ready) {
    print('[readiness][$phase] reasons=${readiness.reasons.join(' | ')}');
  }
}
