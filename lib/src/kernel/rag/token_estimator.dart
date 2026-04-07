class TokenEstimator {
  const TokenEstimator();

  int estimate(String text) {
    if (text.trim().isEmpty) {
      return 0;
    }
    final cjkCount = RegExp(
      r'[\u3400-\u9FFF\uF900-\uFAFF]',
    ).allMatches(text).length;
    final latinWordCount = RegExp(r'[A-Za-z0-9_]+').allMatches(text).length;
    final punctuationCount = RegExp(
      r'[^\sA-Za-z0-9_\u3400-\u9FFF\uF900-\uFAFF]',
    ).allMatches(text).length;
    final newlineCount = '\n'.allMatches(text).length;
    final score =
        cjkCount * 1.15 +
        latinWordCount * 1.3 +
        punctuationCount * 0.3 +
        newlineCount * 0.2;
    return score.ceil().clamp(1, 1 << 30);
  }
}
