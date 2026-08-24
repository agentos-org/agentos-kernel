import 'package:agentos_kernel/agentos_kernel.dart';
import 'package:test/test.dart';

void main() {
  test('background memory and preference processing default to disabled', () {
    const config = KernelRuntimeConfig();

    expect(config.memorySummaryEnabled, isFalse);
    expect(config.preferenceExtractionEnabled, isFalse);
  });

  test('background memory and preference processing remain opt-in', () {
    const config = KernelRuntimeConfig(
      memorySummaryEnabled: true,
      preferenceExtractionEnabled: true,
    );

    expect(config.memorySummaryEnabled, isTrue);
    expect(config.preferenceExtractionEnabled, isTrue);
  });
}
