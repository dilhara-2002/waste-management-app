import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:convert';
import 'dart:async';
import '../utils/geo_helper.dart';
import '../services/routing_service.dart';
import 'segregation_guide.dart';

class ResidentHome extends StatefulWidget {
  const ResidentHome({super.key});

  static Map<String, dynamic> buildLocationUpdatePayload(LatLng location) {
    return {
      'latitude': location.latitude,
      'longitude': location.longitude,
      'locationUpdated': FieldValue.serverTimestamp(),
    };
  }

  static Map<String, dynamic> buildLocationRemovalPayload() {
    return {
      'latitude': FieldValue.delete(),
      'longitude': FieldValue.delete(),
      'locationUpdated': FieldValue.serverTimestamp(),
    };
  }

  @override
  State<ResidentHome> createState() => _ResidentHomeState();
}

class _ResidentHomeState extends State<ResidentHome> {
  final _mapController = MapController();
  int _currentIndex = 0;
  int _scheduleFilterIndex = 1; // 0: All, 1: Upcoming, 2: Completed, 3: Missed
  int _selectedScheduleDayIndex = 17; // today in the 35-day strip
  final ScrollController _scheduleScrollController = ScrollController();
  final _firestore = FirebaseFirestore.instance;
  Map<String, dynamic>? _userData;
  Map<String, dynamic>? _truckLocation;
  List<LatLng>? _routePoints;
  num? _routeDistance;
  num? _routeDuration;
  int _notificationFilterIndex = 0; // 0: All, 1: Reminders, 2: Updates, 3: Alerts
  int _newAlertCount = 0;
  DateTime? _lastAlertViewedAt;
  int _supportTabIndex = 0; // 0: Report Issue, 1: Give Feedback
  String _selectedIssueType = 'Missed Pickup';
  String _reportDescription = '';
  String _feedbackMessage = '';
  // Cached community posts to prevent blinking on Firestore real-time updates
  List<Map<String, dynamic>>? _communityPosts;
  bool _isRefreshing = false;
  StreamSubscription<QuerySnapshot>? _notifSubscription;
  bool _notifListenerInitialized = false;
  String? _notifResidentAreaCode;
  StreamSubscription<dynamic>? _truckSubscription;

  @override
  void initState() {
    super.initState();
    _loadUserData();
    _listenToTruckLocation();
  }

  @override
  void dispose() {
    _notifSubscription?.cancel();
    _truckSubscription?.cancel();
    _scheduleScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadUserData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final doc = await _firestore.collection('users').doc(user.uid).get();
      if (doc.exists && mounted) {
        setState(() {
          _userData = doc.data();
        });
        if (_userData?['latitude'] != null && _userData?['longitude'] != null) {
          final lat = _userData!['latitude'] as double;
          final lon = _userData!['longitude'] as double;
          _mapController.move(LatLng(lat, lon), 15.0);
        }
        _fetchRoute(); // Fetch route when user data loads
        // Start notification listener and truck listener (will avoid re-subscribing if area same)
        _startNotificationListener();
        _listenToTruckLocation();
      }
    }
  }

  void _startNotificationListener() {
    final residentAreaCode = (_userData?['areaCode'] ?? '').toString().trim();
    if (residentAreaCode.isEmpty) return;

    // If already listening for the same area, do nothing
    if (_notifSubscription != null && _notifResidentAreaCode == residentAreaCode) return;

    // Cancel previous subscription and reset init flag
    _notifSubscription?.cancel();
    _notifListenerInitialized = false;
    _notifResidentAreaCode = residentAreaCode;
    _lastAlertViewedAt = DateTime.now();

    _notifSubscription = _firestore
        .collection('notifications')
        .where('areaCode', isEqualTo: residentAreaCode)
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;

      // The first snapshot delivers all existing documents as `added` — ignore
      if (!_notifListenerInitialized) {
        _notifListenerInitialized = true;
        return;
      }

      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data() as Map<String, dynamic>?;
          if (data == null) continue;

          final timestamp = data['createdAt'] as Timestamp?;
          final createdAt = timestamp?.toDate();
          final title = (data['title'] ?? 'Notification').toString();
          final body = (data['body'] ?? '').toString();

          if (_lastAlertViewedAt == null || createdAt == null || createdAt.isAfter(_lastAlertViewedAt!)) {
            setState(() {
              _newAlertCount += 1;
            });
          }

          if (mounted && _currentIndex != 4) {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(title),
                content: Text(body),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Dismiss')),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _newAlertCount = 0;
                        _lastAlertViewedAt = DateTime.now();
                        _currentIndex = 4;
                      });
                    },
                    child: const Text('View'),
                  ),
                ],
              ),
            );
          }
        }
      }
    });
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
    // Cancel previous truck subscription if any
    _truckSubscription?.cancel();

    final residentAreaCode = (_userData?['areaCode'] ?? '').toString().trim();

    if (residentAreaCode.isNotEmpty) {
      // Listen to all trucks in the resident's area only
      _truckSubscription = _firestore
          .collection('truck_locations')
          .where('areaCode', isEqualTo: residentAreaCode)
          .snapshots()
          .listen((snapshot) {
        if (!mounted) return;
        if (snapshot.docs.isEmpty) {
          setState(() {
            _truckLocation = null;
            _routePoints = null;
            _routeDistance = null;
            _routeDuration = null;
          });
          return;
        }

        // Choose the closest truck to the user if we have user coords
        Map<String, dynamic>? chosen;
        if (_userData?['latitude'] != null && _userData?['longitude'] != null) {
          final userLat = _userData!['latitude'] as double;
          final userLon = _userData!['longitude'] as double;
          double? bestDist;
          for (var doc in snapshot.docs) {
            final data = doc.data() as Map<String, dynamic>;
            final lat = data['latitude'] as double?;
            final lon = data['longitude'] as double?;
            if (lat == null || lon == null) continue;
            final dist = GeoHelper.calculateDistance(userLat, userLon, lat, lon);
            if (bestDist == null || dist < bestDist) {
              bestDist = dist;
              chosen = data;
            }
          }
        }

        // Fallback: pick the first truck
        chosen ??= snapshot.docs.first.data() as Map<String, dynamic>;

        // Validate timestamp freshness
        final timestamp = chosen['timestamp'] as Timestamp?;
        if (timestamp != null) {
          final age = DateTime.now().difference(timestamp.toDate());
          if (age.inSeconds < 60) {
            setState(() {
              _truckLocation = chosen;
            });
            _fetchRoute();
            return;
          }
        }

        // If we reach here, no fresh truck
        setState(() {
          _truckLocation = null;
          _routePoints = null;
          _routeDistance = null;
          _routeDuration = null;
        });
      });
    } else {
      // Fallback: listen to single truck document (legacy)
      final docRef = _firestore.collection('truck_locations').doc('truck_1');
      _truckSubscription = docRef.snapshots().listen((snapshot) {
        if (snapshot.exists && mounted) {
          final data = snapshot.data();
          if (data == null) return;

          final timestamp = data['timestamp'] as Timestamp?;
          if (timestamp != null) {
            final age = DateTime.now().difference(timestamp.toDate());
            if (age.inSeconds < 60) {
              setState(() => _truckLocation = data);
              _fetchRoute();
              return;
            }
          }
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

  Future<void> _removeSavedLocation() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _userData?['latitude'] == null || _userData?['longitude'] == null) {
      return;
    }

    final shouldRemove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete current location?'),
        content: const Text('This will permanently remove your saved collection point from Firebase. You can set a new one later.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete Location'),
          ),
        ],
      ),
    );

    if (shouldRemove != true) {
      return;
    }

    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .set(ResidentHome.buildLocationRemovalPayload(), SetOptions(merge: true));

      await _loadUserData();
      _mapController.move(const LatLng(6.9271, 79.8612), 15.0);
      _routePoints = null;
      _routeDistance = null;
      _routeDuration = null;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Collection point removed.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error removing location: $e'),
            backgroundColor: Colors.red,
          ),
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
        timeLimit: const Duration(seconds: 15),
      );
      
      debugPrint('✅ GPS fix: ${position.latitude}, ${position.longitude}, Accuracy: ${position.accuracy.toStringAsFixed(1)}m');

      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog

      // Show confirmation dialog with GPS location
      LatLng gpsPosition = LatLng(position.latitude, position.longitude);
      final Object? dialogResult = await showDialog<Object?>(
        context: context,
        builder: (context) => _LocationPickerDialog(gpsPosition: gpsPosition),
      );

      if (dialogResult == 'delete_location') {
        await _removeSavedLocation();
        return;
      }

      if (dialogResult is LatLng) {
        final confirmedPosition = dialogResult;
        final locationPayload = ResidentHome.buildLocationUpdatePayload(confirmedPosition);

        await _firestore
            .collection('users')
            .doc(user.uid)
            .set(locationPayload, SetOptions(merge: true));

        await _loadUserData();
        _mapController.move(confirmedPosition, 15.0);
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

    final nameCtrl = TextEditingController(text: (_userData?['name'] ?? '').toString());
    final phoneCtrl = TextEditingController(text: (_userData?['phone'] ?? '').toString());
    final areaCtrl = TextEditingController(text: (_userData?['areaCode'] ?? '').toString());

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            bool isSaving = false;
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
              child: SafeArea(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text('My Profile', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          user?.email ?? _userData?['email'] ?? '',
                          style: TextStyle(color: Colors.grey[600], fontSize: 14),
                        ),
                        const Divider(height: 24),
                        TextField(
                          controller: nameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Full Name',
                            prefixIcon: Icon(Icons.person_outline),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: phoneCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Phone Number',
                            prefixIcon: Icon(Icons.phone_outlined),
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.phone,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: areaCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Area Code',
                            prefixIcon: Icon(Icons.map_outlined),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Location row
                        Row(
                          children: [
                            const Icon(Icons.home_outlined, color: Colors.grey, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _userData?['latitude'] != null
                                    ? 'Pickup: Lat ${(_userData!['latitude'] as double).toStringAsFixed(4)}, Lon ${(_userData!['longitude'] as double).toStringAsFixed(4)}'
                                    : 'No pickup location set',
                                style: const TextStyle(fontSize: 13, color: Colors.grey),
                              ),
                            ),
                            TextButton(
                              onPressed: () async {
                                Navigator.pop(context);
                                await _showSetLocationDialog();
                              },
                              child: Text(_userData?['latitude'] != null ? 'Edit' : 'Set'),
                            ),
                            if (_userData?['latitude'] != null && _userData?['longitude'] != null)
                              TextButton(
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await _removeSavedLocation();
                                },
                                child: const Text('Remove', style: TextStyle(color: Colors.red)),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: isSaving
                                ? null
                                : () async {
                                    setSheetState(() => isSaving = true);
                                    try {
                                      final uid = user?.uid;
                                      if (uid == null) return;
                                      await _firestore.collection('users').doc(uid).set({
                                        'name': nameCtrl.text.trim(),
                                        'phone': phoneCtrl.text.trim(),
                                        'areaCode': areaCtrl.text.trim(),
                                        'updatedAt': FieldValue.serverTimestamp(),
                                      }, SetOptions(merge: true));
                                      await _loadUserData();
                                      if (mounted) Navigator.pop(context);
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Profile updated successfully')),
                                        );
                                      }
                                    } catch (e) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('Error updating profile: $e')),
                                        );
                                      }
                                    } finally {
                                      setSheetState(() => isSaving = false);
                                    }
                                  },
                            icon: isSaving
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.save_outlined),
                            label: Text(isSaving ? 'Saving...' : 'Save Changes'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green[700],
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final email = user?.email ?? _userData?['email']?.toString();
                              if (email == null || email.isEmpty) {
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
                            icon: const Icon(Icons.lock_outline),
                            label: const Text('Reset Password'),
                            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              Navigator.pop(context);
                              await _logout();
                            },
                            icon: const Icon(Icons.logout, color: Colors.orange),
                            label: const Text('Logout', style: TextStyle(color: Colors.orange)),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.orange),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Delete Account'),
                                  content: const Text(
                                    'This will permanently delete your account and all associated data. This action cannot be undone.',
                                  ),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                    ElevatedButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true) {
                                try {
                                  final uid = user?.uid;
                                  if (uid != null) {
                                    await _firestore.collection('users').doc(uid).delete();
                                  }
                                  await user?.delete();
                                  if (mounted) Navigator.pushReplacementNamed(context, '/');
                                } catch (e) {
                                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error deleting account: $e')));
                                }
                              }
                            },
                            icon: const Icon(Icons.delete_forever, color: Colors.red),
                            label: const Text('Delete Account', style: TextStyle(color: Colors.red)),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.red),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
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
            if (index == 4) {
              _newAlertCount = 0;
              _lastAlertViewedAt = DateTime.now();
            }
          });
        },
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.green[700],
        unselectedItemColor: Colors.grey[600],
        items: [
          const BottomNavigationBarItem(icon: Icon(Icons.home_outlined), label: 'Home'),
          const BottomNavigationBarItem(icon: Icon(Icons.map_outlined), label: 'Map'),
          const BottomNavigationBarItem(icon: Icon(Icons.calendar_today_outlined), label: 'Schedule'),
          const BottomNavigationBarItem(icon: Icon(Icons.article_outlined), label: 'Report'),
          BottomNavigationBarItem(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications_outlined),
                if (_newAlertCount > 0)
                  Positioned(
                    right: -7,
                    top: -5,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                      child: Text(
                        _newAlertCount > 99 ? '99+' : _newAlertCount.toString(),
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            label: 'Alerts',
          ),
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

  // Manual refresh: re-fetches posts from Firestore and updates the cache
  Future<void> _refreshPosts() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      final snap = await _firestore
          .collection('community_posts')
          .where('published', isEqualTo: true)
          .get();
      if (mounted) {
        setState(() {
          _communityPosts = snap.docs
              .map((doc) => doc.data())
              .toList()
            ..sort((a, b) {
              final aTs = a['createdAt'];
              final bTs = b['createdAt'];
              if (aTs == null && bTs == null) return 0;
              if (aTs == null) return 1;
              if (bTs == null) return -1;
              return (bTs as Timestamp).compareTo(aTs as Timestamp);
            });
        });
      }
    } catch (_) {
      if (mounted) setState(() => _communityPosts ??= []);
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  // HOME tab: upcoming collection card + quick actions + tips
  Widget _buildHomeTab() {
    return RefreshIndicator(
      onRefresh: _refreshPosts,
      color: Colors.green[700],
      child: SingleChildScrollView(
        // physics must allow overscroll so RefreshIndicator triggers
        physics: const AlwaysScrollableScrollPhysics(),
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
          _buildUpcomingCollectionCard(),

          const SizedBox(height: 18),
          const Text('Community Updates', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnapshot>(
            // Query only on a single field (no composite index needed) —
            // sorting is done client-side to avoid Android index requirement.
            stream: _firestore
                .collection('community_posts')
                .where('published', isEqualTo: true)
                .snapshots(),
            builder: (context, snapshot) {
              // Update cached posts when new data arrives (prevents blinking on updates)
              if (snapshot.hasData) {
                final sorted = snapshot.data!.docs
                    .map((doc) => doc.data() as Map<String, dynamic>)
                    .toList()
                  ..sort((a, b) {
                    final aTs = a['createdAt'];
                    final bTs = b['createdAt'];
                    if (aTs == null && bTs == null) return 0;
                    if (aTs == null) return 1;
                    if (bTs == null) return -1;
                    return (bTs as Timestamp).compareTo(aTs as Timestamp);
                  });
                _communityPosts = sorted;
              } else if (snapshot.connectionState != ConnectionState.waiting) {
                // Firestore responded but no data (empty result or error) —
                // treat as empty list so we never spin forever
                _communityPosts ??= [];
              }

              // Show spinner only while waiting for the very first response
              if (_communityPosts == null) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              final posts = _communityPosts!;

              if (posts.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('No community posts yet. Collector updates will appear here.'),
                );
              }

              // Use Column instead of ListView so the parent SingleChildScrollView
              // handles all scrolling — allows scrolling up to see all posts
              return Column(
                children: [
                  for (int index = 0; index < posts.length; index++) ...[
                    if (index > 0) const SizedBox(height: 10),
                    Builder(builder: (context) {
                      final post = posts[index];
                      final caption = (post['caption'] ?? 'Community update').toString();
                      final imageUrl = (post['imageUrl'] ?? '').toString();
                      return Card(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const CircleAvatar(
                                    radius: 18,
                                    backgroundColor: Colors.green,
                                    child: Icon(Icons.people, color: Colors.white, size: 18),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          (post['author'] ?? 'Collector Team').toString(),
                                          style: const TextStyle(fontWeight: FontWeight.bold),
                                        ),
                                        Text(
                                          'Community update',
                                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              if (imageUrl.isNotEmpty)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: _buildPostImage(imageUrl),
                                ),
                              const SizedBox(height: 10),
                              Text(caption, style: const TextStyle(fontSize: 14)),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ],
              );
            },
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
      ),
    );
  }

  Widget _buildPostImage(String imageValue) {
    if (imageValue.isEmpty) {
      return const SizedBox.shrink();
    }

    try {
      if (imageValue.startsWith('data:image')) {
        final base64Data = imageValue.split('base64,').last;
        return Image.memory(
          base64Decode(base64Data),
          height: 180,
          width: double.infinity,
          fit: BoxFit.cover,
        );
      }

      if (imageValue.startsWith('http')) {
        return Image.network(
          imageValue,
          height: 180,
          width: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Container(
            height: 180,
            color: Colors.grey[200],
            child: const Center(child: Text('Image unavailable')),
          ),
        );
      }

      return Image.memory(
        base64Decode(imageValue),
        height: 180,
        width: double.infinity,
        fit: BoxFit.cover,
      );
    } catch (_) {
      return Container(
        height: 180,
        color: Colors.grey[200],
        child: const Center(child: Text('Image unavailable')),
      );
    }
  }

  void _showPostImagePreview(String? imageBase64, String? imageUrl) {
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: SizedBox(
          width: 360,
          height: 520,
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close),
                ),
              ),
              Expanded(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: imageBase64 != null && imageBase64.isNotEmpty
                      ? Image.memory(base64Decode(imageBase64), fit: BoxFit.contain)
                      : (imageUrl != null && imageUrl.isNotEmpty
                          ? Image.network(imageUrl, fit: BoxFit.contain)
                          : const Center(child: Text('No image available'))),
                ),
              ),
            ],
          ),
        ),
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
    final residentAreaCode = (_userData?['areaCode'] ?? '').toString().trim();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text('Notifications', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              ),
              if (residentAreaCode.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.green[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Text(
                    'Area: $residentAreaCode',
                    style: TextStyle(color: Colors.green[700], fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),

        const Divider(height: 1),

        // Notifications list filtered by resident's area code
        Expanded(
          child: residentAreaCode.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.notifications_off_outlined, size: 56, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        const Text(
                          'No area code set',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Set your area code in your profile to receive notifications.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                )
              : StreamBuilder<QuerySnapshot>(
                  // Single-field query — no composite index needed on Android
                  stream: _firestore
                      .collection('notifications')
                      .where('areaCode', isEqualTo: residentAreaCode)
                      .snapshots(),
                  builder: (context, snapshot) {
                    List<Map<String, dynamic>> docs = [];
                    if (snapshot.hasData) {
                      docs = snapshot.data!.docs
                          .map((d) => d.data() as Map<String, dynamic>)
                          .toList()
                        ..sort((a, b) {
                          final aTs = a['createdAt'];
                          final bTs = b['createdAt'];
                          if (aTs == null && bTs == null) return 0;
                          if (aTs == null) return 1;
                          if (bTs == null) return -1;
                          return (bTs as Timestamp).compareTo(aTs as Timestamp);
                        });
                    }

                    if (snapshot.connectionState == ConnectionState.waiting && docs.isEmpty) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    if (docs.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.notifications_none, size: 56, color: Colors.grey[300]),
                              const SizedBox(height: 16),
                              Text(
                                'No notifications for Area $residentAreaCode yet.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey[600]),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'You will be notified when the truck starts or a schedule is updated.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey[500], fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: docs.length,
                      itemBuilder: (context, index) {
                        final data = docs[index];
                        final title = data['title'] ?? 'Notification';
                        final body = data['body'] ?? '';
                        final type = (data['type'] ?? '').toString().toLowerCase();
                        final createdAt = data['createdAt'] as Timestamp?;

                        Color leftColor;
                        IconData icon;
                        if (type == 'shift_start') {
                          leftColor = Colors.green;
                          icon = Icons.local_shipping;
                        } else if (type == 'schedule_update' || type == 'schedule_add') {
                          leftColor = Colors.blue;
                          icon = Icons.calendar_month;
                        } else {
                          leftColor = Colors.orange;
                          icon = Icons.notifications;
                        }

                        String timeText = '';
                        if (createdAt != null) {
                          final dt = createdAt.toDate();
                          final diff = DateTime.now().difference(dt);
                          if (diff.inDays >= 1) {
                            timeText = '${dt.day}/${dt.month}/${dt.year}';
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
                              Container(
                                width: 6,
                                height: 84,
                                decoration: BoxDecoration(
                                  color: leftColor,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Card(
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: leftColor.withValues(alpha: 0.12),
                                      child: Icon(icon, color: leftColor),
                                    ),
                                    title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                                    subtitle: Text(body),
                                    trailing: Text(
                                      timeText,
                                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                                    ),
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

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
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
        ),
        Positioned(
          bottom: 16,
          right: 16,
          child: FloatingActionButton.small(
            heroTag: 'recenter_resident_map',
            onPressed: () {
              if (_userData?['latitude'] != null && _userData?['longitude'] != null) {
                final lat = _userData!['latitude'] as double;
                final lon = _userData!['longitude'] as double;
                _mapController.move(LatLng(lat, lon), 15.0);
              }
            },
            backgroundColor: Colors.white,
            child: const Icon(Icons.my_location, color: Colors.green),
          ),
        ),
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
        final residentAreaCode = (_userData?['areaCode'] ?? '').toString().trim();
        final sourceSchedules = schedules
            .map((doc) => doc.data() as Map<String, dynamic>)
            .toList();

        if (snapshot.hasError) {
          debugPrint('Schedule stream error: ${snapshot.error}');
          if (sourceSchedules.isEmpty) {
            sourceSchedules.addAll(_fallbackSchedules());
          }
        }

        final selectedDate = _dateForSelectedScheduleDay();
        final selectedDayName = _weekdayLongName(selectedDate.weekday - 1);
        final filteredSchedules = sourceSchedules.where((schedule) {
          final scheduleAreaCode = (schedule['areaCode'] ?? schedule['areaName'] ?? '').toString().trim();
          final areaMatches = residentAreaCode.isEmpty ||
              scheduleAreaCode.toLowerCase() == residentAreaCode.toLowerCase();
          if (!areaMatches) return false;

          if (_scheduleFilterIndex == 0) {
            return true;
          }

          final scheduleDate = _resolveScheduleDate(schedule);
          final dayOfWeek = (schedule['dayOfWeek'] ?? '').toString();
          final status = _scheduleStatus(schedule, dayOfWeek);

          if (_scheduleFilterIndex == 1) {
            return status == 'Upcoming';
          }

          final bool dayMatches;
          if (scheduleDate != null) {
            dayMatches = scheduleDate.year == selectedDate.year &&
                scheduleDate.month == selectedDate.month &&
                scheduleDate.day == selectedDate.day;
          } else {
            dayMatches = dayOfWeek.isEmpty || dayOfWeek.toLowerCase() == selectedDayName.toLowerCase();
          }
          if (!dayMatches) return false;
          if (_scheduleFilterIndex == 2) return status == 'Completed';
          return status == 'Missed';
        }).toList()
          ..sort((a, b) {
            final aDate = _resolveScheduleDate(a) ?? DateTime(9999);
            final bDate = _resolveScheduleDate(b) ?? DateTime(9999);
            return aDate.compareTo(bDate);
          });

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

  DateTime _scheduleStripStartDate() {
    final now = DateTime.now();
    return now.subtract(const Duration(days: 17));
  }

  DateTime _dateForSelectedScheduleDay() {
    return _scheduleStripStartDate().add(Duration(days: _selectedScheduleDayIndex));
  }

  bool _isSelectedDateInCurrentWeek(DateTime date) {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));
    return !date.isBefore(monday) && !date.isAfter(sunday);
  }

  DateTime? _findNewestScheduleDateForArea(List<Map<String, dynamic>> schedules, String residentAreaCode) {
    DateTime? newest;
    for (final schedule in schedules) {
      final scheduleAreaCode = (schedule['areaCode'] ?? schedule['areaName'] ?? '').toString().trim();
      final areaMatches = residentAreaCode.isEmpty ||
          scheduleAreaCode.toLowerCase() == residentAreaCode.toLowerCase();
      if (!areaMatches) continue;

      final scheduleDate = _resolveScheduleDate(schedule);
      if (scheduleDate == null) continue;

      if (newest == null || scheduleDate.isAfter(newest)) {
        newest = scheduleDate;
      }
    }
    return newest;
  }

  Map<String, dynamic>? _findNearestUpcomingSchedule(List<Map<String, dynamic>> schedules, String residentAreaCode) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime? nearestDate;
    Map<String, dynamic>? nearest;

    for (final schedule in schedules) {
      final scheduleAreaCode = (schedule['areaCode'] ?? schedule['areaName'] ?? '').toString().trim();
      final areaMatches = residentAreaCode.isEmpty ||
          scheduleAreaCode.toLowerCase() == residentAreaCode.toLowerCase();
      if (!areaMatches) continue;

      final scheduleDate = _resolveScheduleDate(schedule);
      if (scheduleDate == null) continue;

      final scheduleDayOnly = DateTime(scheduleDate.year, scheduleDate.month, scheduleDate.day);
      if (scheduleDayOnly.isBefore(today)) continue;

      if (nearestDate == null || scheduleDayOnly.isBefore(nearestDate)) {
        nearestDate = scheduleDayOnly;
        nearest = schedule;
      }
    }

    return nearest;
  }

  Widget _buildUpcomingCollectionCard() {
    final residentAreaCode = (_userData?['areaCode'] ?? '').toString().trim();
    if (residentAreaCode.isEmpty) {
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ListTile(
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.green[50], borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.calendar_month, color: Colors.green),
          ),
          title: const Text('Upcoming collection unavailable', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: const Text('Set your area code to see the nearest schedule.'),
          trailing: const Icon(Icons.info_outline),
        ),
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('schedules').snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && snapshot.data == null) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final sourceSchedules = snapshot.hasData
            ? snapshot.data!.docs.map((doc) => doc.data() as Map<String, dynamic>).toList()
            : <Map<String, dynamic>>[];

        final schedules = sourceSchedules.isNotEmpty ? sourceSchedules : _fallbackSchedules();
        final nextSchedule = _findNearestUpcomingSchedule(schedules, residentAreaCode);

        if (nextSchedule == null) {
          return Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.green[50], borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.event_busy, color: Colors.green),
              ),
              title: const Text('No upcoming schedule found', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Check back later or update your area code.'),
              trailing: const Icon(Icons.local_shipping_outlined),
            ),
          );
        }

        final date = _resolveScheduleDate(nextSchedule) ?? DateTime.now();
        final wasteType = (nextSchedule['wasteType'] ?? 'Collection').toString();
        final time = (nextSchedule['time'] ?? '08:00 AM - 10:00 AM').toString();
        final areaName = (nextSchedule['areaName'] ?? '').toString();
        final dayLabel = _formatCardDate(date);

        return Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.green[50], borderRadius: BorderRadius.circular(8)),
              child: Text(
                '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
              ),
            ),
            title: Text(wasteType, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('$dayLabel • ${_formatTimeRange(time)}${areaName.isNotEmpty ? '\n$areaName' : ''}'),
            isThreeLine: areaName.isNotEmpty,
            trailing: const Icon(Icons.local_shipping),
            onTap: () {
              setState(() {
                _currentIndex = 2;
              });
            },
          ),
        );
      },
    );
  }

  DateTime? _resolveScheduleDate(Map<String, dynamic> schedule) {
    final rawDate = (schedule['date'] ?? '').toString();
    if (rawDate.isNotEmpty) {
      try {
        return DateTime.parse(rawDate);
      } catch (_) {
        // Fall back to day-of-week matching below if the date is invalid.
      }
    }

    final dayOfWeek = (schedule['dayOfWeek'] ?? '').toString();
    if (dayOfWeek.isEmpty) return null;
    return _nextDateForWeekday(dayOfWeek);
  }

  Widget _buildWeekStrip() {
    final stripStartDate = _scheduleStripStartDate();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scheduleScrollController.hasClients) return;
      final targetOffset = (_selectedScheduleDayIndex * 50.0) - 90.0;
      final clampedOffset = targetOffset.clamp(0.0, _scheduleScrollController.position.maxScrollExtent);
      if ((_scheduleScrollController.offset - clampedOffset).abs() > 2) {
        _scheduleScrollController.animateTo(
          clampedOffset,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    });

    return SingleChildScrollView(
      controller: _scheduleScrollController,
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: List.generate(35, (index) {
          final dayDate = stripStartDate.add(Duration(days: index));
          final isSelected = _selectedScheduleDayIndex == index;
          final dayName = _weekdayShortName(dayDate.weekday - 1);

          return GestureDetector(
            onTap: () {
              setState(() {
                _selectedScheduleDayIndex = index;
              });
            },
            child: Container(
              width: 42,
              height: 66,
              margin: const EdgeInsets.only(right: 8),
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
      ),
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
    final residentAreaCode = (_userData?['areaCode'] ?? '').toString().trim();
    final areaHint = residentAreaCode.isNotEmpty ? ' for $residentAreaCode' : '';
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
            'Try another day or filter$areaHint',
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

    final cardDate = _resolveScheduleDate(schedule) ?? _nextDateForWeekday(dayOfWeek);

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
  final MapController _dialogMapController = MapController();

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
                mapController: _dialogMapController,
                options: MapOptions(
                  center: _selectedPosition,
                  zoom: 17.0,
                  onTap: (tapPosition, point) {
                    setState(() {
                      _selectedPosition = point;
                      _manuallyAdjusted = true;
                    });
                    _dialogMapController.move(point, 17.0);
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
            Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 64,
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context, 'delete_location'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red, width: 1.2),
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.delete_outline, size: 22),
                              SizedBox(height: 4),
                              Text('Delete', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 64,
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.close, size: 22),
                              SizedBox(height: 4),
                              Text('Cancel', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 58,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.pop(context, _selectedPosition),
                    icon: const Icon(Icons.check_circle),
                    label: const Text(
                      'Confirm',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
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
