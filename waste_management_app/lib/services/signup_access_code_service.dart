import 'package:cloud_firestore/cloud_firestore.dart';

enum SignupAccessCodeType {
  collector('collector', 'Collector', 'collector_2026', true),
  admin('admin', 'Admin', 'WASTE_ADMIN_2024', false);

  const SignupAccessCodeType(
    this.fieldName,
    this.label,
    this.defaultCode,
    this.caseInsensitive,
  );

  final String fieldName;
  final String label;
  final String defaultCode;
  final bool caseInsensitive;

  bool matches(String enteredCode, String expectedCode) {
    final entered = enteredCode.trim();
    final expected = expectedCode.trim();
    return caseInsensitive
        ? entered.toLowerCase() == expected.toLowerCase()
        : entered == expected;
  }
}

class SignupAccessCodeService {
  static DocumentReference<Map<String, dynamic>> _configReference(
    FirebaseFirestore firestore,
  ) => firestore.collection('signup_access_codes').doc('config');

  static Future<String> getCode(
    FirebaseFirestore firestore,
    SignupAccessCodeType type,
  ) async {
    final snapshot = await _configReference(firestore).get();
    final code = snapshot.data()?[type.fieldName];
    if (code is String && code.trim().isNotEmpty) return code.trim();
    return type.defaultCode;
  }

  static Future<void> updateCode({
    required FirebaseFirestore firestore,
    required SignupAccessCodeType type,
    required String existingCode,
    required String newCode,
  }) async {
    final configReference = _configReference(firestore);
    await firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(configReference);
      final storedCode = snapshot.data()?[type.fieldName];
      final currentCode = storedCode is String && storedCode.trim().isNotEmpty
          ? storedCode.trim()
          : type.defaultCode;

      if (!type.matches(existingCode, currentCode)) {
        throw const SignupAccessCodeChangedException();
      }

      transaction.set(configReference, {
        type.fieldName: newCode.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  }
}

class SignupAccessCodeChangedException implements Exception {
  const SignupAccessCodeChangedException();
}
