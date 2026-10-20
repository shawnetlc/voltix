import 'package:dio/dio.dart';

/// App-level hook into every media-server connection.
///
/// Each media-server client adds [forwarder] as its last interceptor. The
/// forwarder hands every request, response and error to [delegate] when the
/// app has set one, so the app can shape server traffic (for example, laying a
/// Voltix user's own favorites and watch state over a shared account) without
/// the server packages depending on the app. Because the delegate is looked up
/// per call, clients created before the app sets it are covered too.
class ServerDioHooks {
  ServerDioHooks._();

  /// The app's interceptor, or null to pass everything through untouched.
  static Interceptor? delegate;

  /// Added by every media-server client after its own auth interceptor.
  static final Interceptor forwarder = _ServerDioHookForwarder();
}

class _ServerDioHookForwarder extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final delegate = ServerDioHooks.delegate;
    if (delegate == null) {
      handler.next(options);
      return;
    }
    delegate.onRequest(options, handler);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    final delegate = ServerDioHooks.delegate;
    if (delegate == null) {
      handler.next(response);
      return;
    }
    delegate.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final delegate = ServerDioHooks.delegate;
    if (delegate == null) {
      handler.next(err);
      return;
    }
    delegate.onError(err, handler);
  }
}
