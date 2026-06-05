import 'dart:async';
import 'dart:convert';

import 'package:bip340/bip340.dart' as bip340;
import 'package:convert/convert.dart';
import 'package:ndk/ndk.dart';
import 'package:nostr_relay/nostr_relay.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  group('events', () {
    test('validates ids and signatures', () {
      final event = signedEvent(kind: 1, content: 'hello');
      expect(event.validate(), isNull);
      expect(event.computedId(), event.id);
    });

    test('accepts historical events and rejects far future events', () {
      final oldEvent = signedEvent(
        kind: 1,
        content: 'from the archive',
        createdAt: now() - 86400 * 30,
      );
      final futureEvent = signedEvent(
        kind: 1,
        content: 'too early',
        createdAt: now() + 3600,
      );

      expect(oldEvent.validate(), isNull);
      expect(futureEvent.validate(), startsWith('invalid:'));
    });
  });

  group('sqlite store', () {
    test('persists, filters and replaces events', () async {
      final store = SqliteRelayStore(':memory:');
      await store.open();
      addTearDown(store.close);

      final first = signedEvent(kind: 0, content: 'old', createdAt: now() - 2);
      final second = signedEvent(kind: 0, content: 'new', createdAt: now() - 1);
      expect((await store.saveEvent(first)).accepted, isTrue);
      expect((await store.saveEvent(second)).accepted, isTrue);

      final events = await store.query([
        NostrFilter(authors: [first.pubkey], kinds: [0]),
      ]);
      expect(events, hasLength(1));
      expect(events.single.id, second.id);
    });

    test('deletes only recipient gift wraps with kind 5 semantics', () async {
      final store = SqliteRelayStore(':memory:');
      await store.open();
      addTearDown(store.close);

      final recipient = pubkeyFor(privateKey1);
      final wrap = signedEvent(
        privateKey: privateKey2,
        kind: 1059,
        tags: [
          ['p', recipient],
        ],
      );
      await store.saveEvent(wrap);
      await store.deleteGiftWrapsByRecipientAndIds(recipient, [wrap.id]);

      final events = await store.query([
        NostrFilter(kinds: [1059]),
      ]);
      expect(events, isEmpty);
    });
  });

  group('websocket relay', () {
    late LocalNostrRelay relay;

    setUp(() async {
      relay = await LocalNostrRelay.start(
        const NostrRelayConfig(databasePath: ':memory:'),
      );
    });

    tearDown(() => relay.stop());

    test('publishes and queries NIP-01 events', () async {
      final channel = WebSocketChannel.connect(relay.uri);
      await channel.ready;
      final reader = StreamIterator<dynamic>(channel.stream);
      addTearDown(() => channel.sink.close());

      expect((await nextMessage(reader)).first, 'AUTH');

      final event = signedEvent(kind: 1, content: 'hello relay');
      channel.sink.add(jsonEncode(['EVENT', event.toJson()]));
      expect(await nextMessage(reader), ['OK', event.id, true, '']);

      channel.sink.add(
        jsonEncode([
          'REQ',
          'sub',
          {
            'kinds': [1],
            'limit': 10,
          },
        ]),
      );
      final eventMessage = await nextMessage(reader);
      expect(eventMessage[0], 'EVENT');
      expect(eventMessage[1], 'sub');
      expect(eventMessage[2]['id'], event.id);
      expect(await nextMessage(reader), ['EOSE', 'sub']);
    });

    test(
      'requires recipient AUTH before serving persistent gift wraps',
      () async {
        final publisher = WebSocketChannel.connect(relay.uri);
        await publisher.ready;
        final publisherReader = StreamIterator<dynamic>(publisher.stream);
        addTearDown(() => publisher.sink.close());
        await nextMessage(publisherReader);

        final recipient = pubkeyFor(privateKey1);
        final wrap = signedEvent(
          privateKey: privateKey2,
          kind: 1059,
          tags: [
            ['p', recipient],
          ],
        );
        publisher.sink.add(jsonEncode(['EVENT', wrap.toJson()]));
        expect(await nextMessage(publisherReader), ['OK', wrap.id, true, '']);

        final unauthenticated = WebSocketChannel.connect(relay.uri);
        await unauthenticated.ready;
        final unauthReader = StreamIterator<dynamic>(unauthenticated.stream);
        addTearDown(() => unauthenticated.sink.close());
        await nextMessage(unauthReader);
        unauthenticated.sink.add(
          jsonEncode([
            'REQ',
            'gifts',
            {
              'kinds': [1059],
            },
          ]),
        );
        final closed = await nextMessage(unauthReader);
        expect(closed[0], 'CLOSED');
        expect(closed[2], startsWith('auth-required:'));

        final recipientChannel = WebSocketChannel.connect(relay.uri);
        await recipientChannel.ready;
        final recipientReader = StreamIterator<dynamic>(
          recipientChannel.stream,
        );
        addTearDown(() => recipientChannel.sink.close());
        final authChallenge = await nextMessage(recipientReader);
        final authEvent = signedEvent(
          privateKey: privateKey1,
          kind: 22242,
          tags: [
            ['relay', relay.uri.toString()],
            ['challenge', authChallenge[1] as String],
          ],
        );
        recipientChannel.sink.add(jsonEncode(['AUTH', authEvent.toJson()]));
        expect(await nextMessage(recipientReader), [
          'OK',
          authEvent.id,
          true,
          '',
        ]);

        recipientChannel.sink.add(
          jsonEncode([
            'REQ',
            'gifts',
            {
              'kinds': [1059],
            },
          ]),
        );
        final eventMessage = await nextMessage(recipientReader);
        expect(eventMessage[0], 'EVENT');
        expect(eventMessage[2]['id'], wrap.id);
      },
    );

    test('applies maxQueryResults to broad REQ responses', () async {
      await relay.stop();
      relay = await LocalNostrRelay.start(
        const NostrRelayConfig(databasePath: ':memory:', maxQueryResults: 1),
      );

      final channel = WebSocketChannel.connect(relay.uri);
      await channel.ready;
      final reader = StreamIterator<dynamic>(channel.stream);
      addTearDown(() => channel.sink.close());
      await nextMessage(reader);

      final first = signedEvent(kind: 1, content: 'first');
      final second = signedEvent(
        kind: 1,
        content: 'second',
        createdAt: now() + 1,
      );
      channel.sink.add(jsonEncode(['EVENT', first.toJson()]));
      expect((await nextMessage(reader))[0], 'OK');
      channel.sink.add(jsonEncode(['EVENT', second.toJson()]));
      expect((await nextMessage(reader))[0], 'OK');

      channel.sink.add(
        jsonEncode([
          'REQ',
          'limited',
          {
            'kinds': [1],
          },
        ]),
      );
      expect((await nextMessage(reader))[0], 'EVENT');
      expect(await nextMessage(reader), ['EOSE', 'limited']);
    });

    test(
      'does not leak gift wrap ids through unauthenticated NIP-77',
      () async {
        final channel = WebSocketChannel.connect(relay.uri);
        await channel.ready;
        final reader = StreamIterator<dynamic>(channel.stream);
        addTearDown(() => channel.sink.close());
        await nextMessage(reader);

        final normal = signedEvent(kind: 1, content: 'public');
        final wrap = signedEvent(
          privateKey: privateKey2,
          kind: 1059,
          tags: [
            ['p', pubkeyFor(privateKey1)],
          ],
        );
        channel.sink.add(jsonEncode(['EVENT', normal.toJson()]));
        expect((await nextMessage(reader))[0], 'OK');
        channel.sink.add(jsonEncode(['EVENT', wrap.toJson()]));
        expect((await nextMessage(reader))[0], 'OK');

        final request = NegentropyMessage(negentropyProtocolVersion, [
          NegentropyRange(
            Bound.infinity(),
            RangeMode.fingerprint,
            List.filled(16, 0),
          ),
        ]);
        channel.sink.add(
          jsonEncode(['NEG-OPEN', 'neg', {}, hex.encode(request.encode())]),
        );

        final responseMessage = await nextMessage(reader);
        expect(responseMessage[0], 'NEG-MSG');
        final response = NegentropyMessage.decode(
          hex.decode(responseMessage[2] as String),
        );
        final payloadHex = hex.encode(response.ranges.single.payload);
        expect(payloadHex, contains(normal.id));
        expect(payloadHex, isNot(contains(wrap.id)));
      },
    );
  });

  group('negentropy', () {
    test('responds to an empty message with an id list', () {
      final records = [RelayRecord(100, '0' * 63 + '1')];

      final responseHex = NegentropyResponder(
        records,
      ).respondHex(hex.encode([negentropyProtocolVersion]));
      final response = NegentropyMessage.decode(hex.decode(responseHex));
      expect(response.ranges, hasLength(1));
      expect(response.ranges.single.mode, RangeMode.idList);
      expect(
        hex.encode(response.ranges.single.payload),
        contains(records.first.id),
      );
    });

    test('skips a matching fingerprint range', () {
      final records = [
        RelayRecord(100, '0' * 63 + '1'),
        RelayRecord(101, '0' * 63 + '2'),
      ];
      final request = NegentropyMessage(negentropyProtocolVersion, [
        NegentropyRange(
          Bound.infinity(),
          RangeMode.fingerprint,
          fingerprintRecords(records),
        ),
      ]);

      final responseHex = NegentropyResponder(
        records,
      ).respondHex(hex.encode(request.encode()));
      final response = NegentropyMessage.decode(hex.decode(responseHex));
      expect(response.ranges.single.mode, RangeMode.skip);
    });

    test('responds with relay ids for a mismatching range', () {
      final records = [
        RelayRecord(100, '0' * 63 + '1'),
        RelayRecord(101, '0' * 63 + '2'),
      ];
      final request = NegentropyMessage(negentropyProtocolVersion, [
        NegentropyRange(
          Bound.infinity(),
          RangeMode.fingerprint,
          List.filled(16, 0),
        ),
      ]);

      final responseHex = NegentropyResponder(
        records,
      ).respondHex(hex.encode(request.encode()));
      final response = NegentropyMessage.decode(hex.decode(responseHex));
      expect(response.ranges, hasLength(1));
      expect(response.ranges.single.mode, RangeMode.idList);
    });
  });

  group('ndk integration dependency', () {
    test('is available for relay-facing integration tests', () {
      expect(Ndk, isA<Type>());
      expect(Nip01Event, isA<Type>());
    });
  });
}

const privateKey1 =
    '0000000000000000000000000000000000000000000000000000000000000001';
const privateKey2 =
    '0000000000000000000000000000000000000000000000000000000000000002';

int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

String pubkeyFor(String privateKey) => bip340.getPublicKey(privateKey);

NostrEvent signedEvent({
  String privateKey = privateKey1,
  int? createdAt,
  required int kind,
  String content = '',
  List<List<String>> tags = const [],
}) {
  final pubkey = pubkeyFor(privateKey);
  final draft = NostrEvent(
    id: '0' * 64,
    pubkey: pubkey,
    createdAt: createdAt ?? now(),
    kind: kind,
    tags: tags,
    content: content,
    sig: '0' * 128,
  );
  final id = draft.computedId();
  final sig = bip340.sign(privateKey, id, '1' * 64);
  return NostrEvent(
    id: id,
    pubkey: pubkey,
    createdAt: draft.createdAt,
    kind: kind,
    tags: tags,
    content: content,
    sig: sig,
  );
}

Future<List<dynamic>> nextMessage(StreamIterator<dynamic> reader) async {
  final hasNext = await reader.moveNext().timeout(const Duration(seconds: 5));
  if (!hasNext) {
    throw StateError('websocket closed before next message');
  }
  return jsonDecode(reader.current as String) as List<dynamic>;
}
