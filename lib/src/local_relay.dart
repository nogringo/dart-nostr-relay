import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'event.dart';
import 'filter.dart';
import 'negentropy.dart';
import 'sqlite_store.dart';
import 'store.dart';
import 'utils.dart';

class LocalNostrRelay {
  LocalNostrRelay._(this.config, this._store, this._server);

  final NostrRelayConfig config;
  final RelayStore _store;
  final HttpServer _server;
  final _connections = <_RelayConnection>{};

  Uri get uri {
    final host = _server.address.address == '0.0.0.0'
        ? '127.0.0.1'
        : _server.address.address;
    return Uri(scheme: 'ws', host: host, port: _server.port, path: '/');
  }

  static Future<LocalNostrRelay> start(NostrRelayConfig config) async {
    final store = config.store ?? SqliteRelayStore(config.databasePath);
    await store.open();
    final server = await HttpServer.bind(config.host, config.port);
    final relay = LocalNostrRelay._(config, store, server);
    server.listen(relay._handleRequest, onError: (_) {});
    return relay;
  }

  Future<void> stop() async {
    for (final connection in _connections.toList()) {
      await connection.close();
    }
    await _server.close(force: true);
    await _store.close();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      final connection = _RelayConnection(this, socket);
      _connections.add(connection);
      connection.start();
      return;
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'name': 'nostr_relay',
        'description': 'Embeddable Dart Nostr relay',
        'supported_nips': [1, 42, 59, 77],
        'software': 'nostr_relay',
      }),
    );
    await request.response.close();
  }

  Future<void> _broadcast(NostrEvent event) async {
    for (final connection in _connections.toList()) {
      connection.sendLiveEvent(event);
    }
  }

  String get relayUrl => config.relayUrl ?? uri.toString();
}

class _RelayConnection {
  _RelayConnection(this.relay, this.socket) : challenge = randomHex(32);

  final LocalNostrRelay relay;
  final WebSocket socket;
  final String challenge;
  final authenticatedPubkeys = <String>{};
  final subscriptions = <String, List<NostrFilter>>{};
  final negentropyFilters = <String, List<NostrFilter>>{};
  StreamSubscription<dynamic>? _subscription;

  void start() {
    send(['AUTH', challenge]);
    _subscription = socket.listen(
      _handleMessage,
      onDone: () => relay._connections.remove(this),
      onError: (_) => relay._connections.remove(this),
      cancelOnError: true,
    );
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await socket.close();
    relay._connections.remove(this);
  }

  void send(Object message) {
    if (socket.readyState == WebSocket.open) {
      socket.add(jsonEncode(message));
    }
  }

  Future<void> _handleMessage(dynamic message) async {
    if (message is! String) {
      send(['NOTICE', 'invalid: message must be a JSON string']);
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(message);
    } catch (_) {
      send(['NOTICE', 'invalid: message must be valid JSON']);
      return;
    }
    if (decoded is! List || decoded.isEmpty || decoded.first is! String) {
      send(['NOTICE', 'invalid: message must be a JSON array']);
      return;
    }
    try {
      switch (decoded.first as String) {
        case 'EVENT':
          await _handleEvent(decoded);
        case 'REQ':
          await _handleReq(decoded);
        case 'CLOSE':
          _handleClose(decoded);
        case 'AUTH':
          await _handleAuth(decoded);
        case 'NEG-OPEN':
          await _handleNegOpen(decoded);
        case 'NEG-MSG':
          await _handleNegMsg(decoded);
        case 'NEG-CLOSE':
          _handleNegClose(decoded);
        default:
          send(['NOTICE', 'invalid: unsupported message type']);
      }
    } on FormatException catch (error) {
      send(['NOTICE', 'invalid: ${error.message}']);
    } catch (error) {
      send(['NOTICE', 'error: $error']);
    }
  }

  Future<void> _handleEvent(List<dynamic> message) async {
    if (message.length != 2) {
      send(['NOTICE', 'invalid: EVENT requires exactly one event']);
      return;
    }
    final event = NostrEvent.fromJson(message[1]);
    final validation = event.validate();
    if (validation != null) {
      send(['OK', event.id, false, validation]);
      return;
    }

    if (event.kind == 22242) {
      await _acceptAuthEvent(event);
      return;
    }

    if (event.kind == 5) {
      await _handleDeletionEvent(event);
    } else if (event.kind == 62) {
      await _handleVanishEvent(event);
      send(['OK', event.id, true, '']);
      return;
    }

    StoreSaveResult result;
    if (event.isEphemeral) {
      result = StoreSaveResult.stored;
    } else {
      result = await relay._store.saveEvent(event);
    }
    send(['OK', event.id, result.accepted, result.message]);
    if (result.accepted) {
      await relay._broadcast(event);
    }
  }

  Future<void> _handleAuth(List<dynamic> message) async {
    if (message.length != 2) {
      send(['NOTICE', 'invalid: AUTH requires exactly one event']);
      return;
    }
    final event = NostrEvent.fromJson(message[1]);
    final validation = event.validate();
    if (validation != null) {
      send(['OK', event.id, false, validation]);
      return;
    }
    await _acceptAuthEvent(event);
  }

  Future<void> _acceptAuthEvent(NostrEvent event) async {
    if (event.kind != 22242) {
      send(['OK', event.id, false, 'invalid: auth event must have kind 22242']);
      return;
    }
    if (event.firstTagValue('challenge') != challenge) {
      send(['OK', event.id, false, 'invalid: auth challenge does not match']);
      return;
    }
    final relayTag = event.firstTagValue('relay');
    if (relayTag == null || !_relayTagMatches(relayTag)) {
      send(['OK', event.id, false, 'invalid: auth relay tag does not match']);
      return;
    }
    authenticatedPubkeys.add(event.pubkey);
    send(['OK', event.id, true, '']);
  }

  bool _relayTagMatches(String relayTag) {
    final expected = Uri.parse(relay.relayUrl);
    final actual = Uri.tryParse(relayTag);
    if (actual == null) {
      return false;
    }
    return actual.host == expected.host && actual.port == expected.port;
  }

  Future<void> _handleReq(List<dynamic> message) async {
    if (message.length < 3 || message[1] is! String) {
      send(['NOTICE', 'invalid: REQ requires a subscription id and filters']);
      return;
    }
    final subscriptionId = message[1] as String;
    if (subscriptionId.isEmpty || subscriptionId.length > 64) {
      send([
        'CLOSED',
        subscriptionId,
        'invalid: subscription id must be 1-64 chars',
      ]);
      return;
    }
    final filters = [
      for (final filterJson in message.skip(2))
        NostrFilter.fromJson(filterJson),
    ];
    for (final filter in filters) {
      final validation = filter.validate();
      if (validation != null) {
        send(['CLOSED', subscriptionId, validation]);
        return;
      }
    }
    if (_explicitlyRequiresGiftWrapAuth(filters) &&
        authenticatedPubkeys.isEmpty) {
      send([
        'CLOSED',
        subscriptionId,
        'auth-required: gift wraps require recipient authentication',
      ]);
      return;
    }

    subscriptions[subscriptionId] = filters;
    final events = await relay._store.query(
      filters,
      allowedGiftWrapRecipients: authenticatedPubkeys,
      maxResults: relay.config.maxQueryResults,
    );
    for (final event in events) {
      if (_canSend(event)) {
        send(['EVENT', subscriptionId, event.toJson()]);
      }
    }
    send(['EOSE', subscriptionId]);
  }

  void _handleClose(List<dynamic> message) {
    if (message.length != 2 || message[1] is! String) {
      send(['NOTICE', 'invalid: CLOSE requires a subscription id']);
      return;
    }
    subscriptions.remove(message[1] as String);
  }

  Future<void> _handleNegOpen(List<dynamic> message) async {
    if (message.length != 4 || message[1] is! String || message[3] is! String) {
      send([
        'NEG-ERR',
        message.length > 1 ? message[1] : '',
        'invalid: NEG-OPEN requires id, filter and message',
      ]);
      return;
    }
    final subscriptionId = message[1] as String;
    final filter = NostrFilter.fromJson(message[2]);
    final validation = filter.validate();
    if (validation != null) {
      _sendNegErr(subscriptionId, validation);
      return;
    }
    negentropyFilters[subscriptionId] = [filter];
    await _respondNeg(subscriptionId, [filter], message[3] as String);
  }

  Future<void> _handleNegMsg(List<dynamic> message) async {
    if (message.length != 3 || message[1] is! String || message[2] is! String) {
      send([
        'NEG-ERR',
        message.length > 1 ? message[1] : '',
        'invalid: NEG-MSG requires id and message',
      ]);
      return;
    }
    final subscriptionId = message[1] as String;
    final filters = negentropyFilters[subscriptionId];
    if (filters == null) {
      _sendNegErr(subscriptionId, 'closed: unknown negentropy subscription');
      return;
    }
    await _respondNeg(subscriptionId, filters, message[2] as String);
  }

  void _handleNegClose(List<dynamic> message) {
    if (message.length != 2 || message[1] is! String) {
      send(['NOTICE', 'invalid: NEG-CLOSE requires a subscription id']);
      return;
    }
    negentropyFilters.remove(message[1] as String);
  }

  Future<void> _respondNeg(
    String subscriptionId,
    List<NostrFilter> filters,
    String requestHex,
  ) async {
    if (_explicitlyRequiresGiftWrapAuth(filters) &&
        authenticatedPubkeys.isEmpty) {
      _sendNegErr(
        subscriptionId,
        'auth-required: gift wraps require recipient authentication',
      );
      return;
    }
    final records = await relay._store.records(
      filters,
      limit: relay.config.maxNegentropyRecords + 1,
      allowedGiftWrapRecipients: authenticatedPubkeys,
    );
    if (records.length > relay.config.maxNegentropyRecords) {
      _sendNegErr(
        subscriptionId,
        'blocked: this query is too big',
        relay.config.maxNegentropyRecords,
      );
      return;
    }
    try {
      final response = NegentropyResponder(records).respondHex(requestHex);
      send(['NEG-MSG', subscriptionId, response]);
    } on FormatException catch (error) {
      _sendNegErr(subscriptionId, 'invalid: ${error.message}');
    } catch (error) {
      _sendNegErr(subscriptionId, 'error: $error');
    }
  }

  void _sendNegErr(String subscriptionId, String reason, [int? limit]) {
    negentropyFilters.remove(subscriptionId);
    send(['NEG-ERR', subscriptionId, reason, ?limit]);
  }

  bool _explicitlyRequiresGiftWrapAuth(List<NostrFilter> filters) =>
      filters.any((filter) => filter.explicitlyAsksForGiftWrap);

  Future<void> _handleDeletionEvent(NostrEvent event) async {
    final ids = event.tagValues('e');
    await relay._store.deleteGiftWrapsByRecipientAndIds(event.pubkey, ids);
  }

  Future<void> _handleVanishEvent(NostrEvent event) async {
    final relays = event.tagValues('relay');
    if (relays.contains('ALL_RELAYS') || relays.any(_relayTagMatches)) {
      await relay._store.vanishPubkey(event.pubkey);
    }
  }

  void sendLiveEvent(NostrEvent event) {
    if (!_canSend(event)) {
      return;
    }
    for (final entry in subscriptions.entries) {
      if (entry.value.any((filter) => filter.matches(event))) {
        send(['EVENT', entry.key, event.toJson()]);
      }
    }
  }

  bool _canSend(NostrEvent event) {
    if (!event.isGiftWrap) {
      return true;
    }
    final recipients = event.tagValues('p');
    return recipients.any(authenticatedPubkeys.contains);
  }
}
