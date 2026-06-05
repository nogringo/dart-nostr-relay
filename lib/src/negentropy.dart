import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'store.dart';
import 'utils.dart';

const int negentropyProtocolVersion = 0x61;

class NegentropyResponder {
  NegentropyResponder(this.records, {this.maxIdListItems = 64});

  final List<RelayRecord> records;
  final int maxIdListItems;

  String respondHex(String requestHex) {
    final request = NegentropyMessage.decode(hexToBytes(requestHex));
    if (request.version != negentropyProtocolVersion) {
      return bytesToHex([negentropyProtocolVersion]);
    }
    final ranges = request.ranges.isEmpty
        ? [
            NegentropyRange(
              Bound.infinity(),
              RangeMode.idList,
              encodeIdList(records.map((record) => record.id)),
            ),
          ]
        : _respondToRanges(request.ranges);
    return bytesToHex(
      NegentropyMessage(negentropyProtocolVersion, ranges).encode(),
    );
  }

  List<NegentropyRange> _respondToRanges(List<NegentropyRange> clientRanges) {
    final response = <NegentropyRange>[];
    var lower = Bound.zero();
    for (final range in clientRanges) {
      final ours = records
          .where(
            (record) =>
                lower.includesLower(record) &&
                range.upper.includesUpper(record),
          )
          .toList();
      if (range.mode == RangeMode.skip) {
        response.add(NegentropyRange(range.upper, RangeMode.skip, const []));
      } else if (range.mode == RangeMode.fingerprint) {
        final fingerprint = fingerprintRecords(ours);
        if (const ListEquality().equals(fingerprint, range.payload)) {
          response.add(NegentropyRange(range.upper, RangeMode.skip, const []));
        } else if (ours.length > maxIdListItems) {
          response.add(
            NegentropyRange(range.upper, RangeMode.fingerprint, fingerprint),
          );
        } else {
          response.add(
            NegentropyRange(
              range.upper,
              RangeMode.idList,
              encodeIdList(ours.map((record) => record.id)),
            ),
          );
        }
      } else if (range.mode == RangeMode.idList &&
          const ListEquality().equals(
            range.payload,
            encodeIdList(ours.map((record) => record.id)),
          )) {
        response.add(NegentropyRange(range.upper, RangeMode.skip, const []));
      } else {
        response.add(
          NegentropyRange(
            range.upper,
            RangeMode.idList,
            encodeIdList(ours.map((record) => record.id)),
          ),
        );
      }
      lower = range.upper;
    }
    return response;
  }
}

class NegentropyMessage {
  NegentropyMessage(this.version, this.ranges);

  final int version;
  final List<NegentropyRange> ranges;

  factory NegentropyMessage.decode(List<int> bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('empty negentropy message');
    }
    final reader = _ByteReader(bytes);
    final version = reader.readByte();
    final ranges = <NegentropyRange>[];
    var previousTimestamp = 0;
    while (!reader.isDone) {
      final bound = Bound._decode(reader, previousTimestamp);
      if (!bound.infinity) {
        previousTimestamp = bound.timestamp;
      }
      final modeValue = _readVarint(reader);
      final mode = RangeMode.values.firstWhere(
        (value) => value.value == modeValue,
        orElse: () =>
            throw FormatException('unknown negentropy mode $modeValue'),
      );
      final payload = switch (mode) {
        RangeMode.skip => <int>[],
        RangeMode.fingerprint => reader.readBytes(16),
        RangeMode.idList => _readIdListPayload(reader),
      };
      ranges.add(NegentropyRange(bound, mode, payload));
    }
    return NegentropyMessage(version, ranges);
  }

  Uint8List encode() {
    final out = <int>[version];
    var previousTimestamp = 0;
    for (final range in ranges) {
      out.addAll(range.upper.encode(previousTimestamp));
      if (!range.upper.infinity) {
        previousTimestamp = range.upper.timestamp;
      }
      out.addAll(_writeVarint(range.mode.value));
      out.addAll(range.payload);
    }
    return Uint8List.fromList(out);
  }
}

class NegentropyRange {
  NegentropyRange(this.upper, this.mode, this.payload);

  final Bound upper;
  final RangeMode mode;
  final List<int> payload;
}

enum RangeMode {
  skip(0),
  fingerprint(1),
  idList(2);

  const RangeMode(this.value);
  final int value;
}

class Bound {
  Bound(this.timestamp, this.idPrefix, {this.infinity = false});

  factory Bound.zero() => Bound(0, const []);

  factory Bound.infinity() => Bound(0, const [], infinity: true);

  factory Bound._decode(_ByteReader reader, int previousTimestamp) {
    final encodedTimestamp = _readVarint(reader);
    final timestamp = encodedTimestamp == 0
        ? 0
        : previousTimestamp + encodedTimestamp - 1;
    final length = _readVarint(reader);
    if (length > 32) {
      throw const FormatException('bound id prefix too long');
    }
    return Bound(
      timestamp,
      reader.readBytes(length),
      infinity: encodedTimestamp == 0,
    );
  }

  final int timestamp;
  final List<int> idPrefix;
  final bool infinity;

  List<int> encode(int previousTimestamp) {
    final out = <int>[];
    out.addAll(_writeVarint(infinity ? 0 : timestamp - previousTimestamp + 1));
    out.addAll(_writeVarint(idPrefix.length));
    out.addAll(idPrefix);
    return out;
  }

  bool includesLower(RelayRecord record) {
    if (infinity) {
      return false;
    }
    return _compareRecord(record) >= 0;
  }

  bool includesUpper(RelayRecord record) {
    if (infinity) {
      return true;
    }
    return _compareRecord(record) < 0;
  }

  int _compareRecord(RelayRecord record) {
    final timeDiff = record.createdAt.compareTo(timestamp);
    if (timeDiff != 0) {
      return timeDiff;
    }
    final prefix = Uint8List(32)..setRange(0, idPrefix.length, idPrefix);
    return compareBytes(hexToBytes(record.id), prefix);
  }
}

List<int> fingerprintRecords(List<RelayRecord> records) {
  final sum = Uint8List(32);
  for (final record in records) {
    var carry = 0;
    final id = hexToBytes(record.id).reversed.toList();
    for (var i = 0; i < 32; i++) {
      final value = sum[i] + id[i] + carry;
      sum[i] = value & 0xff;
      carry = value >> 8;
    }
  }
  final input = <int>[...sum, ..._writeVarint(records.length)];
  return sha256.convert(input).bytes.take(16).toList();
}

List<int> encodeIdList(Iterable<String> ids) {
  final out = <int>[];
  final idList = ids.toList();
  out.addAll(_writeVarint(idList.length));
  for (final id in idList) {
    out.addAll(hexToBytes(id));
  }
  return out;
}

List<int> _readIdListPayload(_ByteReader reader) {
  final count = _readVarint(reader);
  final out = <int>[..._writeVarint(count)];
  for (var i = 0; i < count; i++) {
    out.addAll(reader.readBytes(32));
  }
  return out;
}

int _readVarint(_ByteReader reader) {
  var value = 0;
  while (true) {
    final byte = reader.readByte();
    value = (value << 7) | (byte & 0x7f);
    if ((byte & 0x80) == 0) {
      return value;
    }
  }
}

List<int> _writeVarint(int value) {
  if (value < 0) {
    throw ArgumentError.value(value, 'value', 'varint must be unsigned');
  }
  final parts = <int>[value & 0x7f];
  value >>= 7;
  while (value > 0) {
    parts.add(0x80 | (value & 0x7f));
    value >>= 7;
  }
  return parts.reversed.toList();
}

class _ByteReader {
  _ByteReader(this.bytes);

  final List<int> bytes;
  int offset = 0;

  bool get isDone => offset >= bytes.length;

  int readByte() {
    if (offset >= bytes.length) {
      throw const FormatException('unexpected end of negentropy message');
    }
    return bytes[offset++];
  }

  List<int> readBytes(int length) {
    if (offset + length > bytes.length) {
      throw const FormatException('unexpected end of negentropy message');
    }
    return bytes.sublist(offset, offset += length);
  }
}

class ListEquality {
  const ListEquality();

  bool equals(List<int> left, List<int> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) {
        return false;
      }
    }
    return true;
  }
}
