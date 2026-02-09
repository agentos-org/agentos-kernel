import 'dart:async';

import 'package:agentos_kernel/agentos_kernel.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'mock_crud_tool.dart';

Future<void> main() async {
  final liteAgentBaseUrl = '<LITEAGENT_BASE_URL>';
  final liteAgentApiKey = '<LITEAGENT_API_KEY>'; // optional
  final embeddingsBaseUrl = '<LITE_EMBEDDINGS_BASE_URL>';
  final embeddingsApiKey = '<LITE_EMBEDDINGS_API_KEY>'; // optional
  final embeddingsDocsName = '<LITE_EMBEDDINGS_DOCS_NAME>';
  final embeddingsModel = '<EMBEDDINGS_MODEL>'; // optional
  final embeddingsLlmModel = '<EMBEDDINGS_LLM_MODEL>'; // optional

  if (_isPlaceholder(liteAgentBaseUrl)) {
    print(
      'Please set LiteAgent config variables in example/service_example.dart',
    );
    return;
  }
  final service = await KernelService.create(
    KernelServiceConfig(
      liteAgentSdk: LiteAgentSDK(
        baseUrl: liteAgentBaseUrl,
        apiKey: _optionalValue(liteAgentApiKey),
      ),
      embeddings: EmbeddingsConfig(
        baseUrl: embeddingsBaseUrl,
        apiKey: _optionalValue(embeddingsApiKey),
        docsName: embeddingsDocsName,
        model: _optionalValue(embeddingsModel),
        llmModel: _optionalValue(embeddingsLlmModel),
      ),
    ),
  );
  service.registerLocalOpenTool(MockCrudTool());

  final healthSubscription = service.onExternalServiceHealthChange((health) {
    print(
      '[health] ${health.type} ${health.id} available=${health.available} '
      'version=${health.version ?? '-'}',
    );
  });
  final healthSnapshot = service.getExternalServiceHealth();
  print('Initial health items: ${healthSnapshot.items.keys.join(', ')}');

  try {
    await service.suggestNextAction(source: KernelSources.cli);
  } catch (error) {
    print('Expected error (LLM not configured): $error');
  }
  healthSubscription.cancel();
}

bool _isPlaceholder(String value) =>
    value.startsWith('<') && value.endsWith('>');

String? _optionalValue(String value) {
  if (value.trim().isEmpty || _isPlaceholder(value)) {
    return null;
  }
  return value;
}
