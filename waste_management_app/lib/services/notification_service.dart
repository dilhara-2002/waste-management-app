import 'package:cloud_firestore/cloud_firestore.dart';

/// Writes in-app notification documents to the `notifications` Firestore
/// collection. Residents whose `areaCode` matches will see the notification
/// in their Alerts tab.
class NotificationService {
  static final _firestore = FirebaseFirestore.instance;

  /// Sends a notification to all residents in [areaCode].
  /// [type] should be one of: 'shift_start', 'schedule_update', 'schedule_add'
  static Future<void> sendToArea({
    required String areaCode,
    required String title,
    required String body,
    required String type,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'areaCode': areaCode,
        'title': title,
        'body': body,
        'type': type,
        'read': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // Non-fatal: log but don't crash the calling flow
      // ignore: avoid_print
      print('NotificationService error: $e');
    }
  }

  /// Sends a notification to a specific resident identified by [userId].
  /// [type] should be one of: 'bin_collected', etc.
  static Future<void> sendToUser({
    required String userId,
    required String areaCode,
    required String title,
    required String body,
    required String type,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'userId': userId,
        'areaCode': areaCode,
        'title': title,
        'body': body,
        'type': type,
        'read': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // Non-fatal: log but don't crash the calling flow
      // ignore: avoid_print
      print('NotificationService sendToUser error: $e');
    }
  }
}
