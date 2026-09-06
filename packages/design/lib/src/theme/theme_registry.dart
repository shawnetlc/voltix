import 'theme_spec.dart';
import 'themes/voltix_theme_spec.dart';
import 'themes/neon_pulse_theme_spec.dart';
import 'themes/eightbit_hero_theme_spec.dart';
import 'themes/glass_theme_spec.dart';

class ThemeRegistry {
  const ThemeRegistry._();

  static const String voltixId = 'voltix';
  static const String neonPulseId = 'neon_pulse';
  static const String glassId = 'glass';
  static const String eightbitHeroId = '8bit_hero';

  /// IDs that are bundled with the app and cannot be removed.
  static const Set<String> builtInIds = {voltixId, neonPulseId, glassId, eightbitHeroId};

  // `glass` was pulled once, briefly, when the very first version of the
  // glass rendering path pinned the GPU on Android TV and mid-range phones
  // (an unthrottled 16s backdrop animation plus a flat sigma-14 blur on
  // every surface). That work is what GlassCapability/GlassSettings in
  // lib/util/idiom/glass_capability.dart now exist to do properly: the
  // backdrop no longer animates, TV and web default to a zero-blur "sheen"
  // tier instead of a real BackdropFilter, real blur is capped and further
  // throttled by an adaptive GPU-pressure scope, and Glass Quality (Settings
  // > Appearance) lets a user drop to the cheap tier by hand. Re-registering
  // it here is what actually turns it back into a selectable theme again --
  // see glass_theme_spec.dart for the spec itself.
  static const Map<String, ThemeSpec> _builtIns = {
    voltixId: voltixThemeSpec,
    neonPulseId: neonPulseThemeSpec,
    glassId: glassThemeSpec,
    eightbitHeroId: eightbitHeroThemeSpec,
  };

  static final Map<String, ThemeSpec> _custom = {};

  /// Themes the user saved from the Theme Store. Kept separate from [_custom]
  /// so server theme syncs (which call [replaceCustomThemes]) never clear them.
  static final Map<String, ThemeSpec> _store = {};

  /// All themes (built-in + plugin-supplied + store-saved) keyed by id.
  /// Plugin/server themes take precedence over store themes on id clash.
  static Map<String, ThemeSpec> get availableThemes => {
        ..._builtIns,
        ..._store,
        ..._custom,
      };

  static ThemeSpec _active = voltixThemeSpec;
  static ThemeSpec get active => _active;

  static void setActiveById(String id) {
    _active = availableThemes[id] ?? voltixThemeSpec;
  }

  /// Neon Pulse pairs a display face with saturated accents; regular-weight
  /// text reads as washed out against it, so navigation and card labels use a
  /// heavier weight when it is active. Exposed here so call sites share one
  /// definition instead of each re-comparing ids.
  static bool get isNeonPulseActive => _active.id == neonPulseId;

  static ThemeSpec resolveById(String id) {
    return availableThemes[id] ?? voltixThemeSpec;
  }

  /// Register or replace a plugin-supplied theme. Built-in IDs are reserved
  /// and will be rejected to prevent shadowing.
  static void registerCustom(ThemeSpec spec) {
    if (builtInIds.contains(spec.id)) {
      throw ArgumentError(
        'Cannot register custom theme with reserved id "${spec.id}".',
      );
    }
    _custom[spec.id] = spec;
  }

  /// Replace the entire set of custom themes (e.g. after fetching from the
  /// admin plugin). Built-ins are untouched.
  static void replaceCustomThemes(Iterable<ThemeSpec> specs) {
    _custom
      ..clear()
      ..addEntries(specs
          .where((s) => !builtInIds.contains(s.id))
          .map((s) => MapEntry(s.id, s)));
  }

  static void removeCustom(String id) {
    _custom.remove(id);
  }

  static List<ThemeSpec> get customThemes => List.unmodifiable(_custom.values);

  /// Register a theme saved from the Theme Store. Built-in IDs are rejected.
  static void registerStoreTheme(ThemeSpec spec) {
    if (builtInIds.contains(spec.id)) {
      throw ArgumentError(
        'Cannot register store theme with reserved id "${spec.id}".',
      );
    }
    _store[spec.id] = spec;
  }

  static void removeStoreTheme(String id) {
    _store.remove(id);
  }

  static List<ThemeSpec> get storeThemes => List.unmodifiable(_store.values);
}
