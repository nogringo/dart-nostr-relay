import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

final _hex64 = RegExp(r'^[0-9a-f]{64}$');
final _hex128 = RegExp(r'^[0-9a-f]{128}$');

bool isLowerHex64(String value) => _hex64.hasMatch(value);

bool isLowerHex128(String value) => _hex128.hasMatch(value);

String sha256Hex(String value) =>
    hex.encode(sha256.convert(utf8.encode(value)).bytes);

String bytesToHex(List<int> bytes) => hex.encode(bytes);

Uint8List hexToBytes(String value) => Uint8List.fromList(hex.decode(value));

String randomHex(int bytes) {
  final random = Random.secure();
  return bytesToHex(List<int>.generate(bytes, (_) => random.nextInt(256)));
}

int compareHexIds(String left, String right) => left.compareTo(right);

int compareBytes(List<int> left, List<int> right) {
  final length = min(left.length, right.length);
  for (var i = 0; i < length; i++) {
    final diff = left[i] - right[i];
    if (diff != 0) {
      return diff;
    }
  }
  return left.length - right.length;
}
