import 'dart:io';

import 'package:args/args.dart';
import 'package:nostr_relay/nostr_relay.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'host',
      defaultsTo: '127.0.0.1',
      help: 'Host interface to bind.',
    )
    ..addOption('port', defaultsTo: '7777', help: 'TCP port to bind.')
    ..addOption(
      'database',
      defaultsTo: 'nostr_relay.sqlite3',
      help: 'SQLite database path.',
    )
    ..addOption(
      'relay-url',
      help: 'Public relay URL used for NIP-42 relay tags.',
    )
    ..addOption(
      'max-negentropy-records',
      defaultsTo: '50000',
      help: 'Maximum records processed by one NIP-77 query.',
    )
    ..addOption(
      'max-query-results',
      defaultsTo: '1000',
      help: 'Maximum stored events returned by one REQ.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Print usage.');

  final options = parser.parse(arguments);
  if (options['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }

  final relay = await LocalNostrRelay.start(
    NostrRelayConfig(
      host: options['host'] as String,
      port: int.parse(options['port'] as String),
      databasePath: options['database'] as String,
      relayUrl: options['relay-url'] as String?,
      maxNegentropyRecords: int.parse(
        options['max-negentropy-records'] as String,
      ),
      maxQueryResults: int.parse(options['max-query-results'] as String),
    ),
  );

  stdout.writeln('Nostr relay listening on ${relay.uri}');
  ProcessSignal.sigint.watch().listen((_) async {
    await relay.stop();
    exit(0);
  });
}
