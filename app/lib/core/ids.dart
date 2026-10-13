import 'dart:math';

final _random = Random.secure();
const _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

/// Client-generated record id in PocketBase's default format (15 chars of
/// [a-z0-9]), so records created offline keep their id once synced.
String newRecordId() => List.generate(15, (_) => _alphabet[_random.nextInt(_alphabet.length)]).join();
