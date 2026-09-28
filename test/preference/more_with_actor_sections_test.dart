import 'package:flutter_test/flutter_test.dart';
import 'package:voltix/preference/home_section_config.dart';
import 'package:voltix/preference/preference_constants.dart';
import 'package:voltix/preference/user_preferences.dart';

void main() {
  group('More with [Actor] HomeSectionType & Config Tests', () {
    test('HomeSectionType serialization and deserialization', () {
      expect(HomeSectionType.moreWithActor1.serializedName, 'morewithactor1');
      expect(HomeSectionType.moreWithActor2.serializedName, 'morewithactor2');
      expect(HomeSectionType.moreWithActor3.serializedName, 'morewithactor3');

      expect(HomeSectionType.fromSerialized('morewithactor1'), HomeSectionType.moreWithActor1);
      expect(HomeSectionType.fromSerialized('morewithactor2'), HomeSectionType.moreWithActor2);
      expect(HomeSectionType.fromSerialized('morewithactor3'), HomeSectionType.moreWithActor3);
    });

    test('default HomeSectionsConfig includes moreWithActor1..3', () {
      final defaults = HomeSectionConfig.defaults();
      final actor1 = defaults.firstWhere((c) => c.type == HomeSectionType.moreWithActor1);
      final actor2 = defaults.firstWhere((c) => c.type == HomeSectionType.moreWithActor2);
      final actor3 = defaults.firstWhere((c) => c.type == HomeSectionType.moreWithActor3);

      expect(actor1.enabled, isTrue);
      expect(actor2.enabled, isTrue);
      expect(actor3.enabled, isTrue);
      expect(actor1.isBuiltin, isTrue);
    });

    test('HomeSectionConfig toJson and fromJson roundtrip', () {
      const config = HomeSectionConfig(
        type: HomeSectionType.moreWithActor1,
        enabled: true,
        order: 42,
      );

      final json = config.toJson();
      expect(json['type'], 'morewithactor1');
      expect(json['enabled'], isTrue);
      expect(json['order'], 42);

      final restored = HomeSectionConfig.fromJson(json);
      expect(restored.type, HomeSectionType.moreWithActor1);
      expect(restored.enabled, isTrue);
      expect(restored.order, 42);
    });

    test('MoreWithActorNumRows enum values', () {
      expect(MoreWithActorNumRows.one.value, 1);
      expect(MoreWithActorNumRows.two.value, 2);
      expect(MoreWithActorNumRows.three.value, 3);

      expect(MoreWithActorNumRows.one.displayName, '1');
      expect(MoreWithActorNumRows.two.displayName, '2');
      expect(MoreWithActorNumRows.three.displayName, '3');
    });

    test('UserPreferences preference declarations', () {
      expect(UserPreferences.displayMoreWithActorRows.defaultValue, isTrue);
      expect(UserPreferences.moreWithActor1Enabled.defaultValue, isTrue);
      expect(UserPreferences.moreWithActor2Enabled.defaultValue, isTrue);
      expect(UserPreferences.moreWithActor3Enabled.defaultValue, isTrue);
      expect(UserPreferences.moreWithActorNumRows.defaultValue, MoreWithActorNumRows.three);
      expect(UserPreferences.moreWithActorIncludeWatched.defaultValue, isFalse);
    });
  });
}
