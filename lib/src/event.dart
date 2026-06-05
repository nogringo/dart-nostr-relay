import 'dart:convert';

import 'package:bip340/bip340.dart' as bip340;

import 'utils.dart';

class NostrEvent {
  NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  final String id;
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  final String sig;

  factory NostrEvent.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('event must be an object');
    }
    final id = json['id'];
    final pubkey = json['pubkey'];
    final createdAt = json['created_at'];
    final kind = json['kind'];
    final tags = json['tags'];
    final content = json['content'];
    final sig = json['sig'];
    if (id is! String ||
        pubkey is! String ||
        createdAt is! int ||
        kind is! int ||
        tags is! List ||
        content is! String ||
        sig is! String) {
      throw const FormatException('event has invalid field types');
    }

    return NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: [
        for (final tag in tags)
          if (tag is List)
            [
              for (final value in tag)
                if (value is String) value,
            ]
          else
            throw const FormatException('event tag must be an array'),
      ],
      content: content,
      sig: sig,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': sig,
  };

  String serializeForId() =>
      jsonEncode([0, pubkey, createdAt, kind, tags, content]);

  String computedId() => sha256Hex(serializeForId());

  String? validate({
    Duration timestampTolerance = const Duration(minutes: 15),
  }) {
    if (!isLowerHex64(id)) {
      return 'invalid: event id must be 32-byte lowercase hex';
    }
    if (!isLowerHex64(pubkey)) {
      return 'invalid: pubkey must be 32-byte lowercase hex';
    }
    if (!isLowerHex128(sig)) {
      return 'invalid: signature must be 64-byte lowercase hex';
    }
    if (kind < 0 || kind > 65535) {
      return 'invalid: kind must be between 0 and 65535';
    }
    for (final tag in tags) {
      if (tag.isEmpty) {
        return 'invalid: tags must not be empty';
      }
    }
    final actualId = computedId();
    if (actualId != id) {
      return 'invalid: event id does not match serialized event';
    }
    if (!bip340.verify(pubkey, id, sig)) {
      return 'invalid: signature verification failed';
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (createdAt - now > timestampTolerance.inSeconds) {
      return 'invalid: event creation date is too far in the future';
    }
    return null;
  }

  bool get isReplaceable =>
      kind == 0 || kind == 3 || (kind >= 10000 && kind < 20000);

  bool get isAddressable => kind >= 30000 && kind < 40000;

  bool get isEphemeral => kind >= 20000 && kind < 30000;

  bool get isGiftWrap => kind == 1059 || kind == 21059;

  bool get isPersistentGiftWrap => kind == 1059;

  bool get isEphemeralGiftWrap => kind == 21059;

  String? firstTagValue(String name) {
    for (final tag in tags) {
      if (tag.length > 1 && tag.first == name) {
        return tag[1];
      }
    }
    return null;
  }

  List<String> tagValues(String name) => [
    for (final tag in tags)
      if (tag.length > 1 && tag.first == name) tag[1],
  ];
}
