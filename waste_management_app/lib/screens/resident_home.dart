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
  int _notificationFilterIndex = 0; // 0: All, 1: Reminders, 2: Updates, 3: Alerts

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
    // Listen to the specific truck document written by collectors ('truck_1')
    final docRef = _firestore.collection('truck_locations').doc('truck_1');
    docRef.snapshots().listen((snapshot) {
      if (snapshot.exists && mounted) {
        final data = snapshot.data();
        if (data == null) return;

        final timestamp = data['timestamp'] as Timestamp?;
        debugPrint('🚛 Truck location received: lat=${data['latitude']}, lon=${data['longitude']}');

        if (timestamp != null) {
          final age = DateTime.now().difference(timestamp.toDate());
          debugPrint('🕐 Truck location age: ${age.inSeconds} seconds');

          if (age.inSeconds < 60) {
            debugPrint('✅ Showing truck on map');
            setState(() {
              _truckLocation = data;
            });
            _fetchRoute();
            return;
          } else {
            debugPrint('⏰ Truck location too old (${age.inHours} hours), hiding');
            if (age.inHours > 1) {
              // Cleanup stale document
              docRef.delete();
              debugPrint('🗑️ Deleted stale truck location');
            }
          }
        } else {
          debugPrint('⚠️ No timestamp on truck location');
        }
      } else {
        debugPrint('📍 No truck location document');
      }

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

  void _showProfileSheet() {
    final user = FirebaseAuth.instance.currentUser;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: SafeArea(
            child: Wrap(
              children: [
                ListTile(
                  title: const Text('Profile', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.email_outlined),
                  title: const Text('Email'),
                  subtitle: Text(user?.email ?? _userData?['email'] ?? 'Not set'),
                ),
                ListTile(
                  leading: const Icon(Icons.home_outlined),
                  title: const Text('Address'),
                  subtitle: Text(_userData?['address'] ?? (_userData?['latitude'] != null ? 'Lat: ${_userData!['latitude']}, Lon: ${_userData!['longitude']}' : 'Not set')),
                  trailing: TextButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      await _showSetLocationDialog();
                    },
                    child: const Text('Edit'),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('Password'),
                  subtitle: const Text('Change or reset your password'),
                  trailing: TextButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      final email = user?.email ?? _userData?['email'];
                      if (email == null) {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No email available to send reset link')));
                        return;
                      }
                      try {
                        await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password reset email sent')));
                      } catch (e) {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error sending reset email: $e')));
                      }
                    },
                    child: const Text('Reset'),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('Logout'),
                  onTap: () async {
                    Navigator.pop(context);
                    await _logout();
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // New layout: Home | Map | Schedule | Report | Alerts
    return Scaffold(
      backgroundColor: Colors.grey[50],
      body: SafeArea(
        child: Column(
          children: [
            // Top header matching Figma style
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Colors.green.shade700, Colors.green.shade400]),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(20),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Hello', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
                        Text('What can we do for you?', style: TextStyle(color: Colors.white.withOpacity(0.9))),
                      ],
                    ),
                  ),
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: Colors.white,
                    child: IconButton(
                      icon: const Icon(Icons.person, color: Colors.green),
                      onPressed: _showProfileSheet,
                    ),
                  ),
                ],
              ),
            ),

            // Expanded content area switching by index
            Expanded(
              child: IndexedStack(
                index: _currentIndex,
                children: [
                  _buildHomeTab(),
                  _buildMapTab(),
                  _buildScheduleTab(),
                  _buildReportTab(),
                  _buildAlertsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.green[700],
        unselectedItemColor: Colors.grey[600],
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_outlined), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.map_outlined), label: 'Map'),
          BottomNavigationBarItem(icon: Icon(Icons.calendar_today_outlined), label: 'Schedule'),
          BottomNavigationBarItem(icon: Icon(Icons.article_outlined), label: 'Report'),
          BottomNavigationBarItem(icon: Icon(Icons.notifications_outlined), label: 'Alerts'),
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

  // HOME tab: upcoming collection card + quick actions + tips
  Widget _buildHomeTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Quick actions row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _quickAction(Icons.calendar_today, 'Schedule', () {
                setState(() => _currentIndex = 2);
              }),
              _quickAction(Icons.report_gmailerrorred, 'Report Missed Pickup', () {
                Navigator.pushNamed(context, '/login');
              }),
              _quickAction(Icons.menu_book, 'Segregation Guide', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SegregationGuide()),
                );
              }),
            ],
          ),
          const SizedBox(height: 18),

          const Text('Upcoming Collection', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.green[50], borderRadius: BorderRadius.circular(8)),
                child: const Text('Oct\n24', textAlign: TextAlign.center, style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
              ),
              title: const Text('Domestic Waste', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Tomorrow, 08:00 AM - 10:00 AM'),
              trailing: const Icon(Icons.local_shipping),
            ),
          ),

          const SizedBox(height: 18),
          const Text('Waste Segregation Tips', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SizedBox(
            height: 110,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _tipCard('1', 'Plastic', Colors.blue),
                const SizedBox(width: 12),
                _tipCard('2', 'Paper', Colors.orange),
                const SizedBox(width: 12),
                _tipCard('3', 'Glass', Colors.green),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickAction(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.green[700]),
                const SizedBox(height: 8),
                Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tipCard(String number, String title, Color color) {
    return Container(
      width: 160,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(radius: 14, backgroundColor: color.withOpacity(0.1), child: Text(number, style: TextStyle(color: color, fontWeight: FontWeight.bold))),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text('Short tip description goes here', style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  // REPORT tab placeholder
  Widget _buildReportTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.report, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 12),
          const Text('Report an issue', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Use this screen to submit missed pickups or service requests.'),
        ],
      ),
    );
  }

  // ALERTS / Notifications tab
  Widget _buildAlertsTab() {
    // Notifications screen with filter chips
    final filters = ['All', 'Reminders', 'Updates', 'Alerts'];

    Future<void> _markAllRead(QuerySnapshot snapshot) async {
      final batch = _firestore.batch();
      for (var doc in snapshot.docs) {
        batch.update(doc.reference, {'read': true});
      }
      await batch.commit();
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text('Notifications', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              ),
              TextButton.icon(
                onPressed: () async {
                  final snap = await _firestore.collection('notifications').get();
                  await _markAllRead(snap);
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Marked all read')));
                },
                icon: const Icon(Icons.check, color: Colors.green),
                label: const Text('Mark all read', style: TextStyle(color: Colors.green)),
              ),
            ],
          ),
        ),

        // Filter chips
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: List.generate(filters.length, (i) {
              final selected = i == _notificationFilterIndex;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(filters[i]),
                  selected: selected,
                  onSelected: (_) {
                    setState(() {
                      _notificationFilterIndex = i;
                    });
                  },
                  selectedColor: Colors.green[400],
                  backgroundColor: Colors.grey[200],
                  labelStyle: TextStyle(color: selected ? Colors.white : Colors.black),
                ),
              );
            }),
          ),
        ),

        const Divider(height: 1),

        // Notifications list
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: _firestore.collection('notifications').orderBy('createdAt', descending: true).snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return Center(child: Text('No notifications', style: TextStyle(color: Colors.grey[600])));
              }

              final docs = snapshot.data!.docs.where((d) {
                if (_notificationFilterIndex == 0) return true;
                final type = (d.data() as Map<String, dynamic>)['type']?.toString().toLowerCase() ?? '';
                if (_notificationFilterIndex == 1) return type.contains('remind') || type == 'reminder';
                if (_notificationFilterIndex == 2) return type.contains('update');
                if (_notificationFilterIndex == 3) return type.contains('alert');
                return true;
              }).toList();

              if (docs.isEmpty) {
                return Center(child: Text('No notifications', style: TextStyle(color: Colors.grey[600])));
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                itemBuilder: (context, index) {
                  final data = docs[index].data() as Map<String, dynamic>;
                  final title = data['title'] ?? 'Notification';
                  final body = data['body'] ?? '';
                  final type = data['type']?.toString().toLowerCase() ?? '';
                  final createdAt = data['createdAt'] as Timestamp?;

                  Color leftColor = Colors.grey;
                  IconData icon = Icons.notifications;
                  if (type.contains('remind') || type == 'reminder') {
                    leftColor = Colors.green;
                    icon = Icons.local_shipping;
                  } else if (type.contains('update')) {
                    leftColor = Colors.purple;
                    icon = Icons.check_circle;
                  } else if (type.contains('alert')) {
                    leftColor = Colors.orange;
                    icon = Icons.warning_amber_rounded;
                  }

                  String timeText = '';
                  if (createdAt != null) {
                    final dt = createdAt.toDate();
                    final diff = DateTime.now().difference(dt);
                    if (diff.inDays >= 1) {
                      timeText = '${dt.month}/${dt.day}/${dt.year}';
                    } else if (diff.inHours >= 1) {
                      timeText = '${diff.inHours}h ago';
                    } else if (diff.inMinutes >= 1) {
                      timeText = '${diff.inMinutes}m ago';
                    } else {
                      timeText = 'just now';
                    }
                  }

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        Container(width: 6, height: 84, decoration: BoxDecoration(color: leftColor, borderRadius: BorderRadius.circular(6))),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Card(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            child: ListTile(
                              leading: CircleAvatar(backgroundColor: leftColor.withOpacity(0.12), child: Icon(icon, color: leftColor)),
                              title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text(body),
                              trailing: Text(timeText, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
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
