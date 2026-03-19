import 'package:agentos_kernel/src/kernel/agent/config.dart';
import 'package:agentos_kernel/src/kernel/agent/model.dart';
import 'package:agentos_kernel/src/kernel/supervision/model_profiler.dart';
import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';
import 'package:test/test.dart';

void main() {
  group('KernelLlmModel', () {
    test('supportsImageInput recognizes vision-language model types', () {
      const snakeCase = KernelLlmModel(
        baseUrl: 'http://127.0.0.1:1234',
        model: 'qwen2.5-vl-7b',
        type: 'image_text_to_text',
        description: 'vl model',
        parameters: '7B',
        paramsB: 7,
        quantization: 'q4',
        sizeGB: 5,
      );
      const camelCase = KernelLlmModel(
        baseUrl: 'http://127.0.0.1:1234',
        model: 'gemma3-4b',
        type: 'imageTextToText',
        description: 'vl model',
        parameters: '4B',
        paramsB: 4,
        quantization: 'q4',
        sizeGB: 3,
      );
      const textOnly = KernelLlmModel(
        baseUrl: 'http://127.0.0.1:1234',
        model: 'qwen3-8b',
        type: 'textGeneration',
        description: 'text model',
        parameters: '8B',
        paramsB: 8,
        quantization: 'q4',
        sizeGB: 4,
      );

      expect(snakeCase.supportsImageInput, isTrue);
      expect(camelCase.supportsImageInput, isTrue);
      expect(textOnly.supportsImageInput, isFalse);
    });
  });

  group('LlmConfigPool routing', () {
    test(
      'economy mode falls back to remote when pool has no cheaper source',
      () {
        final pool = LlmConfigPool.fromModels([
          const KernelLlmModel(
            baseUrl: 'https://remote.example',
            model: 'remote-model',
            description: 'remote',
            parameters: '70B',
            paramsB: 70,
            quantization: 'fp16',
            sizeGB: 140,
            source: LlmModelSource.remote,
          ),
        ]);

        final picked = pool.pickForPurpose(
          mode: KernelMode.economy,
          purpose: 'perception',
        );

        expect(picked, isNotNull);
        expect(picked!.model, 'remote-model');
      },
    );

    test('balanced planning skips undersized local model', () {
      final local = const KernelLlmModel(
        baseUrl: 'http://127.0.0.1:1234',
        model: 'small-local',
        description: 'small local',
        parameters: '7B',
        paramsB: 7,
        quantization: 'q4',
        sizeGB: 5,
        source: LlmModelSource.local,
      );
      final remote = const KernelLlmModel(
        baseUrl: 'https://remote.example',
        model: 'remote-strong',
        description: 'remote strong',
        parameters: '70B',
        paramsB: 70,
        quantization: 'fp16',
        sizeGB: 140,
        source: LlmModelSource.remote,
      );
      final pool = LlmConfigPool.fromModels([local, remote]);
      final catalog = {local.modelKey(): local, remote.modelKey(): remote};

      final picked = pool.pickForPurpose(
        mode: KernelMode.balanced,
        purpose: 'planning',
        modelCatalog: catalog,
      );

      expect(picked, isNotNull);
      expect(picked!.model, 'remote-strong');
    });

    test('profiler skip can be relaxed without changing mode ordering', () {
      final local = const KernelLlmModel(
        baseUrl: 'http://127.0.0.1:1234',
        model: 'local-model',
        description: 'local',
        parameters: '8B',
        paramsB: 8,
        quantization: 'q4',
        sizeGB: 6,
        source: LlmModelSource.local,
      );
      final pool = LlmConfigPool.fromModels([local]);
      final profiler = ModelProfiler();

      for (var i = 0; i < 10; i += 1) {
        profiler.record(
          LlmCallMetrics(
            meta: LlmRequestMeta(
              id: 'req-$i',
              purpose: 'perception',
              priority: 0,
              weight: 1,
              modelKey: local.modelKey(),
            ),
            startedAt: DateTime(2026, 3, 6),
            doneAt: DateTime(2026, 3, 6, 0, 0, 1),
            success: false,
          ),
        );
      }

      final strict = pool.pickForPurpose(
        mode: KernelMode.balanced,
        purpose: 'perception',
        profiler: profiler,
        successRateThreshold: 0.4,
      );
      final relaxed = pool.pickForPurpose(
        mode: KernelMode.balanced,
        purpose: 'perception',
        profiler: profiler,
        successRateThreshold: 0.4,
        allowProfilerSkip: false,
      );

      expect(strict, isNull);
      expect(relaxed, isNotNull);
      expect(relaxed!.model, 'local-model');
    });
  });

  group('LlmConfig normalization', () {
    test('trims empty api key to null', () {
      final normalized = normalizeLlmConfigForLiteAgent(
        LLMConfig(
          baseUrl: 'http://127.0.0.1:1234',
          apiKey: '   ',
          model: 'test-model',
        ),
      );

      expect(normalized.apiKey, isNull);
    });
  });
}
