import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:voltix/util/voltix_library_branding.dart';

void main() {
  group('VoltixLibraryBranding Tests', () {
    final testCases = [
      // 4K Server / 4K Category tests
      {'raw': '4K Movies', 'server': '4K Server', 'expectedName': 'Movies', 'expectedKey': '/categories/movies%204k.png'},
      {'raw': 'Movies (4K)', 'server': 'Lumistream', 'expectedName': 'Movies', 'expectedKey': '/categories/movies%204k.png'},
      {'raw': 'Movies', 'server': 'Voltix 4K', 'expectedName': 'Movies', 'expectedKey': '/categories/movies%204k.png'},
      {'raw': '4K Series', 'server': '4K Server', 'expectedName': 'Series', 'expectedKey': '/categories/series%204k.png'},
      {'raw': 'Shows (4K)', 'server': 'Lumistream', 'expectedName': 'Series', 'expectedKey': '/categories/series%204k.png'},
      {'raw': 'Shows', 'server': 'Voltix 4K', 'expectedName': 'Series', 'expectedKey': '/categories/series%204k.png'},
      {'raw': '4K Vault', 'server': '4K Server', 'expectedName': 'Vault', 'expectedKey': '/categories/vault%204k.png'},
      {'raw': 'Vault (4K)', 'server': 'Lumistream', 'expectedName': 'Vault', 'expectedKey': '/categories/vault%204k.png'},
      {'raw': 'Vault', 'server': 'Voltix 4K', 'expectedName': 'Vault', 'expectedKey': '/categories/vault%204k.png'},

      // Tiered category tests (Primary / Extra / Base)
      {'raw': 'Movies', 'server': 'Primary Server', 'expectedName': 'Movies', 'expectedKey': '/categories/movies%20primary.png'},
      {'raw': 'Movies', 'server': 'Extra Server', 'expectedName': 'Movies', 'expectedKey': '/categories/movies%20extra.png'},
      {'raw': 'Movies', 'server': 'Base Server', 'expectedName': 'Movies', 'expectedKey': '/categories/movies.png'},
      {'raw': 'Series', 'server': 'Primary Server', 'expectedName': 'Series', 'expectedKey': '/categories/series%20primary.png'},
      {'raw': 'Series', 'server': 'Extra Server', 'expectedName': 'Series', 'expectedKey': '/categories/series%20extra.png'},
      {'raw': 'Series', 'server': 'Base Server', 'expectedName': 'Series', 'expectedKey': '/categories/series.png'},
      {'raw': 'Vault', 'server': 'Primary Server', 'expectedName': 'Vault', 'expectedKey': '/categories/vault%20primary.png'},
      {'raw': 'Vault', 'server': 'Extra Server', 'expectedName': 'Vault', 'expectedKey': '/categories/vault%20extra.png'},
      {'raw': 'Vault', 'server': 'Base Server', 'expectedName': 'Vault', 'expectedKey': '/categories/vault.png'},

      // Special category tests
      {'raw': 'Anime Movies', 'server': null, 'expectedName': 'Anime Movies', 'expectedKey': '/categories/anime%20movies.png'},
      {'raw': 'Anime Series', 'server': null, 'expectedName': 'Anime Series', 'expectedKey': '/categories/anime%20series.png'},
      {'raw': 'Movie Requests', 'server': null, 'expectedName': 'Movie Requests', 'expectedKey': '/categories/movie%20requests.png'},
      {'raw': 'Series Requests', 'server': null, 'expectedName': 'Series Requests', 'expectedKey': '/categories/series%20requests.png'},
      {'raw': 'Documentaries', 'server': null, 'expectedName': 'Documentaries', 'expectedKey': '/categories/documentaries.png'},
      {'raw': 'Foreign Movies', 'server': null, 'expectedName': 'Foreign Movies', 'expectedKey': '/categories/foreign%20movies.png'},
      {'raw': 'Foreign Series', 'server': null, 'expectedName': 'Foreign Series', 'expectedKey': '/categories/foreign%20series.png'},
      {'raw': 'Kids Movies', 'server': null, 'expectedName': 'Kids Movies', 'expectedKey': '/categories/kids%20movies.png'},
      {'raw': 'Kids Series', 'server': null, 'expectedName': 'Kids Series', 'expectedKey': '/categories/kids%20series.png'},
      {'raw': 'Stand-up Comedy', 'server': null, 'expectedName': 'Stand-up Comedy', 'expectedKey': '/categories/stand-up%20comedy.png'},
      {'raw': 'Reality Shows', 'server': null, 'expectedName': 'Reality Shows', 'expectedKey': '/categories/reality%20shows.png'},
      {'raw': 'Sports', 'server': null, 'expectedName': 'Sports', 'expectedKey': '/categories/sports.png'},
      {'raw': 'Sport Pay-per-View', 'server': null, 'expectedName': 'Sport Pay-per-View', 'expectedKey': '/categories/sport%20pay-per-view.png'},
    ];

    for (final tc in testCases) {
      final raw = tc['raw']!;
      final server = tc['server'];
      final expectedName = tc['expectedName']!;
      final expectedPath = tc['expectedKey']!;

      test('Branding for $raw on server $server', () {
        final branding = voltixLibraryBranding(raw, server);
        expect(branding, isNotNull, reason: 'Branding should not be null for $raw');
        expect(branding!.displayName, equals(expectedName));
        expect(branding.imageUrl, contains(expectedPath));
      });
    }

    test('HTTP Status check for all category images on server', () async {
      final categoryPaths = [
        '/categories/movies.png',
        '/categories/movies%20primary.png',
        '/categories/movies%20extra.png',
        '/categories/movies%204k.png',
        '/categories/series.png',
        '/categories/series%20primary.png',
        '/categories/series%20extra.png',
        '/categories/series%204k.png',
        '/categories/vault.png',
        '/categories/vault%20primary.png',
        '/categories/vault%20extra.png',
        '/categories/vault%204k.png',
        '/categories/anime%20movies.png',
        '/categories/anime%20movies%20primary.png',
        '/categories/anime%20movies%20extra.png',
        '/categories/anime%20series.png',
        '/categories/anime%20series%20primary.png',
        '/categories/anime%20series%20extra.png',
        '/categories/movie%20requests.png',
        '/categories/series%20requests.png',
        '/categories/documentaries.png',
        '/categories/foreign%20movies.png',
        '/categories/foreign%20series.png',
        '/categories/kids%20movies.png',
        '/categories/kids%20series.png',
        '/categories/stand-up%20comedy.png',
        '/categories/reality%20shows.png',
        '/categories/sports.png',
        '/categories/sport%20pay-per-view.png',
      ];

      for (final path in categoryPaths) {
        final url = Uri.parse('https://www.voltixstudio.com$path');
        final res = await http.head(url);
        expect(
          res.statusCode,
          equals(200),
          reason: 'Category image URL $url returned HTTP ${res.statusCode}',
        );
      }
    });
  });
}
