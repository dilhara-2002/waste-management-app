import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:waste_management_app/firebase_options.dart';
import 'package:waste_management_app/main.dart';
import 'package:waste_management_app/screens/resident_home.dart';
import 'package:waste_management_app/screens/signup_screen.dart';
import 'package:waste_management_app/services/signup_access_code_service.dart';

void main() {
  test('signup code defaults and matching preserve existing behavior', () {
    expect(SignupAccessCodeType.collector.defaultCode, 'collector_2026');
    expect(SignupAccessCodeType.admin.defaultCode, 'WASTE_ADMIN_2024');
    expect(
      SignupAccessCodeType.collector.matches(
        ' COLLECTOR_2026 ',
        'collector_2026',
      ),
      isTrue,
    );
    expect(
      SignupAccessCodeType.admin.matches(
        'WASTE_ADMIN_2024',
        'WASTE_ADMIN_2024',
      ),
      isTrue,
    );
    expect(
      SignupAccessCodeType.admin.matches(
        'waste_admin_2024',
        'WASTE_ADMIN_2024',
      ),
      isFalse,
    );
  });

  test('resident access codes normalize only the supported range', () {
    expect(SignUpScreen.normalizeResidentAccessCode('R/001'), 'R001');
    expect(SignUpScreen.normalizeResidentAccessCode('r/100'), 'R100');
    expect(SignUpScreen.normalizeResidentAccessCode('R/000'), isNull);
    expect(SignUpScreen.normalizeResidentAccessCode('R/101'), isNull);
    expect(SignUpScreen.normalizeResidentAccessCode('R//001'), isNull);
  });

  testWidgets('app launches', (WidgetTester tester) async {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await tester.pumpWidget(const MyApp());
    expect(find.byType(MyApp), findsOneWidget);
  });

  test(
    'resident location helpers update and remove the saved coordinate pair',
    () {
      final update = ResidentHome.buildLocationUpdatePayload(
        const LatLng(6.9271, 79.8612),
      );

      expect(update['latitude'], 6.9271);
      expect(update['longitude'], 79.8612);
      expect(update['locationUpdated'], isA<FieldValue>());

      final remove = ResidentHome.buildLocationRemovalPayload();
      expect(remove['latitude'], isA<FieldValue>());
      expect(remove['longitude'], isA<FieldValue>());
      expect(remove['locationUpdated'], isA<FieldValue>());
    },
  );

  test(
    'resident schedule date index resolves correctly for a 35-day strip',
    () {
      final stripStartDate = DateTime(2026, 8, 1);
      final selectedDate = DateTime(2026, 8, 5);

      final index = selectedDate.difference(stripStartDate).inDays;
      expect(index, 4);
    },
  );
}
