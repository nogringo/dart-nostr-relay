import 'store.dart';

class NostrRelayConfig {
  const NostrRelayConfig({
    this.host = '127.0.0.1',
    this.port = 0,
    this.databasePath = 'nostr_relay.sqlite3',
    this.relayUrl,
    this.maxNegentropyRecords = 50000,
    this.maxQueryResults = 1000,
    this.store,
  });

  final String host;
  final int port;
  final String databasePath;
  final String? relayUrl;
  final int maxNegentropyRecords;
  final int maxQueryResults;
  final RelayStore? store;
}
