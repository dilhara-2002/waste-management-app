import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../utils/geo_helper.dart';
import '../services/routing_service.dart';
import 'segregation_guide.dart';

class ResidentHome extends StatefulWidget {
  const ResidentHome({super.key});

  @override
  State<ResidentHome> createState() => _ResidentHomeState();
}

class _ResidentHomeState extends State<ResidentHome> {
  int _currentIndex = 0;
  final _firestore = FirebaseFirestore.instance;
  Map<String, dynamic>? _userData;
  Map<String, dynamic>? _truckLocation;
  List<LatLng>? _routePoints;
  num? _routeDistance;
  num? _routeDuration;

  @override
  void initState() {
    super.initState();
    _loadUserData();
    _listenToTruckLocation();
  }

  Future<void> _loadUserData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final doc = await _firestore.collection('users').doc(user.uid).get();
      if (doc.exists && mounted) {
        setState(() {
          _userData = doc.data();
        });
        _fetchRoute(); // Fetch route when user data loads
      }
    }
  }

  Future<void> _fetchRoute() async {
    if (_userData?['latitude'] == null || _truckLocation == null) {
      setState(() {
        _routePoints = null;
        _routeDistance = null;
        _routeDuration = null;
      });
      return;
    }

    final userLat = _userData!['latitude'] as double;
    final userLon = _userData!['longitude'] as double;
    final truckLat = _truckLocation!['latitude'] as double;
    final truckLon = _truckLocation!['longitude'] as double;

    final route = await RoutingService.getRoute(
      LatLng(truckLat, truckLon),
      LatLng(userLat, userLon),
    );

    if (route != null && mounted) {
      setState(() {
        _routePoints = route['points'] as List<LatLng>;
        _routeDistance = route['distance'] as num;
        _routeDuration = route['duration'] as num;
      });
      debugPrint('🛣️ Route fetched: ${RoutingService.formatDistance(_routeDistance!)}, ${RoutingService.formatDuration(_routeDuration!)}');
    }
  }

  void _listenToTruckLocation() {
    _firestore.collection('truck_locations').snapshots().listen((snapshot) {
      if (snapshot.docs.isNotEmpty && mounted) {
        final data = snapshot.docs.first.data();
        final timestamp = data['timestamp'] as Timestamp?;
        
        debugPrint('🚛 Truck location received: lat=${data['latitude']}, lon=${data['longitude']}');
        
        // Only show truck if updated within last 60 seconds (active shift)
        if (timestamp != null) {
          final age = DateTime.now().difference(timestamp.toDate());
          debugPrint('🕐 Truck location age: ${age.inSeconds} seconds');
          
          if (age.inSeconds < 60) {
            debugPrint('✅ Showing truck on map');
            setState(() {
              _truckLocation = data;
            });
            _fetchRoute(); // Fetch route when truck location updates
            return;
          } else {
            debugPrint('⏰ Truck location too old (${(age.inHours)} hours), hiding');
            // Auto-delete very old locations (older than 1 hour)
            if (age.inHours > 1) {
              _firestore.collection('truck_locations').doc(snapshot.docs.first.id).delete();
              debugPrint('🗑️ Deleted stale truck location');
            }
          }
        } else {
          debugPrint('⚠️ No timestamp on truck location');
        }
      } else {
        debugPrint('📍 No truck locations in database');
      }
      
      // No recent truck location
      if (mounted) {
        setState(() {
          _truckLocation = null;
          _routePoints = null;
          _routeDistance = null;
          _routeDuration = null;
        });
      }
    });
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/');
    }
  }

  Future<void> _addDummyData() async {
    try {
      final batch = _firestore.batch();

      final schedules = [
        {
          'dayOfWeek': 'Monday',
          'wasteType': 'General Waste',
          'areaName': 'Colombo 3',
          'time': '08:00 AM',
          'createdAt': FieldValue.serverTimestamp(),
        },
        {
          'dayOfWeek': 'Tuesday',
          'wasteType': 'Recyclable',
          'areaName': 'Colombo 5',
          'time': '09:00 AM',
          'createdAt': FieldValue.serverTimestamp(),
        },
        {
          'dayOfWeek': 'Wednesday',
          'wasteType': 'General Waste',
          'areaName': 'Colombo 7',
          'time': '10:00 AM',
          'createdAt': FieldValue.serverTimestamp(),
        },
      ];

      for (var schedule in schedules) {
        final docRef = _firestore.collection('schedules').doc();
        batch.set(docRef, schedule);
      }

      await batch.commit();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ 3 dummy schedules added!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding data: $e')),
        );
      }
    }
  }

  Future<void> _showSetLocationDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Show loading dialog while getting GPS
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Getting your GPS location...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) Navigator.pop(context);
        throw Exception('Location services are disabled. Please enable GPS in settings.');
      }

      // Request location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) Navigator.pop(context);
          throw Exception('Location permissions are denied');
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) Navigator.pop(context);
        throw Exception('Location permissions are permanently denied');
      }

      // Get current GPS position with better settings
      debugPrint('🔄 Getting current GPS location...');
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        forceAndroidLocationManager: true,
        timeLimit: const Duration(seconds: 15),
      );
      
      debugPrint('✅ GPS fix: ${position.latitude}, ${position.longitude}, Accuracy: ${position.accuracy.toStringAsFixed(1)}m');

      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog

      // Show confirmation dialog with GPS location
      LatLng gpsPosition = LatLng(position.latitude, position.longitude);
      LatLng? confirmedPosition = await showDialog<LatLng>(
        context: context,
        builder: (context) => _LocationPickerDialog(gpsPosition: gpsPosition),
      );

      if (confirmedPosition != null) {
        await _firestore.collection('users').doc(user.uid).update({
          'latitude': confirmedPosition.latitude,
          'longitude': confirmedPosition.longitude,
          'locationUpdated': FieldValue.serverTimestamp(),
        });

        await _loadUserData();
        _fetchRoute(); // Fetch route after setting location

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Collection point saved!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // Close loading if still open
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error getting location: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Resident Portal'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Segregation Guide',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SegregationGuide(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: _currentIndex == 0 ? _buildScheduleTab() : _buildMapTab(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.calendar_today),
            label: 'Schedule',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.map),
            label: 'Live Tracker',
          ),
        ],
      ),
      floatingActionButton: _currentIndex == 0
          ? FloatingActionButton.extended(
              onPressed: _addDummyData,
              backgroundColor: Colors.orange,
              icon: const Icon(Icons.bug_report),
              label: const Text('DEBUG: Add Data'),
            )
          : null,
    );
  }

  Widget _buildMapTab() {
    return Stack(
      children: [
        _buildMap(),
        // Set Location Button
        Positioned(
          top: 16,
          right: 16,
          child: FloatingActionButton.extended(
            onPressed: _showSetLocationDialog,
            backgroundColor: Colors.blue,
            icon: const Icon(Icons.location_on),
            label: const Text('Set My Location'),
          ),
        ),
        // ETA Card
        if (_userData?['latitude'] != null && _truckLocation != null)
          _buildETACard(),
        // Location Not Set Warning
        if (_userData?['latitude'] == null)
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: Card(
              color: Colors.orange[100],
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.warning, color: Colors.orange[900]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Set your collection point to see ETA',
                        style: TextStyle(
                          color: Colors.orange[900],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMap() {
    List<Marker> markers = [];

    // Add truck marker if available
    if (_truckLocation != null) {
      final lat = _truckLocation!['latitude'] as double?;
      final lon = _truckLocation!['longitude'] as double?;
      if (lat != null && lon != null) {
        markers.add(
          Marker(
            point: LatLng(lat, lon),
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
                    'Truck',
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
    }

    // Add user's home marker if set
    if (_userData?['latitude'] != null && _userData?['longitude'] != null) {
      markers.add(
        Marker(
          point: LatLng(
            _userData!['latitude'] as double,
            _userData!['longitude'] as double,
          ),
          width: 80,
          height: 80,
          builder: (context) => Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'Home',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Icon(Icons.home, color: Colors.green, size: 32),
            ],
          ),
        ),
      );
    }

    LatLng centerPosition = const LatLng(6.9271, 79.8612);
    if (_userData?['latitude'] != null) {
      centerPosition = LatLng(
        _userData!['latitude'] as double,
        _userData!['longitude'] as double,
      );
    }

    return FlutterMap(
      options: MapOptions(
        center: centerPosition,
        zoom: 15.0,
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
                color: Colors.blue.withOpacity(0.7),
              ),
            ],
          ),
        MarkerLayer(markers: markers),
      ],
    );
  }

  Widget _buildETACard() {
    if (_userData?['latitude'] == null) {
      debugPrint('🏠 User location not set, hiding ETA');
      return const SizedBox.shrink();
    }
    
    if (_truckLocation == null) {
      debugPrint('🚛 No truck location, hiding ETA');
      return const SizedBox.shrink();
    }

    // Use OSRM route data if available, otherwise fallback to straight-line
    String distanceText;
    String etaText;
    
    if (_routeDistance != null && _routeDuration != null) {
      // Use OSRM routing data
      distanceText = RoutingService.formatDistance(_routeDistance!);
      
      // Get truck's current speed if available
      final truckSpeed = _truckLocation!['speed'] as num?;
      
      // Calculate dynamic ETA based on current speed
      final dynamicETA = RoutingService.calculateDynamicETA(
        routeDistance: _routeDistance!,
        routeDuration: _routeDuration!,
        currentSpeed: truckSpeed?.toDouble(),
      );
      
      etaText = RoutingService.formatDuration(dynamicETA);
      
      debugPrint('📊 ETA Card: distance=$distanceText, eta=$etaText, speed=${truckSpeed?.toStringAsFixed(1) ?? '?'} km/h');
    } else {
      // Fallback to straight-line calculation
      final userLat = _userData!['latitude'] as double;
      final userLon = _userData!['longitude'] as double;
      final truckLat = _truckLocation!['latitude'] as double;
      final truckLon = _truckLocation!['longitude'] as double;

      final distance = GeoHelper.calculateDistance(userLat, userLon, truckLat, truckLon);
      final eta = GeoHelper.calculateETA(distance);
      
      distanceText = GeoHelper.formatDistance(distance);
      etaText = GeoHelper.formatETA(eta);
      
      debugPrint('📊 ETA Card (fallback): distance=$distanceText, eta=$etaText');
    }

    return Positioned(
      bottom: 16,
      left: 16,
      right: 16,
      child: Card(
        color: Colors.white,
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.local_shipping, color: Colors.blue, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Truck is $distanceText away',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Approximate Arrival: $etaText',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.access_time,
                    color: (_routeDuration != null && _routeDuration! < 600) ? Colors.green : Colors.orange,
                    size: 28,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScheduleTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('schedules').snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 60, color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  'Error loading schedules',
                  style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                ),
              ],
            ),
          );
        }

        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.event_busy, size: 80, color: Colors.grey[400]),
                const SizedBox(height: 16),
                Text(
                  'No schedules available',
                  style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap the DEBUG button to add sample data',
                  style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                ),
              ],
            ),
          );
        }

        final schedules = snapshot.data!.docs;

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: schedules.length,
          itemBuilder: (context, index) {
            final schedule = schedules[index].data() as Map<String, dynamic>;
            final wasteType = schedule['wasteType'] ?? 'Unknown';
            final dayOfWeek = schedule['dayOfWeek'] ?? 'Unknown';
            final areaName = schedule['areaName'] ?? 'Unknown';
            final time = schedule['time'] ?? '';

            IconData wasteIcon;
            Color wasteColor;

            if (wasteType.toLowerCase().contains('recycl')) {
              wasteIcon = Icons.recycling;
              wasteColor = Colors.green;
            } else {
              wasteIcon = Icons.delete_outline;
              wasteColor = Colors.grey;
            }

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: CircleAvatar(
                  backgroundColor: wasteColor.withOpacity(0.2),
                  child: Icon(wasteIcon, color: wasteColor, size: 28),
                ),
                title: Text(
                  wasteType,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.calendar_today, size: 16, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text(dayOfWeek, style: const TextStyle(fontSize: 14)),
                          if (time.isNotEmpty) ...[
                            const SizedBox(width: 16),
                            const Icon(Icons.access_time, size: 16, color: Colors.grey),
                            const SizedBox(width: 4),
                            Text(time, style: const TextStyle(fontSize: 14)),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.location_on, size: 16, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text(areaName, style: const TextStyle(fontSize: 14)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// Location Confirmation Dialog with Manual Adjustment
class _LocationPickerDialog extends StatefulWidget {
  final LatLng gpsPosition;

  const _LocationPickerDialog({required this.gpsPosition});

  @override
  State<_LocationPickerDialog> createState() => _LocationPickerDialogState();
}

class _LocationPickerDialogState extends State<_LocationPickerDialog> {
  late LatLng _selectedPosition;
  bool _manuallyAdjusted = false;

  @override
  void initState() {
    super.initState();
    _selectedPosition = widget.gpsPosition;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.7,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  _manuallyAdjusted ? Icons.edit_location : Icons.gps_fixed,
                  color: _manuallyAdjusted ? Colors.orange : Colors.green,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _manuallyAdjusted ? 'Adjust Your Location' : 'Confirm GPS Location',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _manuallyAdjusted ? Colors.orange[50] : Colors.green[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _manuallyAdjusted ? Colors.orange[200]! : Colors.green[200]!,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    color: _manuallyAdjusted ? Colors.orange[700] : Colors.green[700],
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _manuallyAdjusted
                          ? 'Tap on the map to adjust your exact location'
                          : 'This is your GPS location. Tap the map to adjust it manually if needed.',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: FlutterMap(
                options: MapOptions(
                  center: _selectedPosition,
                  zoom: 17.0,
                  onTap: (tapPosition, point) {
                    setState(() {
                      _selectedPosition = point;
                      _manuallyAdjusted = true;
                    });
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.waste_management_app',
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _selectedPosition,
                        width: 60,
                        height: 60,
                        builder: (context) => Icon(
                          _manuallyAdjusted ? Icons.location_pin : Icons.my_location,
                          color: _manuallyAdjusted ? Colors.red : Colors.blue,
                          size: 50,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Coordinates:',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      if (_manuallyAdjusted)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.orange,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'ADJUSTED',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Lat: ${_selectedPosition.latitude.toStringAsFixed(6)}',
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                  Text(
                    'Lon: ${_selectedPosition.longitude.toStringAsFixed(6)}',
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (_manuallyAdjusted)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _selectedPosition = widget.gpsPosition;
                          _manuallyAdjusted = false;
                        });
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reset to GPS'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                if (_manuallyAdjusted) const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    label: const Text('Cancel'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.pop(context, _selectedPosition),
                    icon: const Icon(Icons.check_circle),
                    label: const Text('Confirm Location'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
