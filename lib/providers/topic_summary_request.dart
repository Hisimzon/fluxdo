class TopicSummaryRequest {
  final int topicId;
  final bool skipAgeCheck;
  final int generation;

  const TopicSummaryRequest(
    this.topicId, {
    this.skipAgeCheck = false,
    this.generation = 0,
  });

  TopicSummaryRequest nextRegeneration() => TopicSummaryRequest(
        topicId,
        skipAgeCheck: true,
        generation: generation + 1,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TopicSummaryRequest &&
          topicId == other.topicId &&
          skipAgeCheck == other.skipAgeCheck &&
          generation == other.generation;

  @override
  int get hashCode => Object.hash(topicId, skipAgeCheck, generation);
}
