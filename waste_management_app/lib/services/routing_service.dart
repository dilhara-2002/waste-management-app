import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class RoutingService {
  static const String _osrmBaseUrl = 'https://router.project-osrm.org/route/v1/driving';

  /// Fetch route from OSRM API
  /// Returns: {distance: meters, duration: seconds, points: List<LatLng>}
  static Future<Map<String, dynamic>?> getRoute(
    LatLng start,
    LatLng end,
  ) async {
    try {
      final url = Uri.parse(
        '$_osrmBaseUrl/${start.longitude},${start.latitude};${end.longitude},${end.latitude}'
        '?overview=full&geometries=geojson',
      );

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 'Ok' && data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final geometry = route['geometry']['coordinates'] as List;

          // Convert coordinates to LatLng
          final points = geometry.map((coord) {
            return LatLng(coord[1] as double, coord[0] as double);
          }).toList();

          return {
            'distance': route['distance'] as num, // meters
            'duration': route['duration'] as num, // seconds
            'points': points,
          };
        }
      }
      return null;
    } catch (e) {
      print('Error fetching route: $e');
      return null;
    }
  }

  /// Format distance in human-readable format
  static String formatDistance(num meters) {
    if (meters < 1000) {
      return '${meters.round()} m';
    } else {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
  }

  /// Format duration in human-readable format
  static String formatDuration(num seconds) {
    final minutes = (seconds / 60).round();
    if (minutes < 60) {
      return '$minutes min${minutes != 1 ? 's' : ''}';
    } else {
      final hours = minutes ~/ 60;
      final remainingMinutes = minutes % 60;
      if (remainingMinutes == 0) {
        return '$hours hr${hours != 1 ? 's' : ''}';
      }
      return '$hours hr${hours != 1 ? 's' : ''} $remainingMinutes min${remainingMinutes != 1 ? 's' : ''}';
    }
  }

  /// Calculate speed from distance and time
  static double calculateSpeed(num distanceMeters, num durationSeconds) {
    if (durationSeconds == 0) return 0;
    // Returns km/h
    return (distanceMeters / 1000) / (durationSeconds / 3600);
  }

  /// Calculate ETA based on current speed and remaining distance
  /// If speed is 0 or null, uses OSRM's estimated duration
  static num calculateDynamicETA({
    required num routeDistance,
    required num routeDuration,
    num? currentSpeed, // km/h
  }) {
    if (currentSpeed == null || currentSpeed < 5) {
      // Use OSRM's estimate if truck is stopped or moving very slowly
      return routeDuration;
    }

    // Calculate based on current speed
    final speedMps = currentSpeed / 3.6; // Convert km/h to m/s
    return routeDistance / speedMps; // seconds
  }
}
