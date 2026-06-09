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
  int _scheduleFilterIndex = 1; // 0: All, 1: Upcoming, 2: Completed, 3: Missed
  int _selectedScheduleDayIndex = DateTime.now().weekday - 1;
  final _firestore = FirebaseFirestore.instance;
  Map<String, dynamic>? _userData;
  Map<String, dynamic>? _truckLocation;
  List<LatLng>? _routePoints;
  num? _routeDistance;
  num? _routeDuration;
  int _notificationFilterIndex = 0; // 0: All, 1: Reminders, 2: Updates, 3: Alerts
  int _supportTabIndex = 0; // 0: Report Issue, 1: Give Feedback
  String _selectedIssueType = 'Missed Pickup';
  String _reportDescription = '';
  String _feedbackMessage = '';

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
            if (_currentIndex == 0) _buildHomeHeader(),

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
    );
  }

  Widget _buildHomeHeader() {
    return Container(
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
                Text('What can we do for you?', style: TextStyle(color: Colors.white.withValues(alpha: 0.9))),
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
            height: 160,
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
            const Text(
              'Short tip description goes here',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  // REPORT tab: support and feedback form
  Widget _buildReportTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(34),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF1D2A40).withValues(alpha: 0.07),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Support & Feedback',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F2A3D),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(child: _supportTabButton('Report Issue', 0)),
                      Expanded(child: _supportTabButton('Give Feedback', 1)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: Color(0xFFE8EDF3)),
                  const SizedBox(height: 16),
                  if (_supportTabIndex == 0) ...[
                    const Text(
                      'Issue Type',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF34445A),
                      ),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: _showIssueTypePicker,
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFD),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFE4EAF1)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _selectedIssueType,
                                style: const TextStyle(
                                  fontSize: 18,
                                  color: Color(0xFF3A4A60),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const Icon(Icons.keyboard_arrow_down, color: Color(0xFF90A0B5)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Description',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF34445A),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFD),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE4EAF1)),
                      ),
                      child: TextField(
                        maxLines: 5,
                        onChanged: (value) => _reportDescription = value,
                        decoration: const InputDecoration(
                          hintText: 'Please describe the issue in detail...',
                          hintStyle: TextStyle(color: Color(0xFFB6C1CF), fontSize: 16),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Attach Photo (Optional)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF34445A),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F7FB),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFDCE5EF), style: BorderStyle.solid),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.camera_alt_outlined, size: 34, color: Color(0xFF90A0B5)),
                          SizedBox(height: 8),
                          Text(
                            'Tap to upload photo',
                            style: TextStyle(
                              color: Color(0xFF6E839C),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _primaryActionButton(
                      label: 'Submit Report',
                      onTap: _submitReport,
                    ),
                  ] else ...[
                    const Text(
                      'Share Your Feedback',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF34445A),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFD),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE4EAF1)),
                      ),
                      child: TextField(
                        maxLines: 6,
                        onChanged: (value) => _feedbackMessage = value,
                        decoration: const InputDecoration(
                          hintText: 'Tell us how we can improve your collection experience...',
                          hintStyle: TextStyle(color: Color(0xFFB6C1CF), fontSize: 16),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _primaryActionButton(
                      label: 'Submit Feedback',
                      onTap: _submitFeedback,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Recent Reports',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1F2A3D),
            ),
          ),
          const SizedBox(height: 10),
          _buildRecentReportsList(),
        ],
      ),
    );
  }

  Widget _supportTabButton(String title, int index) {
    final isActive = _supportTabIndex == index;
    return InkWell(
      onTap: () {
        setState(() {
          _supportTabIndex = index;
        });
      },
      child: Container(
        padding: const EdgeInsets.only(bottom: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isActive ? const Color(0xFF18C08F) : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: isActive ? const Color(0xFF07A375) : const Color(0xFF6E7F96),
          ),
        ),
      ),
    );
  }

  Widget _primaryActionButton({required String label, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF18B984),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF18B984).withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.send_outlined, color: Colors.white),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showIssueTypePicker() async {
    final issueTypes = [
      'Missed Pickup',
      'Late Collection',
      'Wrong Waste Type',
      'Damaged Bin',
      'Other',
    ];

    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return SafeArea(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: issueTypes.length,
            itemBuilder: (context, index) {
              final type = issueTypes[index];
              return ListTile(
                title: Text(type),
                trailing: _selectedIssueType == type
                    ? const Icon(Icons.check, color: Color(0xFF18B984))
                    : null,
                onTap: () => Navigator.pop(context, type),
              );
            },
          ),
        );
      },
    );

    if (selected != null && mounted) {
      setState(() {
        _selectedIssueType = selected;
      });
    }
  }

  Future<void> _submitReport() async {
    if (_reportDescription.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please add a description before submitting.')),
        );
      }
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    try {
      await _firestore.collection('reports').add({
        'type': _selectedIssueType,
        'description': _reportDescription.trim(),
        'status': 'Submitted',
        'userId': user?.uid,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        setState(() {
          _reportDescription = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Report submitted successfully.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not submit report. Saved locally in this session.')),
        );
      }
    }
  }

  Future<void> _submitFeedback() async {
    if (_feedbackMessage.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter your feedback message.')),
        );
      }
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    try {
      await _firestore.collection('feedback').add({
        'message': _feedbackMessage.trim(),
        'userId': user?.uid,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        setState(() {
          _feedbackMessage = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Feedback submitted. Thank you!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not submit feedback right now.')),
        );
      }
    }
  }

  Widget _buildRecentReportsList() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('reports').orderBy('createdAt', descending: true).limit(3).snapshots(),
      builder: (context, snapshot) {
        List<Map<String, dynamic>> reports = [];

        if (snapshot.hasData) {
          reports = snapshot.data!.docs
              .map((doc) => doc.data() as Map<String, dynamic>)
              .toList();
        }

        if (snapshot.hasError || reports.isEmpty) {
          reports = [
            {'type': 'Missed Pickup', 'status': 'Submitted', 'createdAt': null},
            {'type': 'Damaged Bin', 'status': 'In Review', 'createdAt': null},
          ];
        }

        return Column(
          children: reports.map((report) {
            final status = (report['status'] ?? 'Submitted').toString();
            final type = (report['type'] ?? 'Issue').toString();

            Color statusColor = const Color(0xFF2B72D6);
            if (status.toLowerCase().contains('review')) {
              statusColor = const Color(0xFFF29D38);
            } else if (status.toLowerCase().contains('resolved')) {
              statusColor = const Color(0xFF11A76A);
            }

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE5ECF3)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0F5FB),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.assignment_outlined, color: Color(0xFF6F8299)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      type,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF253449),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      status,
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        );
      },
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

        final schedules = snapshot.hasData ? snapshot.data!.docs : <QueryDocumentSnapshot>[];
        final sourceSchedules = schedules
            .map((doc) => doc.data() as Map<String, dynamic>)
            .toList();

        if (snapshot.hasError) {
          debugPrint('Schedule stream error: ${snapshot.error}');
          if (sourceSchedules.isEmpty) {
            sourceSchedules.addAll(_fallbackSchedules());
          }
        }

        final selectedDayName = _weekdayLongName(_selectedScheduleDayIndex);
        final filteredSchedules = sourceSchedules.where((schedule) {
          final dayOfWeek = (schedule['dayOfWeek'] ?? '').toString();
          final status = _scheduleStatus(schedule, dayOfWeek);

          final dayMatches = dayOfWeek.isEmpty || dayOfWeek.toLowerCase() == selectedDayName.toLowerCase();
          if (!dayMatches) return false;

          if (_scheduleFilterIndex == 0) return true;
          if (_scheduleFilterIndex == 1) return status == 'Upcoming';
          if (_scheduleFilterIndex == 2) return status == 'Completed';
          return status == 'Missed';
        }).toList();

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(34),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF1B2738).withValues(alpha: 0.06),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Collection Schedule',
                        style: TextStyle(
                          fontSize: 36,
                          height: 1.0,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.8,
                          color: Color(0xFF1B2738),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Managed by your area admin',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.blueGrey.shade400,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _buildWeekStrip(),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(child: _filterChip('All', 0)),
                          const SizedBox(width: 8),
                          Expanded(child: _filterChip('Upcoming', 1)),
                          const SizedBox(width: 8),
                          Expanded(child: _filterChip('Completed', 2)),
                          const SizedBox(width: 8),
                          Expanded(child: _filterChip('Missed', 3)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Divider(height: 1, color: Color(0xFFEAEFF4)),
                      const SizedBox(height: 14),
                      if (filteredSchedules.isEmpty)
                        _buildNoSchedulesCard()
                      else
                        ...filteredSchedules.map((schedule) {
                          return _buildScheduleCard(schedule);
                        }),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWeekStrip() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(7, (index) {
        final dayDate = monday.add(Duration(days: index));
        final isSelected = _selectedScheduleDayIndex == index;
        final dayName = _weekdayShortName(index);

        return GestureDetector(
          onTap: () {
            setState(() {
              _selectedScheduleDayIndex = index;
            });
          },
          child: Container(
            width: 42,
            height: 66,
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFF16C37E) : Colors.transparent,
              borderRadius: BorderRadius.circular(21),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  dayName,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: isSelected ? Colors.white.withValues(alpha: 0.88) : const Color(0xFF8EA0B5),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${dayDate.day}',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: isSelected ? Colors.white : const Color(0xFF223246),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  Widget _filterChip(String label, int index) {
    final selected = _scheduleFilterIndex == index;
    return InkWell(
      onTap: () {
        setState(() {
          _scheduleFilterIndex = index;
        });
      },
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1C2B43) : const Color(0xFFEFF2F7),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : const Color(0xFF748399),
          ),
        ),
      ),
    );
  }

  Widget _buildNoSchedulesCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE7ECF2)),
      ),
      child: Column(
        children: [
          const Icon(Icons.event_busy, color: Color(0xFF8FA1B8), size: 34),
          const SizedBox(height: 10),
          const Text(
            'No schedules for this day',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Color(0xFF30445B),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Try another day or filter',
            style: TextStyle(color: Colors.blueGrey.shade300),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleCard(Map<String, dynamic> schedule) {
    final wasteType = (schedule['wasteType'] ?? 'Unknown Waste').toString();
    final dayOfWeek = (schedule['dayOfWeek'] ?? '').toString();
    final areaName = (schedule['areaName'] ?? '61a Buganda Rd, Kampala').toString();
    final time = (schedule['time'] ?? '08:00 AM - 10:00 AM').toString();
    final status = _scheduleStatus(schedule, dayOfWeek);

    IconData wasteIcon;
    if (wasteType.toLowerCase().contains('plastic')) {
      wasteIcon = Icons.local_drink_outlined;
    } else if (wasteType.toLowerCase().contains('recycl')) {
      wasteIcon = Icons.recycling_outlined;
    } else {
      wasteIcon = Icons.delete_outline;
    }

    final cardDate = _nextDateForWeekday(dayOfWeek);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE8EDF3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F6FA),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(wasteIcon, color: const Color(0xFF7D8EA5), size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      wasteType,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1F2D3F),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _statusBadge(status),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _scheduleMetaRow(Icons.calendar_today_outlined, _formatCardDate(cardDate)),
          const SizedBox(height: 7),
          _scheduleMetaRow(Icons.access_time, _formatTimeRange(time)),
          const SizedBox(height: 7),
          _scheduleMetaRow(Icons.location_on_outlined, areaName),
          const SizedBox(height: 8),
          Row(
            children: const [
              Icon(Icons.verified_user_outlined, size: 16, color: Color(0xFF0BAA68)),
              SizedBox(width: 6),
              Text(
                'Admin Scheduled',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0BAA68),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(String status) {
    Color bg;
    Color fg;
    IconData icon;

    if (status == 'Completed') {
      bg = const Color(0xFFE7F7EE);
      fg = const Color(0xFF0FA766);
      icon = Icons.check_circle_outline;
    } else if (status == 'Missed') {
      bg = const Color(0xFFFDEDED);
      fg = const Color(0xFFCB4A4A);
      icon = Icons.error_outline;
    } else {
      bg = const Color(0xFFE8F1FF);
      fg = const Color(0xFF2E65D6);
      icon = Icons.watch_later_outlined;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            status,
            style: TextStyle(
              fontSize: 11,
              color: fg,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _scheduleMetaRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 16, color: const Color(0xFF95A4B7)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF7F8EA1),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  String _weekdayShortName(int index) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[index];
  }

  String _weekdayLongName(int index) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[index];
  }

  DateTime _nextDateForWeekday(String dayOfWeek) {
    const map = {
      'monday': 1,
      'tuesday': 2,
      'wednesday': 3,
      'thursday': 4,
      'friday': 5,
      'saturday': 6,
      'sunday': 7,
    };

    final targetWeekday = map[dayOfWeek.toLowerCase()] ?? DateTime.now().weekday;
    final now = DateTime.now();
    final diff = (targetWeekday - now.weekday + 7) % 7;
    return now.add(Duration(days: diff));
  }

  String _formatCardDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final daysBetween = target.difference(today).inDays;

    if (daysBetween == 0) {
      return 'Today, ${months[date.month - 1]} ${date.day}';
    }
    if (daysBetween == 1) {
      return 'Tomorrow, ${months[date.month - 1]} ${date.day}';
    }

    return '${_weekdayShortName(date.weekday - 1)}, ${months[date.month - 1]} ${date.day}';
  }

  String _formatTimeRange(String rawTime) {
    if (rawTime.contains('-')) return rawTime;
    if (rawTime.isEmpty) return '08:00 AM - 10:00 AM';
    return '$rawTime - 10:00 AM';
  }

  String _scheduleStatus(Map<String, dynamic> schedule, String dayOfWeek) {
    final explicitStatus = (schedule['status'] ?? '').toString().toLowerCase();
    if (explicitStatus == 'completed') return 'Completed';
    if (explicitStatus == 'missed') return 'Missed';
    if (explicitStatus == 'upcoming') return 'Upcoming';

    final date = _nextDateForWeekday(dayOfWeek);
    final now = DateTime.now();
    final dayOnlyNow = DateTime(now.year, now.month, now.day);
    final dayOnlySchedule = DateTime(date.year, date.month, date.day);

    if (dayOnlySchedule.isBefore(dayOnlyNow)) {
      return 'Completed';
    }
    return 'Upcoming';
  }

  List<Map<String, dynamic>> _fallbackSchedules() {
    return [
      {
        'wasteType': 'Domestic Waste',
        'dayOfWeek': 'Wednesday',
        'areaName': '61a Buganda Rd, Kampala',
        'time': '08:00 AM - 10:00 AM',
        'status': 'upcoming',
      },
      {
        'wasteType': 'Plastic Waste',
        'dayOfWeek': 'Friday',
        'areaName': '61a Buganda Rd, Kampala',
        'time': '02:00 PM - 04:00 PM',
        'status': 'upcoming',
      },
      {
        'wasteType': 'Recyclable',
        'dayOfWeek': 'Monday',
        'areaName': 'Central Ward',
        'time': '09:00 AM - 11:00 AM',
        'status': 'completed',
      },
    ];
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
