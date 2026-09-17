import 'dart:async';
import '../data/models/aggregated_item.dart';
import '../data/models/series_track_preference.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:server_core/server_core.dart' hide ImageType;

import '../playback/audio_capability_profile.dart';
import '../util/idiom/app_ui_idiom.dart';
import '../util/platform_detection.dart';
import 'home_section_config.dart';
import 'preference_constants.dart';

class UserPreferences extends ChangeNotifier {
  static const _lastServerIdPreferenceKey = 'pref_last_server_id';
  static const _lastUserIdPreferenceKey = 'pref_last_user_id';

  static const mediaBarModeVoltix = 'voltix';
  static const mediaBarModeMakd = 'makd';
  static const mediaBarModeBookshelf = 'bookshelf';
  static const mediaBarModeGallery = 'gallery';
  static const mediaBarModeBanner = 'banner';
  static const mediaBarModeAya = 'aya';
  static const mediaBarModeOff = 'off';
  static const mediaBarModeValues = <String>{
    mediaBarModeVoltix,
    mediaBarModeMakd,
    mediaBarModeBookshelf,
    mediaBarModeGallery,
    mediaBarModeBanner,
    mediaBarModeAya,
    mediaBarModeOff,
  };

  final PreferenceStore _store;

  UserPreferences(this._store) {
    _migrateOverlayPreferences();
    _migrateDefaultAudioLanguagePreference();
    _enforceMediaQueuingAlwaysOn();
  }

  void _migrateOverlayPreferences() {
    if (!_store.containsKey(navbarOpacity.key)) {
      _store.set(navbarOpacity, _store.get(mediaBarOverlayOpacity));
    }
    if (!_store.containsKey(navbarColor.key)) {
      _store.set(navbarColor, _store.get(mediaBarOverlayColor));
    }
  }

  void _migrateDefaultAudioLanguagePreference() {
    if (!_store.containsKey(defaultAudioLanguage.key)) {
      return;
    }
    final current = _store.get(defaultAudioLanguage).trim();
    if (current.isEmpty) {
      _store.set(defaultAudioLanguage, 'auto');
    }
  }

  void _enforceMediaQueuingAlwaysOn() {
    if (_store.get(mediaQueuingEnabled) != true) {
      _store.set(mediaQueuingEnabled, true);
    }
  }

  /// Safely reads any preference value regardless of its stored type.
  /// SharedPreferences typed getters (getString, getInt, …) throw a
  /// TypeError when the stored runtime type doesn't match (e.g. getString
  /// on an int value).  This helper uses the untyped [get] accessor which
  /// returns Object? without any cast.
  Object? _safeGetRaw(String key) {
    try {
      // PreferenceStore wraps SharedPreferences. Its typed accessors
      // delegate to SharedPreferences' typed methods which throw on type
      // mismatch, so we try each one inside a guard.
      try { final v = _store.getString(key); if (v != null) return v; } catch (_) {}
      try { final v = _store.getInt(key);    if (v != null) return v; } catch (_) {}
      try { final v = _store.getBool(key);   if (v != null) return v; } catch (_) {}
      try { final v = _store.getDouble(key); if (v != null) return v; } catch (_) {}
      try { final v = _store.getStringList(key); if (v != null) return v; } catch (_) {}
    } catch (_) {}
    return null;
  }

  /// Exports all user preference values to a JSON-serializable Map.
  ///
  /// This captures every user-facing setting so a restore fully replicates the
  /// user's configuration. Device-specific keys (window geometry, one-time
  /// migration flags, audio probe seeds) are intentionally excluded.
  Map<String, dynamic> exportSettingsJson() {
    final Map<String, dynamic> data = {};

    // ── All keys that should be synced ──────────────────────────────────
    final allSyncKeys = <String>{
      // ── Scoped preference keys (profiles, UI, home rows, etc.) ──
      ..._scopedPreferenceKeys,

      // ── Playback ──
      'pref_max_bitrate',
      'pref_max_video_resolution',
      'pref_enable_tv_queuing',
      'external_player',
      'external_player_component',
      'refresh_rate_switching_behavior',
      'auto_hdr_switching_behavior',
      'exoplayer_prefer_ffmpeg',
      'media3_skip_silence',
      'media3_tunneling_disabled',
      'media3_map_dolby_vision_profile7_to_hevc',
      'media3_allow_external_audio_effects',
      'tunneling_fallback_disabled',
      'player_zoom_mode',
      'desktop_scroll_wheel_action',
      'trick_play_enabled',
      'pgs_enabled',
      'ass_enabled',
      'video_start_delay',
      'hardware_decoding',
      'playback_engine_preference',
      'dolby_vision_fallback_behavior',
      'dolby_vision_profile7_direct_play_behavior',
      'custom_mpv_conf_enabled',
      'custom_mpv_conf_path',
      'custom_mpv_conf_unsafe_advanced',

      // ── Audio ──
      'audio_output_mode',
      'audio_fallback_codec',
      'pref_audio_passthrough_preset',
      'pref_max_audio_channels',
      'pref_passthrough_ac3',
      'pref_passthrough_eac3',
      'pref_passthrough_eac3_joc',
      'pref_passthrough_dts_core',
      'pref_passthrough_dts_hd',
      'pref_passthrough_dts_x',
      'pref_passthrough_truehd',
      'pref_passthrough_truehd_atmos',
      'audio_night_mode',
      'pref_appletv_hybrid_atmos',
      'pref_appletv_audio_passthrough',

      // ── OSD / Player Controls ──
      'skipBackLength',
      'skipForwardLength',
      'unpauseRewindDuration',
      'showDescriptionOnPause',
      'osdLockEnabled',

      // ── Screensaver ──
      'pref_screensaver_enabled',
      'pref_screensaver_mode',
      'pref_screensaver_timeout',
      'pref_screensaver_dimming',
      'pref_screensaver_clock_mode',
      'pref_screensaver_max_age_rating',
      'pref_screensaver_require_rating',

      // ── SyncPlay ──
      'pref_syncplay_enabled',
      'syncplay_enable_sync_correction',
      'syncplay_use_speed_to_sync',
      'syncplay_use_skip_to_sync',
      'syncplay_min_delay_speed_to_sync',
      'syncplay_max_delay_speed_to_sync',
      'syncplay_speed_to_sync_duration',
      'syncplay_min_delay_skip_to_sync',
      'syncplay_extra_time_offset',
      'syncplay_advanced_correction_enabled',

      // ── Live TV ──
      'voltix_live_tv_enabled',
      'pref_live_direct',
      'pref_live_tv_epg_source',
      'pref_live_tv_channel_columns',

      // ── General / App ──
      'voltix_jellyfin_enabled',
      'confirm_exit',
      'update_notifications_enabled',
      'pref_diagnostic_logging_enabled',
      'pref_crash_reports_enabled',

      // ── Login / Auto-login ──
      'pref_auto_login_behavior',
      'pref_auto_login_server_id',
      'pref_auto_login_user_id',
      'pref_always_authenticate',
      'user_pin_enabled',
      'user_pin_hash',

      // ── Parental Controls ──
      'blocked_ratings',

      // ── Seerr / Jellyseerr ──
      'seerr_enabled',
      'jellyseerrBlockNsfw',

      // ── Downloads ──
      'download_default_quality',
      'download_wifi_only',
      'download_storage_limit_mb',
      'download_concurrent_count',
      'download_custom_path',

      // ── Additional UI ──
      'all_genres_image_type',
      'favorites_type_filter',
      'defaultFavoritesFilter',
      'pref_display_playlists_rows',
      'pref_display_audio_rows',
      'pref_display_seerr_rows',
      'pref_playlists_row_sort_by',
      'pref_audio_rows_sort_by',
      'home_row_info_overlay',
      'pref_favorites_view_style',
      'pref_admin_drawer_order',
    };

    // ── Resolve the active profile scope suffix ──────────────────────
    // Settings are exported under the BASE key regardless of whether the
    // value was stored in a scoped slot (key_serverId_userId) or the
    // global slot.  This makes personalization app-level, not server-level,
    // so IPTV-only users, multi-server users, and reinstalls all work.
    final scopeSuffix = _activeProfileScopeSuffix();

    for (final key in allSyncKeys) {
      // For scoped preference keys, prefer the scoped value (what the user
      // actually sees) but fall back to the base key.
      Object? value;
      if (scopeSuffix != null && _scopedPreferenceKeys.contains(key)) {
        final scopedKey = '${key}_$scopeSuffix';
        value = _safeGetRaw(scopedKey) ?? _safeGetRaw(key);
      } else {
        value = _safeGetRaw(key);
      }

      if (value != null) {
        data[key] = value;
      }
    }

    // Capture dynamic homeRowImageType_* keys.  Strip the scope suffix so
    // they import cleanly on any server / IPTV-only device.
    try {
      final allStoreKeys = _store.getKeys();
      for (final storeKey in allStoreKeys) {
        if (storeKey.startsWith('homeRowImageType_')) {
          // Derive the base key by removing the scope suffix if present.
          String baseKey = storeKey;
          if (scopeSuffix != null && storeKey.endsWith('_$scopeSuffix')) {
            baseKey = storeKey.substring(
              0, storeKey.length - scopeSuffix.length - 1,
            );
          }
          if (!data.containsKey(baseKey)) {
            final val = _safeGetRaw(storeKey);
            if (val != null) {
              data[baseKey] = val;
            }
          }
        }
      }
    } catch (_) {}

    return data;
  }

  /// Returns a lightweight fingerprint string of the current settings state.
  /// Used for change detection — compare before/after to decide if sync is needed.
  String settingsFingerprint() {
    final data = exportSettingsJson();
    // Sort keys for deterministic output, then hash the JSON string.
    final sorted = Map.fromEntries(
      data.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return jsonEncode(sorted).hashCode.toRadixString(36);
  }

  /// Imports settings from [data] into local storage and notifies UI listeners.
  ///
  /// JSON decoders may return numeric values as [num] (not strictly [int] or
  /// [double]), so we handle all three. After writing every key we flush
  /// pending writes and call [notifyListeners] so the UI rebuilds immediately
  /// with the restored cloud values.
  Future<void> importSettingsJson(Map<String, dynamic> data) async {
    for (final entry in data.entries) {
      final key = entry.key;
      final val = entry.value;
      if (val is String) {
        await _store.setString(key, val);
      } else if (val is bool) {
        await _store.setBool(key, val);
      } else if (val is int) {
        await _store.setInt(key, val);
      } else if (val is double) {
        // If the double is actually a whole number (e.g. 50.0 from JSON),
        // store it as int so typed getters (getInt) don't throw.
        if (val == val.truncateToDouble() && val.abs() < 0x7FFFFFFFFFFFFFFF) {
          await _store.setInt(key, val.toInt());
        } else {
          await _store.setDouble(key, val);
        }
      } else if (val is num) {
        // Catch-all for [num] that isn't caught above.
        if (val is int || val == val.toDouble().truncateToDouble()) {
          await _store.setInt(key, val.toInt());
        } else {
          await _store.setDouble(key, val.toDouble());
        }
      } else if (val is List) {
        // StringList preferences (e.g. mediaBarLibraryIds stored as list).
        final stringList = val.whereType<String>().toList();
        await _store.setStringList(key, stringList);
      }
    }
    // Flush any async SharedPreferences writes before notifying the UI.
    await _store.flushPendingWrites();
    notifyListeners();
  }

  /// Initialize local language preferences from the current server's
  /// [UserConfiguration].  This will not overwrite explicitly set preferences,
  ///  only keys that are missing.
  ///
  /// - Audio: if the local pref is still default ('auto') and never
  ///   explicitly stored), replace it with the server's AudioLanguagePreference.
  /// - Subtitles: if the local pref has never been explicitly stored (empty
  ///   default), replace it with the server's SubtitleLanguagePreference.
  ///
  void initLanguagePrefs(UserConfiguration config) {
    // defaultAudioLanguage
    if (!_store.containsKey(defaultAudioLanguage.key)) {
      final serverAudio = config.audioLanguagePreference;
      if (serverAudio != null && serverAudio.isNotEmpty) {
        _store.set(defaultAudioLanguage, serverAudio.toLowerCase());
      }
    }
    // defaultSubtitleLanguage
    if (!_store.containsKey(defaultSubtitleLanguage.key)) {
      final serverSub = config.subtitleLanguagePreference;
      if (serverSub != null && serverSub.isNotEmpty) {
        _store.set(defaultSubtitleLanguage, serverSub.toLowerCase());
      }
    }
  }

  String? _activeProfileScopeSuffix() {
    final serverId = (_store.getString(_lastServerIdPreferenceKey) ?? '')
        .trim();
    final userId = (_store.getString(_lastUserIdPreferenceKey) ?? '').trim();
    if (serverId.isEmpty || userId.isEmpty) {
      return null;
    }
    return '${serverId}_$userId';
  }

  static final Set<String> _scopedPreferenceKeys = {
    // External Home Rows: which charts a user turns on is per server/user.
    'imdb_top_250_movies_enabled',
    'imdb_top_250_tv_shows_enabled',
    'imdb_most_popular_movies_enabled',
    'imdb_most_popular_tv_shows_enabled',
    'imdb_lowest_rated_movies_enabled',
    'imdb_top_english_movies_enabled',
    'enable_radarr_calendar',
    'enable_sonarr_calendar',
    'merge_radarr_sonarr_calendars',
    'pref_enable_cinema_mode',
    'pref_resume_preroll',
    'media_segment_actions',
    'pref_autoplay_next_episode',
    'next_up_behavior',
    'next_up_timeout',
    'replace_skip_outro_with_next_up',
    'enable_still_watching',
    'pref_language_override',
    'pref_media_segment_countdown',
    'pref_desktop_ui_scale',
    'poster_size_library',
    'poster_size_playlist',
    'pref_home_rows_fullscreen',
    'pref_show_seerr_button',
    'pref_show_media_details_on_library_page',
    'pref_use_detailed_sub_headings',
    'pref_show_clock',
    'pref_use_24_hour_clock',
    'pref_clock_behavior',
    'pref_prefer_system_ime_keyboard',
    'pref_audio_language',
    'pref_subtitle_language',
    'subtitles_background_color',
    'subtitles_text_weight',
    'subtitles_text_color',
    'subtitles_text_stroke_color',
    'subtitles_text_size',
    'subtitles_offset_position',
    'subtitles_default_to_none',
    'subtitles_use_embedded_styles',
    'subtitles_use_embedded_font_sizes',
    'prefer_sdh_subtitles',
    'app_theme_id',
    'pref_custom_theme_id',
    'pref_navbar_position',
    'focus_color',
    'pref_watched_indicator_behavior',
    'pref_card_focus_expansion',
    'pref_home_rows_style',
    'poster_size',
    'pref_display_favorites_rows',
    'pref_display_collections_rows',
    'pref_display_genres_rows',
    'pref_favorites_row_sort_by',
    'pref_collections_row_sort_by',
    'pref_genres_row_sort_by',
    'pref_genres_row_item_filter',
    'pref_show_shuffle_button',
    'pref_show_genres_button',
    'pref_show_favorites_button',
    'pref_show_syncplay_button',
    'pref_show_remote_control_button',
    'pref_remote_control_show_dpad',
    'pref_show_libraries_in_toolbar',
    'pref_shuffle_content_type',
    'pref_merge_continue_watching_next_up',
    'enable_multi_server_libraries',
    'enable_multi_server_search',
    'pref_hide_shared_server_continue_watching',
    'pref_hide_cw_extra_server',
    'pref_hide_cw_4k_server',
    'enable_folder_view',
    'seasonal_surprise',
    'mediaBarEnabled',
    'mediaBarMode',
    'mediaBarContentType',
    'mediaBarItemCount',
    'mediaBarOverlayOpacity',
    'mediaBarOverlayColor',
    'navbarOpacity',
    'navbarColor',
    'mediaBarAutoAdvance',
    'mediaBarIntervalMs',
    'mediaBarTrailerPreview',
    'mediaBarTrailerAudio',
    'episodePreviewEnabled',
    'previewAudioEnabled',
    'mediaBarLibraryIds',
    'mediaBarCollectionIds',
    'mediaBarExcludedGenres',
    'themeMusicEnabled',
    'themeMusicVolume',
    'themeMusicOnHomeRows',
    'homeRowsUniversalOverride',
    'homeRowsUniversalImageType',
    'pref_enable_series_thumbnails',
    'pref_show_backdrop',
    'detailsBackgroundBlurAmount',
    'browsingBackgroundBlurAmount',
    'enableAdditionalRatings',
    'mdblistApiKey',
    'showRatingLabels',
    'showRatingBadges',
    'enableEpisodeRatings',
    'tmdbApiKey',
    'seerrEnabled',
    'jellyseerrBlockNsfw',
    'enabledRatings',
    'home_sections_config',
    'pref_audio_display_latest',
    'pref_audio_display_last_played',
    'pref_audio_display_favorites',
    'pref_audio_display_playlists',
    'pref_audio_display_album_artists',
    'pref_audio_display_artists',
    'pref_audio_display_albums',
    'pref_audio_sort_option',
    'pref_recommendation_system_source',
    'pref_recommendations_apply_parental_rating_cap',
    'pref_display_since_you_watched_rows',
    'pref_since_you_watched_source',
    'pref_since_you_watched_source_type',
    'pref_since_you_watched_source_item',
    'pref_since_you_watched_num_rows',
    'pref_since_you_watched_include_watched',
    // Ported from Moonfin Core 2.4.0 alongside the definition-only
    // preferences at the bottom of this class. Upstream scopes these
    // per server and user, so the keys are registered here too.
    'pref_modern_home_rows_padding',
    'pref_classic_home_rows_padding',
    'pref_display_rewatch_row',
    'pref_rewatch_sort_by',
    'pref_rewatch_include_movies',
    'pref_rewatch_include_shows',
    'pref_rewatch_include_collections',
    'pref_collections_row_show_episodes',
    'pref_playlists_row_show_episodes',
    'pref_group_items_into_collections',
    'pref_merge_recent_rows_by_type',
    'pref_next_up_max_days',
    'pref_detail_screen_style',
    'pref_detail_expanded_tabs',
    'pref_detail_show_technical_details',
    'pref_glass_quality',
    'pref_oled_mode',
    'pref_epg_mobile_view',
    'live_tv_channel_sort_by',
    'pref_navbar_always_expanded',
    'pref_hide_backdrops_in_libraries',
    'pref_enable_cinema_mode_episodes',
    'playback_time_above_left',
    'playback_time_above_center',
    'playback_time_above_right',
    'playback_time_below_left',
    'playback_time_below_center',
    'playback_time_below_right',
    'music_playback_time_display',
    'pref_fallback_audio_language',
    'pref_prefer_default_audio_track',
    'pref_prefer_audio_description',
    'pref_subtitle_mode',
    'pref_fallback_subtitle_language',
    'pref_media_segment_auto_hide',
    'pref_resume_last_queue_on_play',
    'mediaBarTrailerCaptions',
    'themeMusicLoop',
    'download_report_as_activity',
    'pref_person_page_sort_option',
    'pref_person_page_group_items',
    'hidden_continue_watching_items',
    'hidden_next_up_series',
    'pref_interface_style',
    'detailButtonOrderTv',
    'detailButtonOrderMobile',
    'detailButtonOrderDesktop',
    'osdButtonOrderTv',
    'osdButtonOrderMobile',
    'osdButtonOrderDesktop',
    'hiddenDetailButtonsTv',
    'hiddenDetailButtonsMobile',
    'hiddenDetailButtonsDesktop',
    'hiddenOsdButtonsTv',
    'hiddenOsdButtonsMobile',
    'hiddenOsdButtonsDesktop',
  };

  bool _isScopedPreference<T>(Preference<T> pref) {
    return _scopedPreferenceKeys.contains(pref.key) ||
        pref.key.startsWith('homeRowImageType_');
  }

  Preference<T> getEffectivePreference<T>(Preference<T> pref) {
    if (_isScopedPreference(pref)) {
      final scoped = _scopedPreference(pref);
      if (scoped != null) {
        return scoped;
      }
    }
    return pref;
  }

  Preference<T>? _scopedPreference<T>(Preference<T> pref) {
    final scopeSuffix = _activeProfileScopeSuffix();
    if (scopeSuffix == null) {
      return null;
    }
    return pref.withKey('${pref.key}_$scopeSuffix');
  }

  T get<T>(Preference<T> pref) {
    if (_isScopedPreference(pref)) {
      final scoped = _scopedPreference(pref);
      if (scoped != null && _store.containsKey(scoped.key)) {
        return _store.get(scoped);
      }
      return _store.get(pref);
    }

    return _store.get(pref);
  }

  Future<void> set<T>(Preference<T> pref, T value) async {
    if (_isScopedPreference(pref)) {
      final scoped = _scopedPreference(pref);
      if (scoped != null) {
        await _store.set(scoped, value);
      } else {
        await _store.set(pref, value);
      }
      notifyListeners();
      return;
    }

    await _store.set(pref, value);
    notifyListeners();
  }

  /// Clears any stored value for [pref] so subsequent reads fall back to the
  /// default / capability-derived value. Used to return a tri-state passthrough
  /// toggle to its "Auto (follow detection)" state.
  Future<void> removePreference<T>(Preference<T> pref) async {
    if (_isScopedPreference(pref)) {
      final scoped = _scopedPreference(pref);
      if (scoped != null) {
        await _store.delete(scoped);
      }
    }
    await _store.delete(pref);
    notifyListeners();
  }

  Future<void> flushPendingWrites() => _store.flushPendingWrites();

  bool containsPreferenceKey(String key) => _store.containsKey(key);

  bool containsPreference<T>(Preference<T> pref) {
    if (_isScopedPreference(pref)) {
      final scoped = _scopedPreference(pref);
      return (scoped != null && _store.containsKey(scoped.key)) ||
          _store.containsKey(pref.key);
    }

    return _store.containsKey(pref.key);
  }

  AudioOutputMode resolveAudioOutputMode() => get(audioOutputMode);

  AudioFallbackCodec resolveAudioFallbackCodec() => get(audioFallbackCodec);

  int resolveMaxAudioChannels() => get(maxAudioChannels);

  PosterSize resolveLibraryPosterSize() {
    if (containsPreference(libraryPosterSize)) {
      return get(libraryPosterSize);
    }
    return get(posterSize);
  }

  PosterSize resolvePlaylistPosterSize() {
    if (containsPreference(playlistPosterSize)) {
      return get(playlistPosterSize);
    }
    return get(posterSize);
  }

  /// The hardware audio capabilities last detected by the platform probe, or an
  /// optimistic (decode-everything / passthrough-nothing) profile when none has
  /// been detected. Mirrors how the playback backends build their profile.
  AudioCapabilityProfile get detectedAudioCapabilities =>
      PlatformDetection.hasAudioCapabilities
      ? AudioCapabilityProfile.fromMap(
          PlatformDetection.audioCapabilitiesSnapshot,
        )
      : const AudioCapabilityProfile.optimistic();

  // Tri-state passthrough resolution: an explicitly-set toggle wins (On or
  // Off); when unset, the resolved value follows the detected hardware
  // capability so passthrough "just works" out of the box without the user
  // toggling anything. Callers may pass a profile they already built; when
  // omitted, the live detected profile is used. The DeviceProfileBuilder gate
  // already ANDs the codec hierarchy (e.g. DTS:X requires DTS core + DTS-HD)
  // across the resolved values, so each resolver only needs to report its own
  // capability.
  bool _resolvePassthrough(
    Preference<bool> pref,
    bool Function(AudioCapabilityProfile) capabilityOf,
    AudioCapabilityProfile? profile,
  ) => containsPreference(pref)
      ? get(pref)
      : capabilityOf(profile ?? detectedAudioCapabilities);

  bool resolveAc3PassthroughEnabled([AudioCapabilityProfile? profile]) =>
      _resolvePassthrough(
        ac3PassthroughEnabled,
        (p) => p.canPassthroughAc3,
        profile,
      );

  bool resolveEac3PassthroughEnabled([AudioCapabilityProfile? profile]) =>
      _resolvePassthrough(
        eac3PassthroughEnabled,
        (p) => p.canPassthroughEac3,
        profile,
      );

  bool resolveEac3JocPassthroughEnabled([AudioCapabilityProfile? profile]) =>
      _resolvePassthrough(
        eac3JocPassthroughEnabled,
        (p) => p.canPassthroughEac3Joc,
        profile,
      );

  bool resolveDtsCorePassthroughEnabled([AudioCapabilityProfile? profile]) =>
      _resolvePassthrough(
        dtsCorePassthroughEnabled,
        (p) => p.canPassthroughDts,
        profile,
      );

  bool resolveDtsHdPassthroughEnabled([AudioCapabilityProfile? profile]) =>
      _resolvePassthrough(
        dtsHdPassthroughEnabled,
        (p) => p.canPassthroughDtsHd,
        profile,
      );

  bool resolveDtsXPassthroughEnabled([AudioCapabilityProfile? profile]) =>
      _resolvePassthrough(
        dtsXPassthroughEnabled,
        (p) => p.canPassthroughDtsX,
        profile,
      );

  bool resolveTrueHdPassthroughEnabled([AudioCapabilityProfile? profile]) =>
      _resolvePassthrough(
        trueHdPassthroughEnabled,
        (p) => p.canPassthroughTrueHd,
        profile,
      );

  bool resolveTrueHdAtmosPassthroughEnabled([
    AudioCapabilityProfile? profile,
  ]) => _resolvePassthrough(
    trueHdAtmosPassthroughEnabled,
    (p) => p.canPassthroughTrueHdJoc,
    profile,
  );

  /// The eight per-codec passthrough toggle preferences.
  static final useNativeEmulator = Preference(
    key: 'pref_use_native_emulator',
    defaultValue: true,
  );

  static List<Preference<bool>> get passthroughTogglePreferences =>
      <Preference<bool>>[
        ac3PassthroughEnabled,
        eac3PassthroughEnabled,
        eac3JocPassthroughEnabled,
        dtsCorePassthroughEnabled,
        dtsHdPassthroughEnabled,
        dtsXPassthroughEnabled,
        trueHdPassthroughEnabled,
        trueHdAtmosPassthroughEnabled,
      ];

  /// Applies a high-level preset by bulk-writing the output mode and clearing
  /// per-codec overrides (so detection drives passthrough). Auto and AVR also
  /// reset Max Channels to Auto so the detected route maxes out (e.g. 8 on
  /// eARC, stereo on a stereo-only TV). [advanced] leaves the output mode,
  /// channels, and toggles untouched for manual control.
  Future<void> applyAudioPassthroughPreset(
    AudioPassthroughPreset preset,
  ) async {
    await set(audioPassthroughPreset, preset);
    switch (preset) {
      case AudioPassthroughPreset.auto:
        await set(audioOutputMode, AudioOutputMode.auto);
        await set(maxAudioChannels, 0);
        await clearPassthroughOverrides();
      case AudioPassthroughPreset.surroundReceiver:
        await set(audioOutputMode, AudioOutputMode.avrPassthrough);
        await set(maxAudioChannels, 0);
        await clearPassthroughOverrides();
      case AudioPassthroughPreset.stereo:
        await set(audioOutputMode, AudioOutputMode.forceStereo);
        await clearPassthroughOverrides();
      case AudioPassthroughPreset.advanced:
        // Snapshot the current effective values into explicit prefs so the
        // per-codec Advanced switches show the true state (a codec auto-enabled
        // by detection would otherwise read as a bare "off").
        await materializePassthroughOverrides();
    }
  }

  /// Clears every per-codec passthrough override so each resolves back to
  /// "Auto" (follow the detected capability).
  Future<void> clearPassthroughOverrides() async {
    for (final pref in passthroughTogglePreferences) {
      await removePreference(pref);
    }
  }

  /// Writes the current resolved (effective) passthrough values into explicit
  /// prefs for any toggle still on "Auto", so the per-codec Advanced switches
  /// reflect what detection is actually doing.
  Future<void> materializePassthroughOverrides() async {
    final profile = detectedAudioCapabilities;
    Future<void> materialize(Preference<bool> pref, bool value) async {
      if (!containsPreference(pref)) await set(pref, value);
    }

    await materialize(
      ac3PassthroughEnabled,
      resolveAc3PassthroughEnabled(profile),
    );
    await materialize(
      eac3PassthroughEnabled,
      resolveEac3PassthroughEnabled(profile),
    );
    await materialize(
      eac3JocPassthroughEnabled,
      resolveEac3JocPassthroughEnabled(profile),
    );
    await materialize(
      dtsCorePassthroughEnabled,
      resolveDtsCorePassthroughEnabled(profile),
    );
    await materialize(
      dtsHdPassthroughEnabled,
      resolveDtsHdPassthroughEnabled(profile),
    );
    await materialize(
      dtsXPassthroughEnabled,
      resolveDtsXPassthroughEnabled(profile),
    );
    await materialize(
      trueHdPassthroughEnabled,
      resolveTrueHdPassthroughEnabled(profile),
    );
    await materialize(
      trueHdAtmosPassthroughEnabled,
      resolveTrueHdAtmosPassthroughEnabled(profile),
    );
  }

  void notifyPreferenceChanged() {
    notifyListeners();
  }

  static String normalizeMediaBarMode(String? mode) {
    final normalized = (mode ?? '').trim().toLowerCase();
    if (mediaBarModeValues.contains(normalized)) {
      return normalized;
    }
    return mediaBarModeVoltix;
  }

  static bool isMediaBarModeEnabled(String? mode) {
    return normalizeMediaBarMode(mode) != mediaBarModeOff;
  }

  static final posterSize = EnumPreference(
    key: 'poster_size',
    defaultValue: PosterSize.small,
    values: PosterSize.values,
  );

  static final libraryPosterSize = EnumPreference(
    key: 'poster_size_library',
    defaultValue: PosterSize.medium,
    values: PosterSize.values,
  );

  static final playlistPosterSize = EnumPreference(
    key: 'poster_size_playlist',
    defaultValue: PosterSize.medium,
    values: PosterSize.values,
  );

  static final homeRowsStyle = EnumPreference(
    key: 'pref_home_rows_style',
    defaultValue: HomeRowsStyle.v1,
    values: HomeRowsStyle.values,
  );

  static final fullScreenRows = Preference(
    key: 'pref_home_rows_fullscreen',
    defaultValue: true,
  );

  /// Closes the app outright when it goes to the background instead of leaving
  /// it resident.
  ///
  /// This is for the black screen people hit after TV standby. A television
  /// does not tell an app it is going into standby — all the app ever sees is
  /// that it has been backgrounded — and on the way back the surface the
  /// renderer was drawing to is gone, so the app returns black and has to be
  /// force-stopped. Exiting on the way out makes the way back in always a clean
  /// start.
  ///
  /// Off by default. It is the right trade for someone who leaves Voltix open
  /// on a TV and hits this every evening, and the wrong one for someone who
  /// switches to another app for ten seconds and wants their place back — so it
  /// is a choice rather than a behaviour.
  static final exitOnBackground = Preference(
    key: 'pref_exit_on_background',
    defaultValue: false,
  );

  /// How long the on-screen notification banner stays up on a TV, in seconds.
  ///
  /// Set in the admin portal and delivered inside each push from the Voltix
  /// backend. It is remembered here because not every push comes from there:
  /// the Moonfin plugin sends its own FCM messages for Seerr events straight
  /// from the Jellyfin server, and those carry no such field. Without a
  /// remembered value, a Seerr notification would ignore the configured
  /// duration and fall back to the built-in default — so two notifications a
  /// second apart would sit on screen for different lengths of time.
  ///
  /// Not shown in Settings: it is an admin decision, not a viewer one.
  static final tvNotificationSeconds = Preference(
    key: 'pref_tv_notification_seconds',
    defaultValue: 8,
  );

  /// Hides Continue Watching entries that come from the shared Extra / 4K
  /// Lumistream servers, so the home row only shows the user's own primary
  /// progress. The two per-server switches below apply when this is on.
  static final hideSharedServerContinueWatching = Preference(
    key: 'pref_hide_shared_server_continue_watching',
    defaultValue: true,
  );

  static final hideContinueWatchingExtraServer = Preference(
    key: 'pref_hide_cw_extra_server',
    defaultValue: true,
  );

  static final hideContinueWatchingFourKServer = Preference(
    key: 'pref_hide_cw_4k_server',
    defaultValue: true,
  );

  /// When off, search only queries the active server instead of every server
  /// the user is signed in to (server + quality labels come with it).
  static final enableMultiServerSearch = Preference(
    key: 'enable_multi_server_search',
    defaultValue: true,
  );

  static final desktopUiScale = EnumPreference(
    key: 'pref_desktop_ui_scale',
    defaultValue: DesktopUiScale.medium,
    values: DesktopUiScale.values,
  );

  static final cardFocusExpansion = Preference(
    key: 'pref_card_focus_expansion',
    defaultValue: true,
  );

  static final backdropEnabled = Preference(
    key: 'pref_show_backdrop',
    defaultValue: true,
  );

  static final seriesThumbnailsEnabled = Preference(
    key: 'pref_enable_series_thumbnails',
    defaultValue: false,
  );

  static final homeRowInfoOverlay = Preference(
    key: 'pref_home_row_info_overlay',
    defaultValue: PlatformDetection.isTV,
  );

  static final favoritesViewStyle = EnumPreference(
    key: 'pref_favorites_view_style',
    defaultValue: FavoritesViewStyle.home,
    values: FavoritesViewStyle.values,
  );

  static final displayFavoritesRows = Preference(
    key: 'pref_display_favorites_rows',
    defaultValue: false,
  );

  static final displayCollectionsRows = Preference(
    key: 'pref_display_collections_rows',
    defaultValue: false,
  );

  static final displayGenresRows = Preference(
    key: 'pref_display_genres_rows',
    defaultValue: false,
  );

  static final displayPlaylistsRows = Preference(
    key: 'pref_display_playlists_rows',
    defaultValue: false,
  );

  static final displayAudioRows = Preference(
    key: 'pref_display_audio_rows',
    defaultValue: false,
  );

  static final displaySeerrRows = Preference(
    key: 'pref_display_seerr_rows',
    defaultValue: false,
  );

  /// Whether the per-library "Latest in `library`" rows show on the home
  /// screen. Off by default on this version -- the server-side
  /// latestItemsExcludes config (per-library, synced from Jellyfin/Emby)
  /// still applies underneath this, this is just a client-side master
  /// switch layered on top of it.
  static final displayLatestMediaRows = Preference(
    key: 'pref_display_latest_media_rows',
    defaultValue: false,
  );

  // ── Moonfin Recommends ────────────────────────────────────────
  //
  // Ported from Moonfin Core 2.4.0. Replaces the taste-quiz recommendation
  // system: suggestions are scored from library metadata the user already has
  // rather than a one-time onboarding quiz. The Jellyfin/Emby plugin computes
  // and syncs the rows; the client renders them in order.

  static final displaySinceYouWatchedRows = Preference(
    key: 'pref_display_since_you_watched_rows',
    defaultValue: true,
  );

  static final sinceYouWatched1Enabled = Preference(
    key: 'since_you_watched_1_enabled',
    defaultValue: false,
  );

  static final sinceYouWatched2Enabled = Preference(
    key: 'since_you_watched_2_enabled',
    defaultValue: false,
  );

  static final sinceYouWatched3Enabled = Preference(
    key: 'since_you_watched_3_enabled',
    defaultValue: false,
  );

  static final sinceYouWatched4Enabled = Preference(
    key: 'since_you_watched_4_enabled',
    defaultValue: false,
  );

  static final sinceYouWatched5Enabled = Preference(
    key: 'since_you_watched_5_enabled',
    defaultValue: false,
  );

  static final sinceYouWatchedSource = EnumPreference(
    key: 'pref_since_you_watched_source',
    defaultValue: SinceYouWatchedSource.local,
    values: SinceYouWatchedSource.values,
  );

  static final sinceYouWatchedSourceType = EnumPreference(
    key: 'pref_since_you_watched_source_type',
    defaultValue: SinceYouWatchedSourceType.movies,
    values: SinceYouWatchedSourceType.values,
  );

  static final sinceYouWatchedSourceItem = EnumPreference(
    key: 'pref_since_you_watched_source_item',
    defaultValue: SinceYouWatchedSourceItem.recentlyWatched,
    values: SinceYouWatchedSourceItem.values,
  );

  static final sinceYouWatchedNumRows = EnumPreference(
    key: 'pref_since_you_watched_num_rows',
    defaultValue: SinceYouWatchedNumRows.one,
    values: SinceYouWatchedNumRows.values,
  );

  static final sinceYouWatchedIncludeWatched = Preference(
    key: 'pref_since_you_watched_include_watched',
    defaultValue: false,
  );

  static final displayMoreWithActorRows = Preference(
    key: 'pref_display_more_with_actor_rows',
    defaultValue: true,
  );

  static final moreWithActor1Enabled = Preference(
    key: 'more_with_actor_1_enabled',
    defaultValue: true,
  );

  static final moreWithActor2Enabled = Preference(
    key: 'more_with_actor_2_enabled',
    defaultValue: true,
  );

  static final moreWithActor3Enabled = Preference(
    key: 'more_with_actor_3_enabled',
    defaultValue: false,
  );

  static final moreWithActorNumRows = EnumPreference(
    key: 'pref_more_with_actor_num_rows',
    defaultValue: MoreWithActorNumRows.two,
    values: MoreWithActorNumRows.values,
  );

  static final moreWithActorIncludeWatched = Preference(
    key: 'pref_more_with_actor_include_watched',
    defaultValue: false,
  );

  /// Algorithm source for the similar items recommendation system. Stored per server and
  /// user, because it syncs to that server's profile.
  static final recommendationSystemSource = EnumPreference(
    key: 'pref_recommendation_system_source',
    defaultValue: RecommendationSystemSource.local,
    values: RecommendationSystemSource.values,
  );

  /// Apply parental rating ceiling to Moonfin Recommends suggestions.
  static final recommendationsApplyParentalRatingCap = Preference(
    key: 'pref_recommendations_apply_parental_rating_cap',
    defaultValue: false,
  );

  static final favoritesRowSortBy = EnumPreference(
    key: 'pref_favorites_row_sort_by',
    defaultValue: LibrarySortBy.name,
    values: LibrarySortBy.values,
  );

  static final collectionsRowSortBy = EnumPreference(
    key: 'pref_collections_row_sort_by',
    defaultValue: LibrarySortBy.name,
    values: LibrarySortBy.values,
  );

  static final genresRowSortBy = EnumPreference(
    key: 'pref_genres_row_sort_by',
    defaultValue: LibrarySortBy.name,
    values: LibrarySortBy.values,
  );

  static final playlistsRowSortBy = EnumPreference(
    key: 'pref_playlists_row_sort_by',
    defaultValue: LibrarySortBy.name,
    values: LibrarySortBy.values,
  );

  static final audioRowsSortBy = EnumPreference(
    key: 'pref_audio_rows_sort_by',
    defaultValue: LibrarySortBy.name,
    values: LibrarySortBy.values,
  );

  static final studiosRowSortBy = EnumPreference(
    key: 'pref_studios_row_sort_by',
    defaultValue: LibrarySortBy.name,
    values: LibrarySortBy.values,
  );

  static final studiosRowSortOrder = EnumPreference(
    key: 'pref_studios_row_sort_order',
    defaultValue: SortDirection.ascending,
    values: SortDirection.values,
  );

  static final studiosRowSelectedIds = Preference<String>(
    key: 'pref_studios_row_selected_ids',
    defaultValue: '',
  );

  static final genresRowItemFilter = EnumPreference(
    key: 'pref_genres_row_item_filter',
    defaultValue: GenresRowItemFilter.both,
    values: GenresRowItemFilter.values,
  );

  static final watchedIndicatorBehavior = EnumPreference(
    key: 'pref_watched_indicator_behavior',
    defaultValue: WatchedIndicatorBehavior.always,
    values: WatchedIndicatorBehavior.values,
  );

  static final mergeContinueWatchingNextUp = Preference(
    key: 'pref_merge_continue_watching_next_up',
    defaultValue: true,
  );

  static final focusColor = EnumPreference(
    key: 'focus_color',
    defaultValue: AppTheme.white,
    values: AppTheme.values,
  );

  static final preferSystemImeKeyboard = Preference(
    key: 'pref_prefer_system_ime_keyboard',
    defaultValue: PlatformDetection.useMobileUi || PlatformDetection.isDesktop,
  );

  static final visualTheme = EnumPreference(
    key: 'app_theme_id',
    defaultValue: VisualThemeId.voltix,
    values: VisualThemeId.values,
  );

  /// Optional id of a plugin-supplied custom theme. When non-empty and the id
  /// resolves to a registered custom theme, it overrides [visualTheme].
  /// Empty string means "use the built-in [visualTheme] selection".
  static final customThemeId = Preference(
    key: 'pref_custom_theme_id',
    defaultValue: '',
  );

  static final showClock = Preference(
    key: 'pref_show_clock',
    defaultValue: true,
  );

  static final use24HourClock = Preference(
    key: 'pref_use_24_hour_clock',
    defaultValue: true,
  );

  /// Which programme guide the Live TV screen requests.
  ///
  /// 'provider' - the IPTV provider's own xmltv.php guide (default, enriched with DStv thumbnail artwork)
  /// 'dstv'     - the DStv XMLTV feed only
  /// 'auto'     - DStv guide for DStv channels, provider guide for everything else
  static final liveTvEpgSource = Preference(
    key: 'pref_live_tv_epg_source',
    defaultValue: 'provider',
  );

  /// Channel tiles per row on the Live TV grid.
  ///
  /// 0 means "Auto": fit as many as the screen width allows. Any other value
  /// pins the column count, letting the viewer trade tile size against how much
  /// of the channel list is visible at once.
  static final liveTvChannelColumns = Preference(
    key: 'pref_live_tv_channel_columns',
    defaultValue: 0,
  );

  static final showShuffleButton = Preference(
    key: 'pref_show_shuffle_button',
    defaultValue: true,
  );

  static final showGenresButton = Preference(
    key: 'pref_show_genres_button',
    defaultValue: true,
  );

  static final showFavoritesButton = Preference(
    key: 'pref_show_favorites_button',
    defaultValue: true,
  );

  static final showSyncPlayButton = Preference(
    key: 'pref_show_syncplay_button',
    defaultValue: true,
  );

  /// Whether the "Remote control" entry appears in the user menu.
  ///
  /// Defaults to true so the entry does not disappear for anyone already using
  /// it; the toggle exists so it can be hidden on devices that never cast.
  static final showRemoteControlButton = Preference(
    key: 'pref_show_remote_control_button',
    defaultValue: false,
  );

  /// Whether the remote shows a D-pad (arrows, select, back) for driving the
  /// remote session's on-screen UI, not just its playback.
  ///
  /// Separate from [showRemoteControlButton] because the navigation commands are
  /// only meaningful when the target is a TV-style client; on a phone target they
  /// do nothing.
  static final remoteControlShowDpad = Preference(
    key: 'pref_remote_control_show_dpad',
    defaultValue: true,
  );

  /// Libraries in the main menu.
  ///
  /// Off by default: the Voltix menu leads with Home, Live TV and the guide,
  /// and the raw Jellyfin library list underneath them is not how people are
  /// meant to find things here.
  ///
  /// NOTE: this is only the default. The Moonfin plugin syncs a
  /// `showLibrariesInToolbar` setting over the top of it (see
  /// PluginSyncService), so if the server sends `true` the entry comes back
  /// regardless of what is set here — turn it off there to make it stick
  /// without shipping an app build.
  static final showLibrariesInToolbar = Preference(
    key: 'pref_show_libraries_in_toolbar',
    defaultValue: false,
  );

  static final showSeerrButton = Preference(
    key: 'pref_show_seerr_button',
    defaultValue: true,
  );

  static final adminDrawerOrder = Preference(
    key: 'pref_admin_drawer_order',
    defaultValue: '',
  );

  static final navbarPosition = EnumPreference(
    key: 'pref_navbar_position',
    defaultValue: NavbarPosition.left,
    values: NavbarPosition.values,
  );

  static final shuffleContentType = Preference(
    key: 'pref_shuffle_content_type',
    defaultValue: 'both',
  );
  static final clockBehavior = EnumPreference(
    key: 'pref_clock_behavior',
    defaultValue: ClockBehavior.always,
    values: ClockBehavior.values,
  );
  static final enableMultiServerLibraries = Preference(
    key: 'enable_multi_server_libraries',
    defaultValue: true,
  );

  static final diagnosticLoggingEnabled = Preference(
    key: 'pref_diagnostic_logging_enabled',
    defaultValue: false,
  );

  /// Gates uploading crash reports to the server. Capture itself always runs
  /// and stays on the device.
  static final crashReportsEnabled = Preference(
    key: 'pref_crash_reports_enabled',
    defaultValue: true,
  );

  static final enableFolderView = Preference(
    key: 'enable_folder_view',
    defaultValue: false,
  );

  static final showMediaDetailsOnLibraryPage = Preference(
    key: 'pref_show_media_details_on_library_page',
    defaultValue: true,
  );

  static final useDetailedSubHeadings = Preference(
    key: 'pref_use_detailed_sub_headings',
    defaultValue: true,
  );
  /// Transcoding limits, defaulted conservatively on TV.
  ///
  /// 120 Mbps and "auto" are effectively no limit: the player asks the server
  /// for the original file and tries to decode it locally. That is right on a
  /// desktop or a capable box, and wrong on the hardware most TV installs
  /// actually run on -- an entry-level panel handed a 40GB 4K remux does not
  /// fail loudly, it simply never starts, which is indistinguishable from the
  /// app being broken.
  ///
  /// So TV defaults to 20 Mbps and 1080p, which the server transcodes down to
  /// and every Android TV device can decode. Both are ordinary settings, so a
  /// Shield or a capable 4K box raises them once in
  /// Settings > Video Playback > Transcoding limits and the choice sticks.
  ///
  /// Defaults apply only where nothing is stored, so anyone who has already
  /// chosen a limit keeps it.
  static final maxBitrate = Preference(
    key: 'pref_max_bitrate',
    defaultValue: PlatformDetection.isTV ? '20' : '120',
  );

  static final maxVideoResolution = EnumPreference(
    key: 'pref_max_video_resolution',
    defaultValue: PlatformDetection.isTV
        ? MaxVideoResolution.res1080p
        : MaxVideoResolution.auto,
    values: MaxVideoResolution.values,
  );

  static final mediaQueuingEnabled = Preference(
    key: 'pref_enable_tv_queuing',
    defaultValue: true,
  );

  static final autoplayNextEpisode = Preference(
    key: 'pref_autoplay_next_episode',
    defaultValue: true,
  );

  static final nextUpBehavior = EnumPreference(
    key: 'next_up_behavior',
    defaultValue: NextUpBehavior.extended,
    values: NextUpBehavior.values,
  );

  static final nextUpTimeout = Preference(
    key: 'next_up_timeout',
    defaultValue: 7000,
  );

  static final resumeSubtractDuration = Preference(
    key: 'pref_resume_preroll',
    defaultValue: '0',
  );

  static final cinemaModeEnabled = Preference(
    key: 'pref_enable_cinema_mode',
    defaultValue: true,
  );

  static final stillWatchingBehavior = EnumPreference(
    key: 'enable_still_watching',
    defaultValue: StillWatchingBehavior.disabled,
    values: StillWatchingBehavior.values,
  );

  static final screensaverEnabled = Preference(
    key: 'pref_screensaver_enabled',
    defaultValue: true,
  );

  static final screensaverMode = EnumPreference(
    key: 'pref_screensaver_mode',
    defaultValue: ScreensaverMode.library,
    values: ScreensaverMode.values,
  );

  static final screensaverTimeout = EnumPreference(
    key: 'pref_screensaver_timeout',
    defaultValue: ScreensaverTimeout.m5,
    values: ScreensaverTimeout.values,
  );

  static final screensaverDimming = Preference(
    key: 'pref_screensaver_dimming',
    defaultValue: 0,
  );

  static final screensaverClockMode = EnumPreference(
    key: 'pref_screensaver_clock_mode',
    defaultValue: ScreensaverClockMode.off,
    values: ScreensaverClockMode.values,
  );

  static final screensaverMaxAgeRating = Preference(
    key: 'pref_screensaver_max_age_rating',
    defaultValue: 'any',
  );

  static final screensaverRequireRating = Preference(
    key: 'pref_screensaver_require_rating',
    defaultValue: false,
  );

  static final useExternalPlayer = Preference(
    key: 'external_player',
    defaultValue: false,
  );

  static final externalPlayerComponentName = Preference(
    key: 'external_player_component',
    defaultValue: '',
  );

  static final refreshRateSwitchingBehavior = EnumPreference(
    key: 'refresh_rate_switching_behavior',
    defaultValue: RefreshRateSwitchingBehavior.disabled,
    values: RefreshRateSwitchingBehavior.values,
  );

  static final autoHdrSwitchingBehavior = EnumPreference(
    key: 'auto_hdr_switching_behavior',
    defaultValue: AutoHdrSwitchingBehavior.disabled,
    values: AutoHdrSwitchingBehavior.values,
  );

  static final preferExoPlayerFfmpeg = Preference(
    key: 'exoplayer_prefer_ffmpeg',
    defaultValue: !(PlatformDetection.isAndroid && PlatformDetection.isTV),
  );

  static final media3SkipSilence = Preference(
    key: 'media3_skip_silence',
    defaultValue: false,
  );

  static final media3TunnelingDisabled = Preference(
    key: 'media3_tunneling_disabled',
    defaultValue: true,
  );

  static final media3MapDolbyVisionProfile7ToHevc = Preference(
    key: 'media3_map_dolby_vision_profile7_to_hevc',
    defaultValue: false,
  );

  static final media3AllowExternalAudioEffects = Preference(
    key: 'media3_allow_external_audio_effects',
    defaultValue: true,
  );

  static final tunnelingFallbackDisabled = Preference(
    key: 'tunneling_fallback_disabled',
    defaultValue: false,
  );

  static final playerZoomMode = EnumPreference(
    key: 'player_zoom_mode',
    defaultValue: ZoomMode.fit,
    values: ZoomMode.values,
  );

  static final desktopScrollWheelAction = EnumPreference(
    key: 'desktop_scroll_wheel_action',
    defaultValue: DesktopScrollWheelAction.volume,
    values: DesktopScrollWheelAction.values,
  );

  static final trickPlayEnabled = Preference(
    key: 'trick_play_enabled',
    defaultValue: false,
  );

  static final pgsDirectPlay = Preference(
    key: 'pgs_enabled',
    defaultValue: true,
  );

  static final assDirectPlay = Preference(
    key: 'ass_enabled',
    defaultValue: true,
  );

  static final videoStartDelay = Preference(
    key: 'video_start_delay',
    defaultValue: 0,
  );
  static final audioOutputMode = EnumPreference(
    key: 'audio_output_mode',
    defaultValue: AudioOutputMode.auto,
    values: AudioOutputMode.values,
  );

  static final audioFallbackCodec = EnumPreference(
    key: 'audio_fallback_codec',
    defaultValue: AudioFallbackCodec.auto,
    values: AudioFallbackCodec.values,
  );

  static final audioPassthroughPreset = EnumPreference(
    key: 'pref_audio_passthrough_preset',
    defaultValue: AudioPassthroughPreset.auto,
    values: AudioPassthroughPreset.values,
  );

  /// One-time flag: existing installs that had their passthrough toggles
  /// auto-seeded by the old startup probe have been cleared back to "Auto"
  /// (tri-state follow-detection) where their stored value still matched the
  /// probe.
  static final audioPassthroughMigratedToAuto = Preference(
    key: 'pref_audio_passthrough_migrated_to_auto_v1',
    defaultValue: false,
  );

  static final maxAudioChannels = Preference<int>(
    key: 'pref_max_audio_channels',
    defaultValue: 0,
  );

  static final ac3PassthroughEnabled = Preference(
    key: 'pref_passthrough_ac3',
    defaultValue: false,
  );

  static final eac3PassthroughEnabled = Preference(
    key: 'pref_passthrough_eac3',
    defaultValue: false,
  );

  static final eac3JocPassthroughEnabled = Preference(
    key: 'pref_passthrough_eac3_joc',
    defaultValue: false,
  );

  static final dtsCorePassthroughEnabled = Preference(
    key: 'pref_passthrough_dts_core',
    defaultValue: false,
  );

  static final dtsHdPassthroughEnabled = Preference(
    key: 'pref_passthrough_dts_hd',
    defaultValue: false,
  );

  static final dtsXPassthroughEnabled = Preference(
    key: 'pref_passthrough_dts_x',
    defaultValue: false,
  );

  static final trueHdPassthroughEnabled = Preference(
    key: 'pref_passthrough_truehd',
    defaultValue: false,
  );

  static final trueHdAtmosPassthroughEnabled = Preference(
    key: 'pref_passthrough_truehd_atmos',
    defaultValue: false,
  );

  static final audioNightMode = Preference(
    key: 'audio_night_mode',
    defaultValue: false,
  );

  static final appleTvHybridAtmosEnabled = Preference(
    key: 'pref_appletv_hybrid_atmos',
    defaultValue: true,
  );

  static final appleTvAudioPassthroughEnabled = Preference(
    key: 'pref_appletv_audio_passthrough',
    defaultValue: false,
  );

  static final audioPrefsAutoDetected = Preference(
    key: 'pref_audio_caps_auto_detected',
    defaultValue: false,
  );

  static final audioPassthroughProbeSeeded = Preference(
    key: 'pref_audio_passthrough_probe_seeded_v1',
    defaultValue: false,
  );

  static final customMpvConfEnabled = Preference(
    key: 'custom_mpv_conf_enabled',
    defaultValue: false,
  );

  static final customMpvConfPath = Preference(
    key: 'custom_mpv_conf_path',
    defaultValue: '',
  );

  static final customMpvConfUnsafeAdvanced = Preference(
    key: 'custom_mpv_conf_unsafe_advanced',
    defaultValue: false,
  );

  static final hardwareDecoding = Preference(
    key: 'hardware_decoding',
    defaultValue: PlatformDetection.isAndroid || PlatformDetection.isIOS,
  );

  static final playbackEnginePreference = EnumPreference(
    key: 'playback_engine_preference',
    defaultValue: PlatformDetection.isAndroid && PlatformDetection.isTV
        ? PlaybackEnginePreference.media3
        : PlaybackEnginePreference.mpv,
    values: PlaybackEnginePreference.values,
  );

  /// What to do with Dolby Vision content the device cannot play natively.
  ///
  /// Only ever consulted for a device that has already been established as NOT
  /// Dolby Vision capable but able to do some other HDR -- a true DV panel
  /// plays natively and never reaches this, and a device with no HDR at all
  /// transcodes regardless. So changing the TV default costs capable hardware
  /// nothing.
  ///
  /// "Ask" resolves to attempting DV playback anyway, which on a TV that cannot
  /// decode it is the black screen that never starts. Transcoding is the only
  /// outcome that produces a picture on that hardware, so TV asks the server to
  /// do it rather than trying and failing.
  static final dolbyVisionFallbackBehavior = EnumPreference(
    key: 'dolby_vision_fallback_behavior',
    defaultValue: PlatformDetection.isTV
        ? DolbyVisionFallbackBehavior.transcode
        : DolbyVisionFallbackBehavior.ask,
    values: DolbyVisionFallbackBehavior.values,
  );

  static final dolbyVisionProfile7DirectPlayBehavior = EnumPreference(
    key: 'dolby_vision_profile7_direct_play_behavior',
    defaultValue: DolbyVisionProfile7DirectPlayBehavior.auto,
    values: DolbyVisionProfile7DirectPlayBehavior.values,
  );

  static final languageOverride = Preference<String>(
    key: 'pref_language_override',
    defaultValue: 'system',
  );

  static final defaultAudioLanguage = Preference(
    key: 'pref_audio_language',
    defaultValue: 'auto',
  );
  static final defaultSubtitleLanguage = Preference(
    key: 'pref_subtitle_language',
    defaultValue: '',
  );

  static final subtitlesBackgroundColor = Preference(
    key: 'subtitles_background_color',
    defaultValue: 0x00000000,
  );

  static final subtitlesTextWeight = Preference(
    key: 'subtitles_text_weight',
    defaultValue: 400,
  );

  static final subtitlesTextColor = Preference(
    key: 'subtitles_text_color',
    defaultValue: 0xFFFFFFFF,
  );

  static final subtitleTextStrokeColor = Preference(
    key: 'subtitles_text_stroke_color',
    defaultValue: 0xFF000000,
  );

  static final subtitlesTextSize = Preference(
    key: 'subtitles_text_size',
    defaultValue: 20.0,
  );

  static final subtitlesOffsetPosition = Preference(
    key: 'subtitles_offset_position',
    defaultValue: 0.04,
  );

  /// A second appearance used only while HDR reaches the screen, defaulting to
  /// grey text since white reads far brighter in HDR than in SDR.
  static final subtitlesHdrSeparate = Preference(
    key: 'subtitles_hdr_separate',
    defaultValue: false,
  );

  static final subtitlesHdrBackgroundColor = Preference(
    key: 'subtitles_hdr_background_color',
    defaultValue: 0x00000000,
  );

  static final subtitlesHdrTextWeight = Preference(
    key: 'subtitles_hdr_text_weight',
    defaultValue: 400,
  );

  static final subtitlesHdrTextColor = Preference(
    key: 'subtitles_hdr_text_color',
    defaultValue: 0xFF808080,
  );

  static final subtitlesHdrTextStrokeColor = Preference(
    key: 'subtitles_hdr_text_stroke_color',
    defaultValue: 0xFF000000,
  );

  static final subtitlesHdrTextSize = Preference(
    key: 'subtitles_hdr_text_size',
    defaultValue: 20.0,
  );

  static final subtitlesHdrOffsetPosition = Preference(
    key: 'subtitles_hdr_offset_position',
    defaultValue: 0.04,
  );

  static final subtitlesDefaultToNone = Preference(
    key: 'subtitles_default_to_none',
    defaultValue: false,
  );

  /// Whether embedded subtitle styles (colours, positioning, fonts) should be
  /// applied when rendering text tracks. Disable to force the user's caption
  /// style preferences instead. Media3 (Android) only.
  static final subtitlesUseEmbeddedStyles = Preference(
    key: 'subtitles_use_embedded_styles',
    defaultValue: true,
  );

  /// Whether embedded subtitle font-size hints should be applied. Independent
  /// of [subtitlesUseEmbeddedStyles] so users can keep colours but override
  /// font sizes. Media3 (Android) only.
  static final subtitlesUseEmbeddedFontSizes = Preference(
    key: 'subtitles_use_embedded_font_sizes',
    defaultValue: true,
  );

  static final preferSdhSubtitles = Preference(
    key: 'prefer_sdh_subtitles',
    defaultValue: false,
  );

  static final mediaSegmentActions = Preference(
    key: 'media_segment_actions',
    defaultValue: 'intro:askToSkip,outro:askToSkip',
  );

  static final mediaSegmentCountdown = EnumPreference(
    key: 'pref_media_segment_countdown',
    defaultValue: MediaSegmentCountdown.both,
    values: MediaSegmentCountdown.values,
  );

  static final replaceSkipOutroWithNextUp = Preference(
    key: 'replace_skip_outro_with_next_up',
    defaultValue: false,
  );

  static final skipBackLength = Preference(
    key: 'skipBackLength',
    defaultValue: 10000,
  );

  static final skipForwardLength = Preference(
    key: 'skipForwardLength',
    defaultValue: 30000,
  );

  static final unpauseRewindDuration = Preference(
    key: 'unpauseRewindDuration',
    defaultValue: 0,
  );

  static final showDescriptionOnPause = Preference(
    key: 'showDescriptionOnPause',
    defaultValue: false,
  );
  static final osdLockEnabled = Preference(
    key: 'osdLockEnabled',
    defaultValue: false,
  );
  static final mediaBarEnabled = Preference(
    key: 'mediaBarEnabled',
    defaultValue: true,
  );

  static final voltixJellyfinEnabled = Preference(
    key: 'voltix_jellyfin_enabled',
    defaultValue: true,
  );

  static final voltixLiveTvEnabled = Preference(
    key: 'voltix_live_tv_enabled',
    defaultValue: false,
  );

  static final mediaBarMode = Preference(
    key: 'mediaBarMode',
    defaultValue: mediaBarModeVoltix,
  );

  static final mediaBarContentType = Preference(
    key: 'mediaBarContentType',
    defaultValue: 'both',
  );

  static final mediaBarItemCount = Preference(
    key: 'mediaBarItemCount',
    defaultValue: '10',
  );

  static final navbarOpacity = Preference(
    key: 'navbarOpacity',
    defaultValue: 50,
  );

  static final navbarColor = Preference(
    key: 'navbarColor',
    defaultValue: 'gray',
  );

  static final mediaBarOverlayOpacity = Preference(
    key: 'mediaBarOverlayOpacity',
    defaultValue: 50,
  );

  static final mediaBarOverlayColor = Preference(
    key: 'mediaBarOverlayColor',
    defaultValue: 'gray',
  );

  static final mediaBarAutoAdvance = Preference(
    key: 'mediaBarAutoAdvance',
    defaultValue: true,
  );

  static final mediaBarIntervalMs = Preference(
    key: 'mediaBarIntervalMs',
    defaultValue: 10000,
  );

  static final mediaBarTrailerPreview = Preference(
    key: 'mediaBarTrailerPreview',
    defaultValue: false,
  );

  static final mediaBarTrailerAudio = Preference(
    key: 'mediaBarTrailerAudio',
    defaultValue: false,
  );

  static final mediaBarLibraryIds = Preference(
    key: 'mediaBarLibraryIds',
    defaultValue: '',
  );

  static final mediaBarCollectionIds = Preference(
    key: 'mediaBarCollectionIds',
    defaultValue: '',
  );

  static final mediaBarExcludedGenres = Preference(
    key: 'mediaBarExcludedGenres',
    defaultValue: '',
  );

  static final episodePreviewEnabled = Preference(
    key: 'episodePreviewEnabled',
    defaultValue: false,
  );

  static final previewAudioEnabled = Preference(
    key: 'previewAudioEnabled',
    defaultValue: false,
  );
  static final homeRowsUniversalOverride = Preference(
    key: 'homeRowsUniversalOverride',
    defaultValue: false,
  );

  static final homeRowsUniversalImageType = EnumPreference(
    key: 'homeRowsUniversalImageType',
    defaultValue: ImageType.thumb,
    values: ImageType.values,
  );

  static EnumPreference<ImageType> homeRowImageType(
    HomeSectionType sectionType,
  ) => EnumPreference(
    key: 'homeRowImageType_${sectionType.serializedName}',
    defaultValue: _defaultHomeRowImageType(sectionType),
    values: ImageType.values,
  );

  static ImageType _defaultHomeRowImageType(HomeSectionType sectionType) {
    return switch (sectionType) {
      HomeSectionType.resume ||
      HomeSectionType.nextUp ||
      HomeSectionType.libraryTilesSmall => ImageType.banner,
      _ => ImageType.poster,
    };
  }

  static final detailsBackgroundBlurAmount = Preference(
    key: 'detailsBackgroundBlurAmount',
    defaultValue: 10,
  );

  static final browsingBackgroundBlurAmount = Preference(
    key: 'browsingBackgroundBlurAmount',
    defaultValue: 10,
  );
  static final enableAdditionalRatings = Preference(
    key: 'enableAdditionalRatings',
    defaultValue: false,
  );

  static final mdblistApiKey = Preference(
    key: 'mdblistApiKey',
    defaultValue: '',
  );

  static final enableEpisodeRatings = Preference(
    key: 'enableEpisodeRatings',
    defaultValue: false,
  );

  static final tmdbApiKey = Preference(key: 'tmdbApiKey', defaultValue: '');

  /// OMDb key for the awards index behind the Oscar / award-season rows.
  ///
  /// Only used when the Voltix backend has no awards endpoint to answer
  /// instead. OMDb's free tier is counted against the key rather than the
  /// user, so a key shipped with the app is shared by every install --
  /// TasteAwardsIndex caches hard and caps lookups per session for exactly
  /// that reason.
  static final omdbApiKey = Preference(key: 'omdbApiKey', defaultValue: '');

  static final tmdbPopularMoviesEnabled = Preference(
    key: 'tmdb_popular_movies_enabled',
    defaultValue: false,
  );

  static final tmdbTopRatedMoviesEnabled = Preference(
    key: 'tmdb_top_rated_movies_enabled',
    defaultValue: false,
  );

  static final tmdbNowPlayingMoviesEnabled = Preference(
    key: 'tmdb_now_playing_movies_enabled',
    defaultValue: false,
  );

  static final tmdbUpcomingMoviesEnabled = Preference(
    key: 'tmdb_upcoming_movies_enabled',
    defaultValue: false,
  );

  static final tmdbPopularTvEnabled = Preference(
    key: 'tmdb_popular_tv_enabled',
    defaultValue: false,
  );

  static final tmdbTopRatedTvEnabled = Preference(
    key: 'tmdb_top_rated_tv_enabled',
    defaultValue: false,
  );

  static final tmdbAiringTodayTvEnabled = Preference(
    key: 'tmdb_airing_today_tv_enabled',
    defaultValue: false,
  );

  static final tmdbOnTheAirTvEnabled = Preference(
    key: 'tmdb_on_the_air_tv_enabled',
    defaultValue: false,
  );

  static final tmdbTrendingMovieDailyEnabled = Preference(
    key: 'tmdb_trending_movie_daily_enabled',
    defaultValue: false,
  );

  static final tmdbTrendingMovieWeeklyEnabled = Preference(
    key: 'tmdb_trending_movie_weekly_enabled',
    defaultValue: false,
  );

  static final tmdbTrendingTvDailyEnabled = Preference(
    key: 'tmdb_trending_tv_daily_enabled',
    defaultValue: false,
  );

  static final tmdbTrendingTvWeeklyEnabled = Preference(
    key: 'tmdb_trending_tv_weekly_enabled',
    defaultValue: false,
  );

  static final tmdbTrendingAllWeeklyEnabled = Preference(
    key: 'tmdb_trending_all_weekly_enabled',
    defaultValue: false,
  );

  static final showRatingLabels = Preference(
    key: 'showRatingLabels',
    defaultValue: true,
  );

  static final showRatingBadges = Preference(
    key: 'showRatingBadges',
    defaultValue: true,
  );

  static final enabledRatings = Preference(
    key: 'enabledRatings',
    defaultValue: 'tomatoes,stars',
  );

  static final blockedParentalRatings = Preference(
    key: 'blocked_ratings',
    defaultValue: '',
  );

  // ---- External Home Rows (ported from Moonfin Core 2.4.0) ----
  // IMDb chart rows and the Radarr/Sonarr upcoming calendars. The TMDB
  // chart preferences already existed in this fork. All of these are
  // fetched through the server plugin's CustomRows controller.
  static final lastExternalRowsRefreshTime = Preference(
    key: 'last_external_rows_refresh_time',
    defaultValue: 0,
  );

  static final imdbTop250MoviesEnabled = Preference(
    key: 'imdb_top_250_movies_enabled',
    defaultValue: false,
  );

  static final imdbTop250TvShowsEnabled = Preference(
    key: 'imdb_top_250_tv_shows_enabled',
    defaultValue: false,
  );

  static final imdbMostPopularMoviesEnabled = Preference(
    key: 'imdb_most_popular_movies_enabled',
    defaultValue: false,
  );

  static final imdbMostPopularTvShowsEnabled = Preference(
    key: 'imdb_most_popular_tv_shows_enabled',
    defaultValue: false,
  );

  static final imdbLowestRatedMoviesEnabled = Preference(
    key: 'imdb_lowest_rated_movies_enabled',
    defaultValue: false,
  );

  static final imdbTopEnglishMoviesEnabled = Preference(
    key: 'imdb_top_english_movies_enabled',
    defaultValue: false,
  );

  static final enableRadarrCalendar = Preference(
    key: 'enable_radarr_calendar',
    defaultValue: false,
  );

  static final enableSonarrCalendar = Preference(
    key: 'enable_sonarr_calendar',
    defaultValue: false,
  );

  static final radarrCalendarShowCinema = Preference(
    key: 'radarr_calendar_show_cinema',
    defaultValue: true,
  );

  static final radarrCalendarShowDigital = Preference(
    key: 'radarr_calendar_show_digital',
    defaultValue: true,
  );

  static final radarrCalendarShowPhysical = Preference(
    key: 'radarr_calendar_show_physical',
    defaultValue: true,
  );

  static final radarrCalendarShowDate = Preference(
    key: 'radarr_calendar_show_date',
    defaultValue: true,
  );

  static final sonarrCalendarShowDate = Preference(
    key: 'sonarr_calendar_show_date',
    defaultValue: true,
  );

  static final sonarrCalendarShowEpisodeInfo = Preference(
    key: 'sonarr_calendar_show_episode_info',
    defaultValue: true,
  );

  static final lastRadarrCalendarFetchTime = Preference(
    key: 'last_radarr_calendar_fetch_time',
    defaultValue: 0,
  );

  static final lastSonarrCalendarFetchTime = Preference(
    key: 'last_sonarr_calendar_fetch_time',
    defaultValue: 0,
  );

  static final mergeRadarrSonarrCalendars = Preference(
    key: 'merge_radarr_sonarr_calendars',
    defaultValue: false,
  );

  static final homeSectionsJson = Preference(
    key: 'home_sections_config',
    defaultValue: '',
  );

  SeriesTrackPreference getSeriesSubtitlePreference(String seriesId) {
    final pref = Preference(
      key: 'pref_series_subtitle_lang_$seriesId',
      defaultValue: '',
    );
    final raw = _store.get(pref);
    return SeriesTrackPreference.fromRawString(raw);
  }

  Future<void> setSeriesSubtitlePreference(
    String seriesId,
    SeriesTrackPreference pref,
  ) async {
    final key = Preference(
      key: 'pref_series_subtitle_lang_$seriesId',
      defaultValue: '',
    );
    await _store.set(key, pref.toRawString());
    notifyListeners();
  }

  SeriesTrackPreference getSeriesAudioPreference(String seriesId) {
    final pref = Preference(
      key: 'pref_series_audio_lang_$seriesId',
      defaultValue: '',
    );
    final raw = _store.get(pref);
    return SeriesTrackPreference.fromRawString(raw);
  }

  Future<void> setSeriesAudioPreference(
    String seriesId,
    SeriesTrackPreference pref,
  ) async {
    final key = Preference(
      key: 'pref_series_audio_lang_$seriesId',
      defaultValue: '',
    );
    await _store.set(key, pref.toRawString());
    notifyListeners();
  }

  int getItemSubtitleStreamIndex(String itemId) {
    final pref = Preference<int>(
      key: 'pref_item_subtitle_index_$itemId',
      defaultValue: -2,
    );
    return _store.get(pref);
  }

  Future<void> setItemSubtitleStreamIndex(String itemId, int? index) async {
    final pref = Preference<int>(
      key: 'pref_item_subtitle_index_$itemId',
      defaultValue: -2,
    );
    if (index == null) {
      await _store.delete(pref);
    } else {
      await _store.set(pref, index);
    }
    notifyListeners();
  }

  int getItemAudioStreamIndex(String itemId) {
    final pref = Preference<int>(
      key: 'pref_item_audio_index_$itemId',
      defaultValue: -2,
    );
    return _store.get(pref);
  }

  Future<void> setItemAudioStreamIndex(String itemId, int? index) async {
    final pref = Preference<int>(
      key: 'pref_item_audio_index_$itemId',
      defaultValue: -2,
    );
    if (index == null) {
      await _store.delete(pref);
    } else {
      await _store.set(pref, index);
    }
    notifyListeners();
  }

  List<HomeSectionConfig> get homeSectionsConfig {
    final json = get(homeSectionsJson);
    return HomeSectionConfig.fromJsonString(json);
  }

  Future<void> setHomeSectionsConfig(List<HomeSectionConfig> configs) =>
      set(homeSectionsJson, HomeSectionConfig.toJsonString(configs));

  List<HomeSectionType> get activeHomeSections {
    final enabled = homeSectionsConfig.where((c) => c.enabled).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    return enabled
        .where((c) => c.isBuiltin && c.type != HomeSectionType.none)
        .map((c) => c.type)
        .toList();
  }

  /// Ordered list of all enabled section configs (builtin + plugin dynamic).
  /// Built-in `none` entries are filtered out.
  List<HomeSectionConfig> get activeHomeSectionConfigs {
    final enabled = homeSectionsConfig.where((c) => c.enabled).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    return enabled
        .where((c) => c.isPluginDynamic || c.type != HomeSectionType.none)
        .toList();
  }

  static final themeMusicEnabled = Preference(
    key: 'themeMusicEnabled',
    defaultValue: false,
  );

  static final themeMusicVolume = Preference(
    key: 'themeMusicVolume',
    defaultValue: 30,
  );

  static final themeMusicOnHomeRows = Preference(
    key: 'themeMusicOnHomeRows',
    defaultValue: false,
  );
  static final liveTvDirectPlayEnabled = Preference(
    key: 'pref_live_direct',
    defaultValue: true,
  );
  static final syncPlayEnabled = Preference(
    key: 'pref_syncplay_enabled',
    defaultValue: true,
  );

  static final syncPlayEnableSyncCorrection = Preference(
    key: 'syncplay_enable_sync_correction',
    defaultValue: true,
  );

  static final syncPlayUseSpeedToSync = Preference(
    key: 'syncplay_use_speed_to_sync',
    defaultValue: true,
  );

  static final syncPlayUseSkipToSync = Preference(
    key: 'syncplay_use_skip_to_sync',
    defaultValue: true,
  );

  static final syncPlayMinDelaySpeedToSync = Preference(
    key: 'syncplay_min_delay_speed_to_sync',
    defaultValue: 120.0,
  );

  static final syncPlayMaxDelaySpeedToSync = Preference(
    key: 'syncplay_max_delay_speed_to_sync',
    defaultValue: 2500.0,
  );

  static final syncPlaySpeedToSyncDuration = Preference(
    key: 'syncplay_speed_to_sync_duration',
    defaultValue: 1200.0,
  );

  static final syncPlayMinDelaySkipToSync = Preference(
    key: 'syncplay_min_delay_skip_to_sync',
    defaultValue: 2000.0,
  );

  static final syncPlayExtraTimeOffset = Preference(
    key: 'syncplay_extra_time_offset',
    defaultValue: 0.0,
  );
  static final pluginSyncEnabled = Preference(
    key: 'pref_plugin_sync_enabled',
    defaultValue: false,
  );

  static Preference<bool> pluginSyncInitializedForServer(String serverKey) =>
      Preference(
        key: 'pref_plugin_sync_initialized_$serverKey',
        defaultValue: false,
      );

  static final voltixUseTestServer = Preference(
    key: 'voltix_use_test_server',
    defaultValue: false,
  );

  static final tasteOnboardingSeen = Preference(
    key: 'taste_onboarding_seen',
    defaultValue: false,
  );

  static final grokApiKey = Preference<String>(
    key: 'grok_api_key',
    defaultValue: '',
  );

  static final grokModel = Preference<String>(
    key: 'grok_model',
    defaultValue: 'grok-2-latest',
  );

  static final grokEndpoint = Preference<String>(
    key: 'grok_endpoint',
    defaultValue: 'https://api.x.ai/v1',
  );

  /// Optional runtime override for the taste-profile blob credentials.
  ///
  /// Only the SAS parts are honoured (`SharedAccessSignature=` / `SasToken=`,
  /// or a full blob URL carrying one). An `AccountKey=` in this string is
  /// discarded: nothing in the client signs with it, and holding an account
  /// key on a device would grant whoever extracted it full read/write/delete
  /// over every user's profile, settings and watch history. Normally left
  /// empty so the build-time AZURE_BLOB_SAS_TOKEN, or the Voltix proxy,
  /// answers instead.
  static final azureStorageConnectionString = Preference<String>(
    key: 'azure_storage_connection_string',
    defaultValue: '',
  );

  static final azureBlobContainer = Preference<String>(
    key: 'azure_blob_container',
    defaultValue: 'voltix-taste-profiles',
  );

  static final confirmExit = Preference(
    key: 'confirm_exit',
    defaultValue: true,
  );

  static final updateNotificationsEnabled = Preference(
    key: 'update_notifications_enabled',
    defaultValue: true,
  );

  static final seasonalSurprise = Preference(
    key: 'seasonal_surprise',
    defaultValue: 'none',
  );

  static final autoLoginUserBehavior = EnumPreference(
    key: 'pref_auto_login_behavior',
    defaultValue: UserSelectBehavior.lastUser,
    values: UserSelectBehavior.values,
  );

  static final autoLoginServerId = Preference(
    key: 'pref_auto_login_server_id',
    defaultValue: '',
  );

  static final autoLoginUserId = Preference(
    key: 'pref_auto_login_user_id',
    defaultValue: '',
  );

  static final lastServerId = Preference(
    key: 'pref_last_server_id',
    defaultValue: '',
  );

  static final lastUserId = Preference(
    key: 'pref_last_user_id',
    defaultValue: '',
  );

  static final alwaysAuthenticate = Preference(
    key: 'pref_always_authenticate',
    defaultValue: false,
  );
  static final userPinHash = Preference(key: 'user_pin_hash', defaultValue: '');

  static final userPinEnabled = Preference(
    key: 'user_pin_enabled',
    defaultValue: false,
  );

  static EnumPreference<LibrarySortBy> librarySortBy(String libraryId) =>
      EnumPreference(
        key: 'library_sort_by_$libraryId',
        defaultValue: LibrarySortBy.name,
        values: LibrarySortBy.values,
      );

  static EnumPreference<SortDirection> librarySortDirection(String libraryId) =>
      EnumPreference(
        key: 'library_sort_dir_$libraryId',
        defaultValue: SortDirection.ascending,
        values: SortDirection.values,
      );

  static EnumPreference<PlayedStatusFilter> libraryPlayedFilter(
    String libraryId,
  ) => EnumPreference(
    key: 'library_played_filter_$libraryId',
    defaultValue: PlayedStatusFilter.all,
    values: PlayedStatusFilter.values,
  );

  static EnumPreference<SeriesStatusFilter> librarySeriesFilter(
    String libraryId,
  ) => EnumPreference(
    key: 'library_series_filter_$libraryId',
    defaultValue: SeriesStatusFilter.all,
    values: SeriesStatusFilter.values,
  );

  static Preference<bool> libraryFavoriteFilter(String libraryId) =>
      Preference(key: 'library_fav_filter_$libraryId', defaultValue: false);

  static EnumPreference<ImageType> libraryImageType(String libraryId) =>
      EnumPreference(
        key: 'library_image_type_$libraryId',
        defaultValue: ImageType.poster,
        values: ImageType.values,
      );

  static EnumPreference<LibraryScrollDirection> libraryScrollDirection(
    String libraryId,
  ) => EnumPreference(
    key: 'library_scroll_dir_$libraryId',
    defaultValue: LibraryScrollDirection.vertical,
    values: LibraryScrollDirection.values,
  );

  static EnumPreference<LibraryGroupBy> libraryGroupBy(String libraryId) =>
      EnumPreference(
        key: 'library_group_by_$libraryId',
        defaultValue: LibraryGroupBy.none,
        values: LibraryGroupBy.values,
      );

  static final allGenresImageType = EnumPreference(
    key: 'all_genres_image_type',
    defaultValue: ImageType.thumb,
    values: ImageType.values,
  );

  static EnumPreference<FavoriteTypeFilter> favoriteTypeFilter = EnumPreference(
    key: 'favorites_type_filter',
    defaultValue: FavoriteTypeFilter.all,
    values: FavoriteTypeFilter.values,
  );

  static final defaultFavoritesFilter = Preference(
    key: 'defaultFavoritesFilter',
    defaultValue: '',
  );

  static final seerrEnabled = Preference(
    key: 'seerr_enabled',
    defaultValue: false,
  );

  static final jellyseerrBlockNsfw = Preference(
    key: 'jellyseerrBlockNsfw',
    defaultValue: false,
  );

  static final defaultDownloadQuality = Preference(
    key: 'download_default_quality',
    defaultValue: 'original',
  );

  static final downloadWifiOnly = Preference(
    key: 'download_wifi_only',
    defaultValue: false,
  );

  static final downloadStorageLimitMb = Preference(
    key: 'download_storage_limit_mb',
    defaultValue: 0,
  );

  static final downloadConcurrentCount = Preference(
    key: 'download_concurrent_count',
    defaultValue: 2,
  );

  static final customDownloadPath = Preference(
    key: 'download_custom_path',
    defaultValue: '',
  );

  static final windowWidth = Preference(key: 'window_width', defaultValue: 0.0);

  static final windowHeight = Preference(
    key: 'window_height',
    defaultValue: 0.0,
  );

  static final windowX = Preference(key: 'window_x', defaultValue: 0.0);

  static final windowY = Preference(key: 'window_y', defaultValue: 0.0);

  static final syncPlayAdvancedCorrectionEnabled = Preference(
    key: 'syncplay_advanced_correction_enabled',
    defaultValue: true,
  );

  static final displayAudioLatest = Preference(
    key: 'pref_audio_display_latest',
    defaultValue: true,
  );

  static final displayAudioLastPlayed = Preference(
    key: 'pref_audio_display_last_played',
    defaultValue: true,
  );

  static final displayAudioFavorites = Preference(
    key: 'pref_audio_display_favorites',
    defaultValue: true,
  );

  static final displayAudioPlaylists = Preference(
    key: 'pref_audio_display_playlists',
    defaultValue: true,
  );

  static final displayAudioAlbumArtists = Preference(
    key: 'pref_audio_display_album_artists',
    defaultValue: true,
  );

  static final displayAudioArtists = Preference(
    key: 'pref_audio_display_artists',
    defaultValue: true,
  );

  static final displayAudioAlbums = Preference(
    key: 'pref_audio_display_albums',
    defaultValue: true,
  );

  static final audioSortOption = Preference<String>(
    key: 'pref_audio_sort_option',
    defaultValue: 'name',
  );

  // =========================================================================
  // Ported from Moonfin Core 2.4.0 - DEFINITIONS ONLY.
  //
  // Keys, defaults and enums are copied verbatim from upstream. Nothing in
  // this fork reads them yet: no settings UI, no consumer, no migration is
  // wired up for any of these. They exist so the corresponding features can
  // be ported incrementally without churning stored keys or defaults later.
  // =========================================================================

  // --- Home rows layout ---
  static final modernHomeRowsPadding = Preference<int>(
    key: 'pref_modern_home_rows_padding',
    defaultValue: 460,
  );

  static final classicHomeRowsPadding = Preference<int>(
    key: 'pref_classic_home_rows_padding',
    defaultValue: 30,
  );

  // --- Rewatch row ---
  static final displayRewatchRow = Preference(
    key: 'pref_display_rewatch_row',
    defaultValue: true,
  );

  static final rewatchSortBy = EnumPreference(
    key: 'pref_rewatch_sort_by',
    defaultValue: RewatchSortBy.recentlyWatched,
    values: RewatchSortBy.values,
  );

  static final rewatchIncludeMovies = Preference(
    key: 'pref_rewatch_include_movies',
    defaultValue: true,
  );

  static final rewatchIncludeShows = Preference(
    key: 'pref_rewatch_include_shows',
    defaultValue: true,
  );

  static final rewatchIncludeCollections = Preference(
    key: 'pref_rewatch_include_collections',
    defaultValue: true,
  );

  // --- Collections, playlists and recent rows ---
  static final collectionsRowShowEpisodes = Preference(
    key: 'pref_collections_row_show_episodes',
    defaultValue: false,
  );

  static final playlistsRowShowEpisodes = Preference(
    key: 'pref_playlists_row_show_episodes',
    defaultValue: false,
  );

  static final playlistsGroupByType = Preference(
    key: 'pref_playlists_group_by_type',
    defaultValue: true,
  );

  static final groupItemsIntoCollections = Preference(
    key: 'pref_group_items_into_collections',
    defaultValue: false,
  );

  static final mergeRecentRowsByType = Preference(
    key: 'pref_merge_recent_rows_by_type',
    defaultValue: false,
  );

  /// New in 2.5.0. Whether a "Recently released" row groups by the whole
  /// series, by season, or shows each new episode individually.
  static final recentlyReleasedSeriesType = EnumPreference(
    key: 'pref_recently_released_series_type',
    values: RecentlyReleasedSeriesType.values,
    defaultValue: RecentlyReleasedSeriesType.series,
  );

  static final nextUpMaxDays = Preference(
    key: 'pref_next_up_max_days',
    defaultValue: 365,
  );

  // --- First-run setup wizard (2.5.0) ---
  /// Tracks whether the first-run setup wizard has been completed for a given
  /// server+user, keyed so a second server is treated as a fresh set of
  /// libraries worth arranging, and kept out of the synced fields so a new
  /// device asks rather than inheriting somebody else's answer.
  static Preference<int> setupWizardVersionForServer(String serverKey) =>
      Preference(
        key: 'pref_setup_wizard_version_$serverKey',
        defaultValue: 0,
      );

  /// Bumped only when a release adds a step that earns its place. Everything
  /// already answered stays answered.
  static const setupWizardVersion = 1;

  // --- Detail screen ---
  /// Structural style for the media detail screen. Stored per server and user,
  /// because it syncs to that server's profile.
  static final detailScreenStyle = EnumPreference(
    key: 'pref_detail_screen_style',
    defaultValue: DetailScreenStyle.modern,
    values: DetailScreenStyle.values,
  );

  /// When on, the modern detail tabs behave like the search tabs: the first
  /// tab starts expanded and moving focus across tabs shows their content
  /// without pressing select. When off, tabs start collapsed on TV and each
  /// one is opened/closed by pressing it. Stored per server like [detailScreenStyle].
  static final detailExpandedTabs = Preference(
    key: 'pref_detail_expanded_tabs',
    defaultValue: true,
  );

  /// When on, the modern detail screen shows codec and stream technical details. Stored per
  /// server like [detailScreenStyle].
  static final detailShowTechnicalDetails = Preference(
    key: 'pref_detail_show_technical_details',
    defaultValue: false,
  );

  // --- Appearance: glass and OLED ---
  static final glassQuality = EnumPreference(
    key: 'pref_glass_quality',
    defaultValue: GlassQualityMode.auto,
    values: GlassQualityMode.values,
  );

  /// Settled quality of the adaptive glass renderer from the last session.
  /// Seeds GlassAdaptiveScope's initialQuality so repeat launches skip the
  /// warm-up benchmark. [GlassSettledQuality.unset] means benchmark again.
  static final glassSettledQuality = EnumPreference(
    key: 'pref_glass_settled_quality',
    defaultValue: GlassSettledQuality.unset,
    values: GlassSettledQuality.values,
  );

  /// Deepens chrome toward pure black and enriches artwork, on top of the
  /// selected theme. Off by default so no existing install changes look.
  static final oledMode = EnumPreference(
    key: 'pref_oled_mode',
    defaultValue: OledMode.off,
    values: OledMode.values,
  );

  // --- Library and navigation UI ---
  static final showAlphabeticalFilters = Preference(
    key: 'pref_show_alphabetical_filters',
    defaultValue: false,
  );

  static final navbarAlwaysExpanded = Preference(
    key: 'pref_navbar_always_expanded',
    defaultValue: false,
  );

  static final hideBackdropsInLibraries = Preference(
    key: 'pref_hide_backdrops_in_libraries',
    defaultValue: false,
  );

  // --- Live TV ---
  /// Default mobile view for the Live TV guide (Now/Next list vs compact grid).
  static final epgMobileView = EnumPreference(
    key: 'pref_epg_mobile_view',
    defaultValue: EpgMobileView.list,
    values: EpgMobileView.values,
  );

  static final liveTvChannelSortBy = EnumPreference(
    key: 'live_tv_channel_sort_by',
    defaultValue: ChannelSortBy.number,
    values: ChannelSortBy.values,
  );

  // --- Networking ---
  static final allowSelfSignedCerts = Preference(
    key: 'pref_allow_self_signed_certs',
    defaultValue: false,
  );

  // --- Cinema mode ---
  /// Off by default, because a preroll before every episode of a binge wears
  /// thin much faster than one before a film.
  static final cinemaModeEpisodesEnabled = Preference(
    key: 'pref_enable_cinema_mode_episodes',
    defaultValue: false,
  );

  // --- Playback OSD time slots ---
  static final playbackTimeAboveLeft = EnumPreference(
    key: 'playback_time_above_left',
    defaultValue: PlaybackTimeSlot.none,
    values: PlaybackTimeSlot.values,
  );

  static final playbackTimeAboveCenter = EnumPreference(
    key: 'playback_time_above_center',
    defaultValue: PlaybackTimeSlot.none,
    values: PlaybackTimeSlot.values,
  );

  static final playbackTimeAboveRight = EnumPreference(
    key: 'playback_time_above_right',
    defaultValue: PlaybackTimeSlot.none,
    values: PlaybackTimeSlot.values,
  );

  static final playbackTimeBelowLeft = EnumPreference(
    key: 'playback_time_below_left',
    defaultValue: PlaybackTimeSlot.elapsed,
    values: PlaybackTimeSlot.values,
  );

  static final playbackTimeBelowCenter = EnumPreference(
    key: 'playback_time_below_center',
    defaultValue: PlaybackTimeSlot.none,
    values: PlaybackTimeSlot.values,
  );

  static final playbackTimeBelowRight = EnumPreference(
    key: 'playback_time_below_right',
    defaultValue: PlaybackTimeSlot.totalDuration,
    values: PlaybackTimeSlot.values,
  );

  /// The music player has one label rather than six slots, so it picks a mode.
  static final musicPlaybackTimeDisplay = EnumPreference(
    key: 'music_playback_time_display',
    defaultValue: PlaybackTimeDisplay.totalDuration,
    values: PlaybackTimeDisplay.values,
  );

  // --- Audio ---
  static final audioPassthroughMode = EnumPreference(
    key: 'pref_audio_passthrough_mode',
    defaultValue: AudioPassthroughMode.auto,
    values: AudioPassthroughMode.values,
  );

  static final downmixToStereo = Preference(
    key: 'pref_downmix_to_stereo',
    defaultValue: false,
  );

  /// One-time flag: the old preset, output mode, and variant toggles have been
  /// folded into [audioPassthroughMode], [downmixToStereo], and the five base
  /// toggles.
  static final audioModeMigrated = Preference(
    key: 'pref_audio_passthrough_mode_migrated_v1',
    defaultValue: false,
  );

  static final fallbackAudioLanguage = Preference<String>(
    key: 'pref_fallback_audio_language',
    defaultValue: '',
  );

  static final preferDefaultAudioTrack = Preference<bool>(
    key: 'pref_prefer_default_audio_track',
    defaultValue: false,
  );

  static final preferAudioDescription = Preference<bool>(
    key: 'pref_prefer_audio_description',
    defaultValue: false,
  );

  // --- Subtitles ---
  static final subtitleMode = EnumPreference(
    key: 'pref_subtitle_mode',
    defaultValue: SubtitleMode.flagged,
    values: SubtitleMode.values,
  );

  static final fallbackSubtitleLanguage = Preference(
    key: 'pref_fallback_subtitle_language',
    defaultValue: '',
  );

  // --- Media segments ---
  static final mediaSegmentAutoHide = EnumPreference(
    key: 'pref_media_segment_auto_hide',
    defaultValue: MediaSegmentAutoHide.s5,
    values: MediaSegmentAutoHide.values,
  );

  // --- Queue and audiobooks ---
  static final resumeLastQueueOnPlay = Preference(
    key: 'pref_resume_last_queue_on_play',
    defaultValue: true,
  );

  static final audiobookDefaultSpeed = Preference(
    key: 'pref_audiobook_default_speed',
    defaultValue: 1.0,
  );

  static final audiobookSleepPresetMin = Preference(
    key: 'pref_audiobook_sleep_preset_min',
    defaultValue: 15,
  );

  static final audiobookExtendSleepTimer = Preference(
    key: 'pref_audiobook_extend_sleep_timer',
    defaultValue: false,
  );

  static final audiobookDrawerTab = Preference(
    key: 'pref_audiobook_drawer_tab',
    defaultValue: 'chapters',
  );

  // --- Media bar ---
  static final mediaBarTrailerCaptions = Preference(
    key: 'mediaBarTrailerCaptions',
    defaultValue: false,
  );

  // --- Theme music ---
  static final themeMusicLoop = Preference(
    key: 'themeMusicLoop',
    defaultValue: true,
  );

  // --- Player, window and image cache ---
  static final playerVolume = Preference(
    key: 'player_volume',
    defaultValue: 100.0,
  );

  static final windowFullscreen = Preference(
    key: 'window_fullscreen',
    defaultValue: false,
  );

  static final imageCacheLimitMb = Preference(
    key: 'image_cache_limit_mb',
    defaultValue: 350,
  );

  // --- Downloads ---
  static final legacyDownloadEngineServers = Preference(
    key: 'download_legacy_engine_servers',
    defaultValue: '',
  );

  static final reportDownloadsAsActivity = Preference(
    key: 'download_report_as_activity',
    defaultValue: true,
  );

  static final customDownloadPathBookmark = Preference(
    key: 'download_custom_path_bookmark',
    defaultValue: '',
  );

  // --- Person page ---
  static final personPageSortOption = Preference<String>(
    key: 'pref_person_page_sort_option',
    defaultValue: 'alphabetical',
  );

  static final personPageGroupItems = Preference<bool>(
    key: 'pref_person_page_group_items',
    defaultValue: false,
  );

  // --- Hidden home items ---
  static final hiddenContinueWatchingItems = Preference<String>(
    key: 'hidden_continue_watching_items',
    defaultValue: '{}',
  );

  static final hiddenNextUpSeries = Preference<String>(
    key: 'hidden_next_up_series',
    defaultValue: '{}',
  );

  // --- Interface style ---
  /// Which UI idiom the app adopts. [InterfaceStyle.automatic] resolves from
  /// the running platform; apple and material force one idiom everywhere. Read
  /// by [AppUiIdiomResolver]; see lib/util/idiom/app_ui_idiom.dart.
  static final interfaceStyle = EnumPreference(
    key: 'pref_interface_style',
    defaultValue: InterfaceStyle.automatic,
    values: InterfaceStyle.values,
  );

  // --- Detail screen and player OSD button layout ---
  // Comma separated button ids, kept per kind of device because a phone and a
  // TV want very different rows. The order preferences hold the arrangement
  // the user chose; the hidden preferences hold the ids switched off, so a
  // button added in a later release still shows up by default. Consumed by
  // [ButtonLayout]; see lib/preference/button_layout.dart.
  static final detailButtonOrderTv = Preference(
    key: 'detailButtonOrderTv',
    defaultValue: '',
  );
  static final detailButtonOrderMobile = Preference(
    key: 'detailButtonOrderMobile',
    defaultValue: '',
  );
  static final detailButtonOrderDesktop = Preference(
    key: 'detailButtonOrderDesktop',
    defaultValue: '',
  );
  static final osdButtonOrderTv = Preference(
    key: 'osdButtonOrderTv',
    defaultValue: '',
  );
  static final osdButtonOrderMobile = Preference(
    key: 'osdButtonOrderMobile',
    defaultValue: '',
  );
  static final osdButtonOrderDesktop = Preference(
    key: 'osdButtonOrderDesktop',
    defaultValue: '',
  );
  static final hiddenDetailButtonsTv = Preference(
    key: 'hiddenDetailButtonsTv',
    defaultValue: '',
  );
  static final hiddenDetailButtonsMobile = Preference(
    key: 'hiddenDetailButtonsMobile',
    defaultValue: '',
  );
  static final hiddenDetailButtonsDesktop = Preference(
    key: 'hiddenDetailButtonsDesktop',
    defaultValue: '',
  );
  static final hiddenOsdButtonsTv = Preference(
    key: 'hiddenOsdButtonsTv',
    defaultValue: '',
  );
  static final hiddenOsdButtonsMobile = Preference(
    key: 'hiddenOsdButtonsMobile',
    defaultValue: '',
  );
  static final hiddenOsdButtonsDesktop = Preference(
    key: 'hiddenOsdButtonsDesktop',
    defaultValue: '',
  );

  // --- Hidden home item filtering ---

  Map<String, String> getHiddenContinueWatchingItems() {
    try {
      final jsonStr = get(hiddenContinueWatchingItems);
      final map = jsonDecode(jsonStr) as Map;
      return map.cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  Future<void> hideFromContinueWatching(String id) async {
    final items = getHiddenContinueWatchingItems();
    items[id] = DateTime.now().toUtc().toIso8601String();
    await set(hiddenContinueWatchingItems, jsonEncode(items));
  }

  Future<void> unhideFromContinueWatching(String id) async {
    final items = getHiddenContinueWatchingItems();
    if (items.remove(id) != null) {
      await set(hiddenContinueWatchingItems, jsonEncode(items));
    }
  }

  Map<String, String> getHiddenNextUpSeries() {
    try {
      final jsonStr = get(hiddenNextUpSeries);
      final map = jsonDecode(jsonStr) as Map;
      return map.cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  Future<void> hideFromNextUp(String seriesId) async {
    final series = getHiddenNextUpSeries();
    series[seriesId] = DateTime.now().toUtc().toIso8601String();
    await set(hiddenNextUpSeries, jsonEncode(series));
  }

  Future<void> unhideFromNextUp(String seriesId) async {
    final series = getHiddenNextUpSeries();
    if (series.remove(seriesId) != null) {
      await set(hiddenNextUpSeries, jsonEncode(series));
    }
  }

  List<AggregatedItem> filterContinueWatching(List<AggregatedItem> items) {
    final hidden = getHiddenContinueWatchingItems();
    if (hidden.isEmpty) return items;
    final toRemove = <String>{};
    final result = <AggregatedItem>[];
    for (final item in items) {
      final id = item.id;
      final seriesId = item.seriesId;
      String? matchedKey;
      if (hidden.containsKey(id)) {
        matchedKey = id;
      } else if (seriesId != null && hidden.containsKey(seriesId)) {
        matchedKey = seriesId;
      }
      if (matchedKey != null) {
        final lastPlayedStr = item.rawData['UserData']?['LastPlayedDate'] as String?;
        if (lastPlayedStr != null && lastPlayedStr.isNotEmpty) {
          final lastPlayed = DateTime.tryParse(lastPlayedStr);
          final hiddenAt = DateTime.tryParse(hidden[matchedKey]!);
          if (lastPlayed != null && hiddenAt != null && lastPlayed.isAfter(hiddenAt)) {
            toRemove.add(matchedKey);
            result.add(item);
            continue;
          }
        }
        continue;
      }
      result.add(item);
    }
    if (toRemove.isNotEmpty) {
      unawaited(() async {
        final current = getHiddenContinueWatchingItems();
        var changed = false;
        for (final k in toRemove) { if (current.remove(k) != null) changed = true; }
        if (changed) await set(hiddenContinueWatchingItems, jsonEncode(current));
      }());
    }
    return result;
  }

  List<AggregatedItem> filterNextUp(List<AggregatedItem> items) {
    final hidden = getHiddenNextUpSeries();
    if (hidden.isEmpty) return items;
    final toRemove = <String>{};
    final result = <AggregatedItem>[];
    for (final item in items) {
      final seriesId = item.seriesId;
      if (seriesId != null && hidden.containsKey(seriesId)) {
        final lastPlayedStr = item.rawData['UserData']?['LastPlayedDate'] as String?;
        if (lastPlayedStr != null && lastPlayedStr.isNotEmpty) {
          final lastPlayed = DateTime.tryParse(lastPlayedStr);
          final hiddenAt = DateTime.tryParse(hidden[seriesId]!);
          if (lastPlayed != null && hiddenAt != null && lastPlayed.isAfter(hiddenAt)) {
            toRemove.add(seriesId);
            result.add(item);
            continue;
          }
        }
        continue;
      }
      result.add(item);
    }
    if (toRemove.isNotEmpty) {
      unawaited(() async {
        final current = getHiddenNextUpSeries();
        var changed = false;
        for (final k in toRemove) { if (current.remove(k) != null) changed = true; }
        if (changed) await set(hiddenNextUpSeries, jsonEncode(current));
      }());
    }
    return result;
  }

  bool _notificationsSuppressed = false;
  bool _notificationPending = false;

  @override
  void notifyListeners() {
    if (_notificationsSuppressed) {
      _notificationPending = true;
      return;
    }
    super.notifyListeners();
  }

  /// Temporarily suppresses notifyListeners until action completes, to apply
  /// a whole profile without notifying every listener once per key.
  Future<T> batchNotifications<T>(Future<T> Function() action) async {
    if (_notificationsSuppressed) return action();
    _notificationsSuppressed = true;
    try {
      return await action();
    } finally {
      _notificationsSuppressed = false;
      if (_notificationPending) {
        _notificationPending = false;
        super.notifyListeners();
      }
    }
  }

  /// When on, video details will pull trailers from YouTube. If false,
  /// they always play in-app. Stored per server like [detailScreenStyle].
  static final detailTrailersExternal = Preference(
    key: 'pref_detail_trailers_external',
    defaultValue: false,
  );

  /// New in 2.5.0. How a personal (user-entered, not critic) rating is
  /// displayed and collected on the details screen.
  static final personalRatingStyle = EnumPreference(
    key: 'pref_personal_rating_style',
    values: PersonalRatingStyle.values,
    defaultValue: PersonalRatingStyle.thumbs,
  );
}
