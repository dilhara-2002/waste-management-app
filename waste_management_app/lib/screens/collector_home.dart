import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import '../services/routing_service.dart';

class CollectorHome extends StatefulWidget {
  const CollectorHome({super.key});

  @override
  State<CollectorHome> createState() => _CollectorHomeState();
}

class _CollectorHomeState extends State<CollectorHome> {
  bool _isOnShift = false;
  Timer? _locationTimer;
  final _firestore = FirebaseFirestore.instance;
  Position? _currentPosition;
  Position? _previousPosition;
  double _currentSpeed = 0.0; // km/h
  List<LatLng>? _routePoints;
  Map<String, dynamic>? _selectedResident;

  @override
  void dispose() {
    _locationTimer?.cancel();
    super.dispose();
  }

  Future<void> _logout() async {
    if (_isOnShift) {
      await _stopShift();
    }
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/');
    }
  }

  Future<void> _toggleShift() async {
    if (_isOnShift) {
      await _stopShift();
    } else {
      await _startShift();
    }
  }

  Future<void> _startShift() async {
    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are disabled. Please enable GPS.');
      }

      // Request location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw Exception('Location permissions are denied');
        }
      }

      if (permission == LocationPermission.deniedForever) {
        throw Exception('Location permissions are permanently denied');
      }

      setState(() {
        _isOnShift = true;
      });

      // Start broadcasting location every 10 seconds
      _locationTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
        try {
          Position position = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
            forceAndroidLocationManager: true, // Force GPS instead of network location
            timeLimit: const Duration(seconds: 8), // Timeout after 8 seconds
          );

          // Calculate speed if we have a previous position
          double speed = 0.0;
          if (_previousPosition != null) {
            final distance = Geolocator.distanceBetween(
              _previousPosition!.latitude,
              _previousPosition!.longitude,
              position.latitude,
              position.longitude,
            ); // meters
            final timeDiff = position.timestamp.difference(_previousPosition!.timestamp).inSeconds;
            if (timeDiff > 0) {
              speed = (distance / timeDiff) * 3.6; // Convert m/s to km/h
            }
          }

          setState(() {
            _previousPosition = _currentPosition;
            _currentPosition = position;
            _currentSpeed = speed;
          });

          await _firestore.collection('truck_locations').doc('truck_1').set({
            'latitude': position.latitude,
            'longitude': position.longitude,
            'timestamp': FieldValue.serverTimestamp(),
            'accuracy': position.accuracy,
            'speed': speed, // km/h
          });

          debugPrint('📍 Location: ${position.latitude}, ${position.longitude}, Speed: ${speed.toStringAsFixed(1)} km/h, Accuracy: ${position.accuracy.toStringAsFixed(1)}m');
        } catch (e) {
          debugPrint('Error updating location: $e');
        }
      });

      // Also send initial location immediately - with retry logic
      debugPrint('🔄 Getting initial GPS location...');
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        forceAndroidLocationManager: true,
        timeLimit: const Duration(seconds: 15), // Longer timeout for first fix
      );
      setState(() {
        _currentPosition = position;
        _previousPosition = position;
        _currentSpeed = 0.0;
      });
      
      debugPrint('✅ Initial GPS fix: ${position.latitude}, ${position.longitude}, Accuracy: ${position.accuracy.toStringAsFixed(1)}m');
      
      await _firestore.collection('truck_locations').doc('truck_1').set({
        'latitude': position.latitude,
        'longitude': position.longitude,
        'timestamp': FieldValue.serverTimestamp(),
        'accuracy': position.accuracy,
        'speed': 0.0,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Shift started - Broadcasting location'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isOnShift = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error starting shift: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _stopShift() async {
    _locationTimer?.cancel();
    
    // Delete truck location from Firestore
    try {
      await _firestore.collection('truck_locations').doc('truck_1').delete();
    } catch (e) {
      debugPrint('Error deleting truck location: $e');
    }
    
    setState(() {
      _isOnShift = false;
      _currentPosition = null;
      _previousPosition = null;
      _currentSpeed = 0.0;
      _routePoints = null;
      _selectedResident = null;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🛑 Shift ended'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Future<void> _navigateToLocation(double lat, double lon, String address) async {
    final url = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lon');
    
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open Google Maps'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showPickupDialog(Map<String, dynamic> resident) async {
    final lat = resident['latitude'] as double?;
    final lon = resident['longitude'] as double?;
    final email = resident['email'] as String? ?? 'No email';

    if (lat == null || lon == null || _currentPosition == null) return;

    // Fetch route
    final route = await RoutingService.getRoute(
      LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
      LatLng(lat, lon),
    );

    if (!mounted) return;

    // Show route on map
    if (route != null) {
      setState(() {
        _routePoints = route['points'] as List<LatLng>;
        _selectedResident = resident;
      });
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.delete, color: Colors.green),
            SizedBox(width: 8),
            Text('Pickup Point'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Resident: $email'),
            const SizedBox(height: 8),
            if (route != null) ...[
              Row(
                children: [
                  const Icon(Icons.route, size: 16, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    'Distance: ${RoutingService.formatDistance(route['distance'] as num)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.access_time, size: 16, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    'Time: ${RoutingService.formatDuration(route['duration'] as num)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ] else
              const Text('Calculating route...'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _routePoints = null;
                _selectedResident = null;
              });
            },
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _navigateToLocation(lat, lon, email);
              setState(() {
                _routePoints = null;
                _selectedResident = null;
              });
            },
            icon: const Icon(Icons.navigation),
            label: const Text('Navigate'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Collector Portal'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: Column(
        children: [
          // Control Panel
          Container(
            padding: const EdgeInsets.all(16),
            color: _isOnShift ? Colors.green[50] : Colors.grey[100],
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      _isOnShift ? Icons.check_circle : Icons.circle_outlined,
                      color: _isOnShift ? Colors.green : Colors.grey,
                      size: 32,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isOnShift ? 'On Shift' : 'Off Shift',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            _isOnShift
                                ? 'Broadcasting location every 10 seconds'
                                : 'Tap the button below to start your shift',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[700],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _toggleShift,
                    icon: Icon(_isOnShift ? Icons.stop : Icons.play_arrow),
                    label: Text(_isOnShift ? 'Stop Shift' : 'Start Shift'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isOnShift ? Colors.red : Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      textStyle: const TextStyle(fontSize: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Map View with Pickup Points
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _firestore
                  .collection('users')
                  .where('role', isEqualTo: 'resident')
                  .snapshots(),
              builder: (context, snapshot) {
                List<Map<String, dynamic>> residents = [];
                
                if (snapshot.hasData) {
                  residents = snapshot.data!.docs
                      .map((doc) => doc.data() as Map<String, dynamic>)
                      .where((data) =>
                          data['latitude'] != null && data['longitude'] != null)
                      .toList();
                }

                // Always show map even if loading or no residents
                return Stack(
                  children: [
                    _buildMap(residents),
                    if (snapshot.connectionState == ConnectionState.waiting)
                      const Center(
                        child: CircularProgressIndicator(),
                      ),
                    if (snapshot.hasData && residents.isEmpty && !_isOnShift)
                      Center(
                        child: Card(
                          margin: const EdgeInsets.all(16),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.info_outline, size: 48, color: Colors.grey[400]),
                                const SizedBox(height: 12),
                                const Text(
                                  'No pickup points yet',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Residents will appear here once they set their location',
                                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMap(List<Map<String, dynamic>> residents) {
    List<Marker> markers = [];

    // Add truck marker if on shift
    if (_isOnShift && _currentPosition != null) {
      markers.add(
        Marker(
          point: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
          width: 100,
          height: 100,
          builder: (context) => Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blue,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'You',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Icon(Icons.local_shipping, color: Colors.blue, size: 40),
            ],
          ),
        ),
      );
    }

    // Add resident pickup markers
    for (var resident in residents) {
      final lat = resident['latitude'] as double;
      final lon = resident['longitude'] as double;
      final email = resident['email'] as String? ?? 'Resident';

      markers.add(
        Marker(
          point: LatLng(lat, lon),
          width: 80,
          height: 80,
          builder: (context) => GestureDetector(
            onTap: () => _showPickupDialog(resident),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    email.split('@').first,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.delete, color: Colors.green, size: 32),
              ],
            ),
          ),
        ),
      );
    }

    LatLng center = const LatLng(6.9271, 79.8612); // Default to Colombo
    if (_currentPosition != null) {
      center = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
    } else if (residents.isNotEmpty) {
      center = LatLng(
        residents.first['latitude'] as double,
        residents.first['longitude'] as double,
      );
    }

    return FlutterMap(
      options: MapOptions(
        center: center,
        zoom: 14.0,
        minZoom: 5.0,
        maxZoom: 18.0,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.waste_management_app',
          maxZoom: 19,
        ),
        // Route polyline if available
        if (_routePoints != null && _routePoints!.isNotEmpty)
          PolylineLayer(
            polylines: [
              Polyline(
                points: _routePoints!,
                strokeWidth: 4.0,
                color: Colors.blue,
              ),
            ],
          ),
        MarkerLayer(markers: markers),
      ],
    );
  }
}
