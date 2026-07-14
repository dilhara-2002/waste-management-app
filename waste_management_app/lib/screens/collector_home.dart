import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:async';
import 'dart:convert';
import '../services/routing_service.dart';
import '../utils/area_options.dart';

class CollectorHome extends StatefulWidget {
  const CollectorHome({super.key});

  @override
  State<CollectorHome> createState() => _CollectorHomeState();
}

class _CollectorHomeState extends State<CollectorHome> {
  bool _isOnShift = false;
  int _selectedTabIndex = 0;
  Timer? _locationTimer;
  final _firestore = FirebaseFirestore.instance;
  final ImagePicker _imagePicker = ImagePicker();
  Position? _currentPosition;
  Position? _previousPosition;
  double _currentSpeed = 0.0; // km/h
  List<LatLng>? _routePoints;
  Map<String, dynamic>? _selectedResident;
  String? _draftImageBase64;
  String? _draftImageName;
  bool _isPickingImage = false;
  bool _isSeedingSchedules = false;

  @override
  void initState() {
    super.initState();
    _seedDefaultSchedulesIfEmpty();
  }

  Future<void> _seedDefaultSchedulesIfEmpty() async {
    if (_isSeedingSchedules) return;
    _isSeedingSchedules = true;
    try {
      final snapshot = await _firestore.collection('schedules').limit(1).get();
      if (snapshot.docs.isNotEmpty) return;

      final now = DateTime.now();
      final defaults = [
        {
          'wasteType': 'Recyclables',
          'areaCode': 'A01',
          'date': _formatDate(now.add(const Duration(days: 1))),
        },
        {
          'wasteType': 'Organic waste',
          'areaCode': 'A02',
          'date': _formatDate(now.add(const Duration(days: 3))),
        },
        {
          'wasteType': 'General waste',
          'areaCode': 'A03',
          'date': _formatDate(now.add(const Duration(days: 5))),
        },
      ];

      final userId = FirebaseAuth.instance.currentUser?.uid ?? 'collector_seed';
      final batch = _firestore.batch();
      for (final entry in defaults) {
        final parsedDate = DateTime.parse(entry['date']!.toString());
        final docRef = _firestore.collection('schedules').doc();
        batch.set(docRef, {
          'date': entry['date'],
          'dayOfWeek': _dayNameFromDate(parsedDate),
          'time': '09:00 AM',
          'wasteType': entry['wasteType'],
          'areaCode': entry['areaCode'],
          'areaName': entry['areaCode'],
          'status': 'upcoming',
          'createdBy': userId,
          'updatedBy': userId,
          'published': true,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
      if (mounted) {
        setState(() {});
      }
    } catch (_) {
      // Keep screen usable even if initial seed fails.
    } finally {
      _isSeedingSchedules = false;
    }
  }

  String _dayNameFromDate(DateTime date) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[date.weekday - 1];
  }

  String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Future<void> _showScheduleEditor({Map<String, dynamic>? schedule}) async {
    final isEditing = schedule != null;
    final wasteController = TextEditingController(text: (schedule?['wasteType'] ?? '').toString());
    String selectedAreaCode = (schedule?['areaCode'] ?? schedule?['areaName'] ?? '').toString().trim();
    if (!kAreaCodes.contains(selectedAreaCode)) {
      selectedAreaCode = kAreaCodes.first;
    }

    DateTime selectedDate = DateTime.now();
    final existingDate = (schedule?['date'] ?? '').toString();
    if (existingDate.isNotEmpty) {
      final parts = existingDate.split('-');
      if (parts.length == 3) {
        selectedDate = DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
      }
    }

    TimeOfDay selectedTime = const TimeOfDay(hour: 8, minute: 0);
    final existingTime = (schedule?['time'] ?? '').toString();
    if (existingTime.isNotEmpty) {
      final match = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(existingTime);
      if (match != null) {
        final hour = int.parse(match.group(1)!);
        final minute = int.parse(match.group(2)!);
        final isPm = existingTime.toLowerCase().contains('pm');
        var hour24 = hour % 12;
        if (isPm) {
          hour24 += 12;
        }
        if (!isPm && hour == 12) {
          hour24 = 0;
        }
        selectedTime = TimeOfDay(hour: hour24, minute: minute);
      }
    }

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(isEditing ? 'Edit schedule' : 'Add new schedule'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: wasteController,
                    decoration: const InputDecoration(labelText: 'Waste type'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: selectedAreaCode,
                    decoration: const InputDecoration(labelText: 'Area'),
                    items: kAreaCodes
                        .map((area) => DropdownMenuItem<String>(
                              value: area,
                              child: Text(area),
                            ))
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        selectedAreaCode = value;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Date'),
                    subtitle: Text(_formatDate(selectedDate)),
                    trailing: const Icon(Icons.calendar_today_outlined),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: selectedDate,
                        firstDate: DateTime.now().subtract(const Duration(days: 1)),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (picked != null) {
                        setDialogState(() {
                          selectedDate = picked;
                        });
                      }
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Time'),
                    subtitle: Text(selectedTime.format(context)),
                    trailing: const Icon(Icons.access_time),
                    onTap: () async {
                      final picked = await showTimePicker(context: context, initialTime: selectedTime);
                      if (picked != null) {
                        setDialogState(() {
                          selectedTime = picked;
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () async {
                  final wasteType = wasteController.text.trim();
                  if (wasteType.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please complete waste type and area.')),
                    );
                    return;
                  }

                  await _saveSchedule(
                    dialogContext: context,
                    scheduleId: schedule?['id']?.toString(),
                    wasteType: wasteType,
                    areaCode: selectedAreaCode,
                    selectedDate: selectedDate,
                    selectedTime: selectedTime,
                  );
                  if (!mounted) return;
                  Navigator.pop(context);
                },
                child: Text(isEditing ? 'Save changes' : 'Add schedule'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _saveSchedule({
    required BuildContext dialogContext,
    required String? scheduleId,
    required String wasteType,
    required String areaCode,
    required DateTime selectedDate,
    required TimeOfDay selectedTime,
  }) async {
    final userId = FirebaseAuth.instance.currentUser?.uid ?? 'collector';
    final docRef = scheduleId == null
        ? _firestore.collection('schedules').doc()
        : _firestore.collection('schedules').doc(scheduleId);

    final data = <String, dynamic>{
      'date': _formatDate(selectedDate),
      'dayOfWeek': _dayNameFromDate(selectedDate),
      'time': selectedTime.format(dialogContext),
      'wasteType': wasteType,
      'areaCode': areaCode,
      'areaName': areaCode,
      'status': 'upcoming',
      'createdBy': userId,
      'updatedBy': userId,
      'published': true,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (scheduleId == null) {
      data['createdAt'] = FieldValue.serverTimestamp();
    }

    await docRef.set(data, SetOptions(merge: true));
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Schedule saved to Firebase successfully')),
    );
  }

  Future<void> _deleteSchedule(String scheduleId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete schedule'),
        content: const Text('Remove this schedule from the resident view?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _firestore.collection('schedules').doc(scheduleId).delete();
    }
  }

  Future<String?> _pickPostImage() async {
    final pickedFile = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 900,
      maxHeight: 900,
      imageQuality: 70,
    );
    if (pickedFile == null) return null;
    final bytes = await pickedFile.readAsBytes();
    return base64Encode(bytes);
  }

  Future<void> _showPostComposer({Map<String, dynamic>? post}) async {
    final isEditing = post != null;
    final captionController = TextEditingController(text: (post?['caption'] ?? '').toString());
    String? imageData = (post?['imageData'] ?? '').toString();
    if (imageData.isEmpty) {
      imageData = (post?['imageUrl'] ?? '').toString();
      if (imageData.startsWith('data:image')) {
        imageData = imageData.split('base64,').last;
      } else if (imageData.startsWith('http')) {
        imageData = '';
      }
    }
    bool isPickingImage = false;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(isEditing ? 'Edit post' : 'Add new post'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: captionController,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Caption'),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: isPickingImage
                        ? null
                        : () async {
                            setDialogState(() => isPickingImage = true);
                            try {
                              final pickedBase64 = await _pickPostImage();
                              if (pickedBase64 != null && mounted) {
                                setDialogState(() {
                                  imageData = pickedBase64;
                                  isPickingImage = false;
                                });
                              } else {
                                setDialogState(() => isPickingImage = false);
                              }
                            } catch (e) {
                              if (mounted) {
                                setDialogState(() => isPickingImage = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Error picking image: $e')),
                                );
                              }
                            }
                          },
                    icon: isPickingImage ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.photo_library_outlined),
                    label: Text(isPickingImage ? 'Picking image...' : 'Choose image'),
                  ),
                  if (imageData != null && imageData!.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 240),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: Colors.grey[100],
                      ),
                      child: GestureDetector(
                        onTap: () => _showImagePreview(imageData, null),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(
                            base64Decode(imageData!),
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                height: 180,
                                color: Colors.grey[200],
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.error_outline, color: Colors.red, size: 32),
                                    const SizedBox(height: 8),
                                    Text('Error loading image', style: TextStyle(color: Colors.red[700])),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tap image to preview',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ] else if (imageData == null || imageData!.isEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      height: 140,
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey[300]!),
                      ),
                      child: const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.image_outlined, color: Colors.grey, size: 40),
                            SizedBox(height: 8),
                            Text('No image selected', style: TextStyle(color: Colors.grey)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () async {
                  final caption = captionController.text.trim();
                  if (caption.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please add a caption for the post.')),
                    );
                    return;
                  }

                  final userId = FirebaseAuth.instance.currentUser?.uid ?? 'collector';
                  final docRef = isEditing && post?['id'] != null
                      ? _firestore.collection('community_posts').doc(post!['id'].toString())
                      : _firestore.collection('community_posts').doc();

                  final data = <String, dynamic>{
                    'caption': caption,
                    'imageData': imageData ?? '',
                    'imageUrl': imageData != null && imageData!.isNotEmpty ? 'data:image/jpeg;base64,$imageData' : '',
                    'author': 'Collector Team',
                    'createdBy': userId,
                    'updatedBy': userId,
                    'published': true,
                    'updatedAt': FieldValue.serverTimestamp(),
                  };
                  if (!isEditing) {
                    data['createdAt'] = FieldValue.serverTimestamp();
                  }

                  await docRef.set(data, SetOptions(merge: true));
                  if (!mounted) return;
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Post published to Firebase successfully')),
                  );
                },
                child: Text(isEditing ? 'Save changes' : 'Publish post'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showImagePreview(String? imageBase64, String? imageUrl) {
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
                      ? Image.memory(base64Decode(imageBase64), fit: BoxFit.contain, cacheWidth: 600)
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

  Future<void> _deletePost(String postId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete post'),
        content: const Text('Remove this community update from the resident feed?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _firestore.collection('community_posts').doc(postId).delete();
    }
  }

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
          Expanded(child: _buildSelectedTab()),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTabIndex,
        onTap: (index) => setState(() => _selectedTabIndex = index),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_outlined), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.edit_outlined), label: 'Edit'),
        ],
      ),
    );
  }

  Widget _buildSelectedTab() {
    if (_selectedTabIndex == 1) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          children: [
            _buildScheduleManagementCard(),
            const SizedBox(height: 14),
            _buildCommunityPostsCard(),
          ],
        ),
      );
    }

    return Column(
      children: [
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
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          _isOnShift
                              ? 'Broadcasting location every 10 seconds'
                              : 'Tap the button below to start your shift',
                          style: TextStyle(fontSize: 14, color: Colors.grey[700]),
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
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              children: [
                SizedBox(
                  height: 280,
                  child: StreamBuilder<QuerySnapshot>(
                    stream: _firestore.collection('users').where('role', isEqualTo: 'resident').snapshots(),
                    builder: (context, snapshot) {
                      List<Map<String, dynamic>> residents = [];
                      if (snapshot.hasData) {
                        residents = snapshot.data!.docs
                            .map((doc) => doc.data() as Map<String, dynamic>)
                            .where((data) => data['latitude'] != null && data['longitude'] != null)
                            .toList();
                      }

                      return Stack(
                        children: [
                          _buildMap(residents),
                          if (snapshot.connectionState == ConnectionState.waiting)
                            const Center(child: CircularProgressIndicator()),
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
                                      const Text('No pickup points yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
          ),
        ),
      ],
    );
  }

  Widget _buildScheduleManagementCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_month, color: Colors.green, size: 24),
              const SizedBox(width: 8),
              const Expanded(child: Text('Edit schedule', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              IconButton(
                onPressed: () => _showScheduleEditor(),
                icon: const Icon(Icons.add_circle_outline),
                tooltip: 'Add schedule',
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('Manage the current collection plan for residents. You can add, edit, or remove entries.', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Existing schedules', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 12),
          StreamBuilder<QuerySnapshot>(
            stream: _firestore.collection('schedules').orderBy('date', descending: false).snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final items = snapshot.hasData
                  ? snapshot.data!.docs.map((doc) {
                      final data = doc.data() as Map<String, dynamic>;
                      data['id'] = doc.id;
                      return data;
                    }).toList()
                  : <Map<String, dynamic>>[];
              if (items.isEmpty) {
                final today = DateTime.now();
                final starterSchedules = [
                  {
                    'wasteType': 'Recyclables',
                    'dayOfWeek': _dayNameFromDate(today.add(const Duration(days: 1))),
                    'date': _formatDate(today.add(const Duration(days: 1))),
                    'time': '09:00 AM',
                    'areaName': 'A01',
                  },
                  {
                    'wasteType': 'Organic waste',
                    'dayOfWeek': _dayNameFromDate(today.add(const Duration(days: 3))),
                    'date': _formatDate(today.add(const Duration(days: 3))),
                    'time': '10:30 AM',
                    'areaName': 'A02',
                  },
                  {
                    'wasteType': 'General waste',
                    'dayOfWeek': _dayNameFromDate(today.add(const Duration(days: 5))),
                    'date': _formatDate(today.add(const Duration(days: 5))),
                    'time': '08:00 AM',
                    'areaName': 'A03',
                  },
                ];

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Starter schedules are shown below. Tap + to add and save your own schedules.',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    ...starterSchedules.map((schedule) {
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          title: Text((schedule['wasteType'] ?? 'Schedule').toString()),
                          subtitle: Text('${schedule['dayOfWeek'] ?? ''} • ${schedule['date'] ?? ''} • ${schedule['time'] ?? ''}\n${schedule['areaName'] ?? ''}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: 'Edit schedule',
                            onPressed: () => _showScheduleEditor(schedule: schedule),
                          ),
                        ),
                      );
                    }).toList(),
                  ],
                );
              }
              return Column(
                children: items.map((schedule) {
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text((schedule['wasteType'] ?? 'Schedule').toString()),
                      subtitle: Text('${schedule['dayOfWeek'] ?? ''} • ${schedule['date'] ?? ''} • ${schedule['time'] ?? ''}\n${schedule['areaName'] ?? ''}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _showScheduleEditor(schedule: schedule)),
                          IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _deleteSchedule(schedule['id'].toString())),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCommunityPostsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.post_add_outlined, color: Colors.green, size: 24),
              const SizedBox(width: 8),
              const Expanded(child: Text('Community posts', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              IconButton(
                onPressed: () => _showPostComposer(),
                icon: const Icon(Icons.add_circle_outline),
                tooltip: 'Publish post',
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('Share photos and captions that appear in the resident home feed.', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          StreamBuilder<QuerySnapshot>(
            stream: _firestore.collection('community_posts').orderBy('createdAt', descending: true).snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final posts = snapshot.hasData
                  ? snapshot.data!.docs.map((doc) {
                      final data = doc.data() as Map<String, dynamic>;
                      data['id'] = doc.id;
                      return data;
                    }).toList()
                  : <Map<String, dynamic>>[];
              if (posts.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No posts yet. Share updates for residents to see.'),
                );
              }
              return Column(
                children: posts.map((post) {
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text((post['caption'] ?? 'Community update').toString()),
                      subtitle: Text(
                        (post['imageUrl'] ?? '').toString().isEmpty
                            ? 'No image attached yet'
                            : 'Image link ready',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _showPostComposer(post: post)),
                          IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _deletePost(post['id'].toString())),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
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
