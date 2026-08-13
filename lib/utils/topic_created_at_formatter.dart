String formatTopicCreatedAt(DateTime? dateTime, {DateTime? now}) {
  if (dateTime == null) return '';

  now ??= DateTime.now();
  final hour = dateTime.hour.toString().padLeft(2, '0');
  final minute = dateTime.minute.toString().padLeft(2, '0');
  final clock = '$hour:$minute';
  if (dateTime.year == now.year &&
      dateTime.month == now.month &&
      dateTime.day == now.day) {
    return clock;
  }
  if (dateTime.year == now.year) {
    return '${dateTime.month}月${dateTime.day}日$clock';
  }
  return '${dateTime.year}年${dateTime.month}月${dateTime.day}日$clock';
}
