// Money is stored as integer cents (分) everywhere.

/// Formats cents as yuan with thousands separators, dropping zero decimals:
/// 123456 -> "1,234.56", 100000 -> "1,000". Mirrors alertcopy.FormatYuan (Go).
String formatYuan(int cents) {
  final sign = cents < 0 ? '-' : '';
  final abs = cents.abs();
  final intPart = (abs ~/ 100).toString();
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }
  final frac = abs % 100;
  if (frac != 0) {
    buf.write('.');
    buf.write(frac.toString().padLeft(2, '0'));
  }
  return '$sign$buf';
}

/// "¥1,234.56"
String yuan(int cents) => '¥${formatYuan(cents)}';

/// Parses user input like "12", "12.5", "1,234.56" into cents.
/// Returns null for invalid input or more than two decimals.
int? parseYuan(String input) {
  final s = input.trim().replaceAll(',', '').replaceAll('，', '');
  final match = RegExp(r'^(\d{1,9})(?:\.(\d{0,2}))?$').firstMatch(s);
  if (match == null) return null;
  final whole = int.parse(match.group(1)!);
  final fracStr = (match.group(2) ?? '').padRight(2, '0');
  return whole * 100 + int.parse(fracStr);
}

/// Plain decimal string for an input field: 123450 -> "1234.5", 100 -> "1".
String centsToInput(int cents) {
  final whole = cents ~/ 100;
  final frac = cents % 100;
  if (frac == 0) return '$whole';
  if (frac % 10 == 0) return '$whole.${frac ~/ 10}';
  return '$whole.${frac.toString().padLeft(2, '0')}';
}
