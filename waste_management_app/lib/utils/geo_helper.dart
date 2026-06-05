import 'dart:math';

class GeoHelper {
  /// Calculate distance between two points in kilometers using Haversine formula
  static double calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadius = 6371; // Earth's radius in kilometers

    // Convert degrees to radians
    double dLat = _toRadians(lat2 - lat1);
    double dLon = _toRadians(lon2 - lon1);

    double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) *
            cos(_toRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);

    double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    double distance = earthRadius * c;

    return distance;
  }

  /// Convert degrees to radians
  static double _toRadians(double degrees) {
    return degrees * pi / 180;
  }

  /// Calculate ETA in minutes based on distance and average speed
  static int calculateETA(double distanceKm, {double averageSpeedKmh = 30}) {
    if (distanceKm <= 0) return 0;
    double timeInHours = distanceKm / averageSpeedKmh;
    int timeInMinutes = (timeInHours * 60).round();
    return timeInMinutes;
  }

  /// Format distance for display
  static String formatDistance(double distanceKm) {
    if (distanceKm < 1) {
      return '${(distanceKm * 1000).round()} m';
    } else {
      return '${distanceKm.toStringAsFixed(1)} km';
    }
  }

  /// Format ETA for display
  static String formatETA(int minutes) {
    if (minutes < 1) {
      return 'Less than 1 min';
    } else if (minutes < 60) {
      return '$minutes min${minutes > 1 ? 's' : ''}';
    } else {
      int hours = minutes ~/ 60;
      int mins = minutes % 60;
      return '$hours hr${hours > 1 ? 's' : ''} ${mins > 0 ? '$mins min${mins > 1 ? 's' : ''}' : ''}';
    }
  }
}
