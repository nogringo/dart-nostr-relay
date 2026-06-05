# nostr_relay

Embeddable Dart Nostr relay for local-first Dart and Flutter native apps.

## Features

- NIP-01 WebSocket relay flow: `EVENT`, `REQ`, `CLOSE`, `OK`, `EOSE`, `CLOSED`, `NOTICE`
- NIP-42 authentication challenges
- NIP-59 gift wrap routing with recipient-only reads for `kind:1059`
- NIP-77 Negentropy responder implemented locally
- Persistent SQLite storage

Flutter native apps should add `sqlite3_flutter_libs` in the host app and pass an
app-owned database path to `NostrRelayConfig`.

## Usage

```dart
final relay = await LocalNostrRelay.start(
  const NostrRelayConfig(databasePath: 'local_relay.sqlite3'),
);

print(relay.uri);

await relay.stop();
```

Run as a standalone relay:

```sh
dart run bin/nostr_relay.dart --port 7777 --database nostr_relay.sqlite3
```
