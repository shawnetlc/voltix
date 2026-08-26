import 'theme_spec.dart';
import 'themes/voltix_theme_spec.dart';
import 'themes/neon_pulse_theme_spec.dart';
import 'themes/eightbit_hero_theme_spec.dart';

class ThemeRegistry {
  const ThemeRegistry._();

  static const String voltixId = 'voltix';
  static const String neonPulseId = 'neon_pulse';
  static const String glassId = 'glass';
  static const String eightbitHeroId = '8bit_hero';

  /// IDs that are bundled with the app and cannot be removed.
  static const Set<String> builtInIds = {voltixId, neonPulseId, glassId, eightbitHeroId};

  // `glass` is deliberately ABSENT here, so resolveById('glass') falls through
  // to the Voltix fallback below and Glass does not appear in Appearance.
  //
  // It was registered briefly and had to be withdrawn. Registering it was the
  // first time the glass rendering path had ever actually run, and it is far
  // too expensive to ship as-is:
  //
  //   - app.dart renders GlassBackdrop in the app shell whenever isGlass is
  //     true. That widget drives an AnimationController on repeat(reverse:true)
  //     with a 16s period, so the backdrop is invalidated every single frame
  //     and never settles.
  //   - GlassSurface applies ImageFilter.blur(sigma 14) per surface - the
  //     sidebar plus every card. Each BackdropFilter forces a saveLayer of the
  //     region behind it, so a list of cards stacks many of them.
  //
  // Together those pinned the GPU on Android TV and mid-range phones: the app
  // appeared to freeze on the splash and content screens never painted.
  //
  // Leaving it unregistered also self-heals installs that already persisted
  // visualTheme=glass - resolveById returns the Voltix spec, isGlass goes
  // false, and the app recovers on next launch with no data clearing.
  //
  // BEFORE RE-ENABLING: profile it. GlassBackdrop needs to stop animating (or
  // animate far more cheaply), GlassSurface needs a much smaller sigma or a
  // non-BackdropFilter approach, and glass should probably be refused on TV
  // outright. glass_theme_spec.dart is kept for that work.
  static const Map<String, ThemeSpec> _builtIns = {
    voltixId: voltixThemeSpec,
    neonPulseId: neonPulseThemeSpec,
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
