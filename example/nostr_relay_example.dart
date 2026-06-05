import 'package:nostr_relay/nostr_relay.dart';

Future<void> main() async {
  final relay = await LocalNostrRelay.start(
    const NostrRelayConfig(databasePath: ':memory:'),
  );
  print('relay listening on ${relay.uri}');
  await relay.stop();
}
