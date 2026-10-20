/// Whether [baseUrl] points at Lumistream, directly or through the Voltix
/// server proxy (which forwards every path to Lumistream).
///
/// Used to keep app-specific traffic (Moonfin/Voltix plugin endpoints and
/// similar) away from Lumistream, which rejects third-party clients.
bool isLumistreamBackedUrl(String baseUrl) {
  final host = Uri.tryParse(baseUrl)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  return host == 'lumistream.cc' ||
      host.endsWith('.lumistream.cc') ||
      host == 'voltixstudio.com' ||
      host.endsWith('.voltixstudio.com') ||
      host == 'voltix.media' ||
      host.endsWith('.voltix.media');
}
