import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class PayFastCheckoutScreen extends StatefulWidget {
  final String checkoutUrl;
  final String packageName;
  final String amount;

  const PayFastCheckoutScreen({
    super.key,
    required this.checkoutUrl,
    required this.packageName,
    required this.amount,
  });

  @override
  State<PayFastCheckoutScreen> createState() => _PayFastCheckoutScreenState();
}

class _PayFastCheckoutScreenState extends State<PayFastCheckoutScreen> {
  bool _isLoading = true;
  bool _hasNavigated = false;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        final shouldPop = await _showCancelDialog();
        if (shouldPop == true && mounted) {
          nav.pop(false);
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0a0a0a),
        appBar: AppBar(
          backgroundColor: const Color(0xFF111528),
          title: Text('${widget.packageName} - ${widget.amount}'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () async {
              final nav = Navigator.of(context);
              final shouldPop = await _showCancelDialog();
              if (shouldPop == true && mounted) {
                nav.pop(false);
              }
            },
          ),
        ),
        body: Stack(
          children: [
            InAppWebView(
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                transparentBackground: true,
              ),
              initialUrlRequest: URLRequest(url: WebUri.uri(Uri.parse(widget.checkoutUrl))),
              onLoadStart: (controller, url) {
                setState(() => _isLoading = true);
                _checkUrl(url?.toString());
              },
              onLoadStop: (controller, url) {
                setState(() => _isLoading = false);
                _checkUrl(url?.toString());
              },
              onUpdateVisitedHistory: (controller, url, androidIsReload) {
                _checkUrl(url?.toString());
              },
            ),
            if (_isLoading)
              const Center(
                child: CircularProgressIndicator(color: Colors.amberAccent),
              ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _showCancelDialog() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF141A26),
        title: const Text('Cancel payment?', style: TextStyle(color: Colors.white)),
        content: const Text('Are you sure you want to cancel the payment?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  void _checkUrl(String? urlString) {
    if (urlString == null || _hasNavigated) return;
    final url = urlString.toLowerCase();
    if (url.contains('success') || url.contains('thank') || url.contains('complete') || url.contains('return')) {
      _hasNavigated = true;
      Navigator.pop(context, true);
    } else if (url.contains('cancel')) {
      _hasNavigated = true;
      Navigator.pop(context, false);
    }
  }
}
