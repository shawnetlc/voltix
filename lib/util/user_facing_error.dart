import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// Turns any thrown object into something worth showing a viewer.
///
/// `e.toString()` on a DioException produces the library's own troubleshooting
/// essay -- several lines about RequestOptions.validateStatus, a link to the
/// MDN status code reference, and advice to "fix your request code or the
/// server code". That is written for the developer reading a stack trace, and
/// it was going straight onto the television: the search screen and the
/// full-screen retry view both rendered it verbatim.
///
/// A viewer cannot act on any of it. What they can act on is "sign in again",
/// "check your connection", or "try again shortly" -- so that is what this
/// returns, keyed off the status code and exception type that the raw text was
/// burying.
String userFacingError(Object? error) {
  if (error == null) return 'Something went wrong.';

  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status != null) return _forStatus(status);

    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'The server took too long to respond. Please try again.';
      case DioExceptionType.connectionError:
        return 'Could not reach the server. Check your connection and try '
            'again.';
      case DioExceptionType.badCertificate:
        return 'The server\'s security certificate could not be verified.';
      case DioExceptionType.cancel:
        return 'The request was cancelled.';
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        return _wrapped(error.error) ?? 'Could not reach the server. Check '
            'your connection and try again.';
    }
  }

  if (error is TimeoutException) {
    return 'That took too long to respond. Please try again.';
  }

  return _wrapped(error) ?? 'Something went wrong. Please try again.';
}

/// True when [error] means the session is no longer accepted, so a caller can
/// send the viewer back to sign-in rather than leaving them on a dead screen.
bool isAuthError(Object? error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    return status == 401 || status == 403;
  }
  return false;
}

String _forStatus(int status) {
  if (status == 401) {
    return 'Your session has expired. Please sign in again.';
  }
  if (status == 403) {
    return 'This account does not have access to that.';
  }
  if (status == 404) {
    return 'That is no longer available.';
  }
  if (status == 410) {
    return 'That recording is no longer available.';
  }
  if (status == 429) {
    return 'Too many requests. Please wait a moment and try again.';
  }
  if (status >= 500) {
    return 'The server had a problem. Please try again shortly.';
  }
  return 'The request could not be completed.';
}

/// Network faults that arrive wrapped inside another exception, which is where
/// the genuinely useful cause usually hides.
String? _wrapped(Object? inner) {
  if (inner is SocketException) {
    return 'Could not reach the server. Check your connection and try again.';
  }
  if (inner is HandshakeException) {
    return 'A secure connection to the server could not be established.';
  }
  if (inner is TimeoutException) {
    return 'That took too long to respond. Please try again.';
  }
  return null;
}
