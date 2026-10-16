import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'rpc/rpc_client.dart';

/// An error the QVAC worker reported, such as a missing model.
class QvacException implements Exception {
  const QvacException(this.message,
      {this.name, this.code, this.details = const {}});

  factory QvacException.fromJson(Map<String, dynamic> json) => QvacException(
        json['message'] as String? ?? 'Unknown QVAC error',
        name: json['name'] as String?,
        code: json['code'] as int?,
        details: json,
      );

  final String message;
  final String? name;
  final int? code;

  /// The whole error object, including fields like `stack` and `cause`.
  final Map<String, dynamic> details;

  @override
  String toString() => 'QvacException(${name ?? code ?? 'error'}): $message';
}

/// Speaks the QVAC worker's protocol: JSON requests with a `type` field.
class QvacRpc {
  QvacRpc(this._rpc);

  final RpcClient _rpc;

  /// One request, one reply.
  Future<Map<String, dynamic>> call(String type,
      [Map<String, dynamic> args = const {}]) async {
    final reply = await _rpc.request(_encode(type, args));
    return _check(jsonDecode(utf8.decode(reply)));
  }

  /// One request, many replies. The worker sends one JSON object per line.
  Stream<Map<String, dynamic>> stream(String type,
          [Map<String, dynamic> args = const {}]) =>
      _rpc
          .requestStream(_encode(type, args))
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((line) => line.trim().isNotEmpty)
          .map((line) => _check(jsonDecode(line)));

  Future<void> close() => _rpc.close();

  // An empty body would make the worker treat this as an upload stream.
  static Uint8List _encode(String type, Map<String, dynamic> args) =>
      utf8.encode(jsonEncode({...args, 'type': type}));

  static Map<String, dynamic> _check(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw FormatException(
          'QVAC worker sent something that is not a JSON object: $json');
    }
    if (json['type'] == 'error') throw QvacException.fromJson(json);
    return json;
  }
}
