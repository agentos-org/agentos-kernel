import 'package:agentos_kernel/src/kernel/content/content_normalizer.dart';
import 'package:agentos_kernel/src/kernel/agent/model.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:test/test.dart';

void main() {
  group('content normalization', () {
    setUp(() {
      registerKernelLlmModels(const []);
    });

    test('replaces image content with placeholder for text-only models', () {
      registerKernelLlmModels([
        const KernelLlmModel(
          baseUrl: 'http://localhost:1234',
          apiKey: '',
          model: 'llama-3.1-8b-instruct',
          type: 'textGeneration',
          description: 'text only',
          parameters: '8B',
          paramsB: 8,
          quantization: 'q4',
          sizeGB: 5,
        ),
      ]);
      final config = LLMConfig(
        baseUrl: 'http://localhost:1234',
        apiKey: '',
        model: 'llama-3.1-8b-instruct',
      );
      final content = [
        Content(type: ContentType.text, message: 'hello'),
        Content.fromJson({
          'type': 'image',
          'message': 'data:image/png;base64,abc',
        }),
      ];

      final normalized = normalizeContentForModel(content, config);
      expect(normalized, hasLength(2));
      expect(normalized.first.type, ContentType.text);
      expect(normalized.first.message, 'hello');
      expect(normalized.last.type, ContentType.text);
      expect(normalized.last.message, '[image]');
    });

    test('keeps image content for multimodal models', () {
      registerKernelLlmModels([
        const KernelLlmModel(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'test',
          model: 'gpt-4.1',
          type: 'image_text_to_text',
          description: 'multimodal',
          parameters: 'unknown',
          paramsB: 0,
          quantization: 'unknown',
          sizeGB: 0,
          source: LlmModelSource.remote,
        ),
      ]);
      final config = LLMConfig(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'test',
        model: 'gpt-4.1',
      );
      final data = {
        'content': [
          {'type': 'image', 'message': 'data:image/png;base64,abc'},
        ],
      };

      final normalized = normalizeStructuredDataForModel(data, config);
      final content = contentFromStructuredData(data, config);

      expect(normalized?['content'], [
        {'type': 'image', 'message': 'data:image/png;base64,abc'},
      ]);
      expect(content, hasLength(1));
      expect(content.single.toJson()['type'], 'image');
      expect(content.single.message, 'data:image/png;base64,abc');
    });
  });
}
