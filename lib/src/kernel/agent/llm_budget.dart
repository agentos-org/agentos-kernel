import 'package:liteagent_sdk_dart/liteagent_sdk_dart.dart';

import 'config.dart';

class LlmInputBudget {
  final LLMConfig config;
  final int contextWindowSize;
  final int reservedTokens;
  final int usableInputTokens;

  const LlmInputBudget({
    required this.config,
    required this.contextWindowSize,
    required this.reservedTokens,
    required this.usableInputTokens,
  });
}

LlmInputBudget resolveLlmInputBudget({
  required LLMConfig fallbackConfig,
  LlmConfigResolver? resolver,
  double reserveRatio = 0.5,
  int minReservedTokens = 4000,
  int maxReservedTokens = 64000,
  int minInputTokens = 2000,
}) {
  final config = normalizeLlmConfigForLiteAgent(
    resolver?.call() ?? fallbackConfig,
  );
  final contextWindowSize = config.contextWindowSize ?? 32000;
  final reservedTokens = (contextWindowSize * reserveRatio).round().clamp(
    minReservedTokens,
    maxReservedTokens,
  );
  final usableInputTokens = (contextWindowSize - reservedTokens).clamp(
    minInputTokens,
    contextWindowSize,
  );
  return LlmInputBudget(
    config: config,
    contextWindowSize: contextWindowSize,
    reservedTokens: reservedTokens,
    usableInputTokens: usableInputTokens,
  );
}

bool isLikelyContextOverflowError(Object error) {
  final text = error.toString().toLowerCase();
  const patterns = [
    'context',
    'maximum context',
    'context length',
    'context window',
    'too many tokens',
    'token limit',
    'prompt is too long',
    'input is too long',
    'maximum tokens',
    'exceeds the limit',
  ];
  var hits = 0;
  for (final pattern in patterns) {
    if (text.contains(pattern)) {
      hits += 1;
    }
  }
  return hits >= 2 ||
      text.contains('context length') ||
      text.contains('too many tokens');
}
