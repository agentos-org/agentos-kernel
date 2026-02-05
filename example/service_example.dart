import 'dart:async';

import 'package:agentos_kernel/agentos_kernel.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

import 'mock_crud_tool.dart';

Future<void> main() async {
  final liteAgentBaseUrl = '<LITEAGENT_BASE_URL>';
  final liteAgentApiKey = '<LITEAGENT_API_KEY>'; // optional
  final llmBaseUrl = '<LLM_BASE_URL>';
  final llmApiKey = '<LLM_API_KEY>';
  final llmModel = '<LLM_MODEL>';
  final llmDescription = '<LLM_DESCRIPTION>';
  final llmParameters = '<LLM_PARAMETERS>';
  final llmParamsB = 32;
  final llmQuantization = '<LLM_QUANTIZATION>';
  final llmSizeGB = 19.9;
  final embeddingsBaseUrl = '<LITE_EMBEDDINGS_BASE_URL>';
  final embeddingsApiKey = '<LITE_EMBEDDINGS_API_KEY>'; // optional
  final embeddingsDocsName = '<LITE_EMBEDDINGS_DOCS_NAME>';
  final embeddingsModel = '<EMBEDDINGS_MODEL>'; // optional
  final embeddingsLlmModel = '<EMBEDDINGS_LLM_MODEL>'; // optional

  if (_isPlaceholder(liteAgentBaseUrl) ||
      _isPlaceholder(llmBaseUrl) ||
      _isPlaceholder(llmApiKey) ||
      _isPlaceholder(llmModel) ||
      _isPlaceholder(embeddingsBaseUrl) ||
      _isPlaceholder(embeddingsDocsName)) {
    print('Please set LiteAgent/LLM/LiteEmbeddings config variables in example/service_example.dart');
    return;
  }

  final service = await KernelService.create(
    KernelServiceConfig(
      liteAgent: LiteAgentConfig(
        baseUrl: liteAgentBaseUrl,
        apiKey: _optionalValue(liteAgentApiKey),
      ),
      llm: LlmConfigGroup(
        models: [
          KernelLlmModel(
            baseUrl: llmBaseUrl,
            apiKey: _optionalValue(llmApiKey),
            model: llmModel,
            description: _optionalValue(llmDescription) ?? '',
            parameters: _optionalValue(llmParameters) ?? '',
            paramsB: llmParamsB,
            quantization: _optionalValue(llmQuantization) ?? '',
            sizeGB: llmSizeGB,
          ),
        ],
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

  final confirmationListener = service.subscribeConfirmation(
    onNeedsConfirmation: (jobId) {
      service.confirmJob(jobId, confirmed: true);
    },
  );

  await _submitAndDelay(service, 'count');
  await _submitAndDelay(service, 'create Hi');
  await _submitAndDelay(service, 'list');

  service.submitRaw(
    source: KernelSources.cli,
    content: _textContent('delete 1'),
  );
  await _pause();
  await confirmationListener.cancel();
}

Future<void> _submitAndDelay(
  KernelService service,
  String text,
) async {
  service.submitRaw(
    source: KernelSources.cli,
    content: _textContent(text),
  );
  await _pause();
}

Future<void> _pause() async {
  await Future<void>.delayed(const Duration(milliseconds: 400));
}

List<Content> _textContent(String text) {
  return [Content(type: ContentType.text, message: text)];
}

bool _isPlaceholder(String value) => value.startsWith('<') && value.endsWith('>');

String? _optionalValue(String value) {
  if (value.trim().isEmpty || _isPlaceholder(value)) {
    return null;
  }
  return value;
}
