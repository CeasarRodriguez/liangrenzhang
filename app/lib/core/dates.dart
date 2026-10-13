const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

String two(int n) => n.toString().padLeft(2, '0');

/// YYYY-MM-DD for a local date.
String isoDate(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

DateTime parseIsoDate(String s) => DateTime.parse(s);

/// "今天" / "昨天" / "10月12日 周一" (+ year when not this year).
String friendlyDate(String iso, {DateTime? now}) {
  final d = parseIsoDate(iso);
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final diff = today.difference(DateTime(d.year, d.month, d.day)).inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  final base = '${d.month}月${d.day}日 ${_weekdays[d.weekday - 1]}';
  return d.year == n.year ? base : '${d.year}年$base';
}
