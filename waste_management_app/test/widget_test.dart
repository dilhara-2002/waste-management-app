import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:waste_management_app/firebase_options.dart';
import 'package:waste_management_app/main.dart';
import 'package:waste_management_app/screens/resident_home.dart';

void main() {
  testWidgets('app launches', (WidgetTester tester) async {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    await tester.pumpWidget(const MyApp());
    expect(find.byType(MyApp), findsOneWidget);
  });

  test('resident location helpers update and remove the saved coordinate pair', () {
    final update = ResidentHome.buildLocationUpdatePayload(const LatLng(6.9271, 79.8612));

    expect(update['latitude'], 6.9271);
    expect(update['longitude'], 79.8612);
    expect(update['locationUpdated'], isA<FieldValue>());

    final remove = ResidentHome.buildLocationRemovalPayload();
    expect(remove['latitude'], isA<FieldValue>());
    expect(remove['longitude'], isA<FieldValue>());
    expect(remove['locationUpdated'], isA<FieldValue>());
  });
}
