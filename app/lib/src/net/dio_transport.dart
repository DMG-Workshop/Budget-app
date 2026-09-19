import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:transcript_core/transcript_core.dart';

/// transcript_core's [HttpTransport], implemented with dio.
///
/// The core packages stay dependency-free and testable; everything that needs
/// a real socket goes through here. Failure mapping is the substance of this
/// class: a LAN endpoint fails in specific ways, and "connection refused"
/// versus "host not found" versus "the platform blocked cleartext" are three
/// different remedies for the user.
class DioHttpTransport implements HttpTransport {
  DioHttpTransport({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  Future<HttpReply> send(HttpCall call) async {
    try {
      final response = await _dio.requestUri<String>(
        call.url,
        data: call.jsonBody != null
            ? jsonEncode(call.jsonBody)
            : call.bodyBytes == null
                ? null
                : Stream<List<int>>.value(call.bodyBytes!),
        options: Options(
          method: call.method,
          headers: {
            ...call.headers,
            if (call.jsonBody != null)
              Headers.contentTypeHeader: Headers.jsonContentType
            else if (call.contentType != null)
              Headers.contentTypeHeader: call.contentType,
            if (call.bodyBytes != null)
              Headers.contentLengthHeader: call.bodyBytes!.length,
          },
          responseType: ResponseType.plain,
          sendTimeout: call.timeout,
          receiveTimeout: call.timeout,
          // Provider adapters decide what a status means; dio must not throw
          // on 4xx or the adapter never sees the error body.
          validateStatus: (_) => true,
        ),
      );

      return HttpReply(
        response.statusCode ?? 0,
        response.data ?? '',
        headers: {
          for (final entry in response.headers.map.entries)
            entry.key: entry.value.join(', '),
        },
      );
    } on DioException catch (e) {
      throw TransportException(_classify(e), _describe(e));
    }
  }

  static TransportFailure _classify(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return TransportFailure.timeout;
      case DioExceptionType.badCertificate:
        return TransportFailure.tls;
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        final error = e.error;
        if (error is SocketException) {
          if (error.message.contains('Failed host lookup')) {
            return TransportFailure.unresolved;
          }
          if (error.osError?.errorCode == 111 ||
              error.message.toLowerCase().contains('refused')) {
            return TransportFailure.refused;
          }
          return TransportFailure.other;
        }
        if (error is HandshakeException) return TransportFailure.tls;
        return TransportFailure.other;
      case DioExceptionType.cancel:
      case DioExceptionType.badResponse:
        return TransportFailure.other;
    }
  }

  /// The platform's own message is preserved verbatim.
  ///
  /// On Android a cleartext block reads "Cleartext HTTP traffic to 192.168.1.50
  /// not permitted" and on iOS a missing local-network permission produces its
  /// own distinct wording. Both are the single most useful string available for
  /// diagnosing a LAN setup, and paraphrasing them loses the diagnosis.
  static String _describe(DioException e) {
    final error = e.error;
    if (error is SocketException) {
      return error.osError?.message ?? error.message;
    }
    return error?.toString() ?? e.message ?? 'The request failed.';
  }
}
