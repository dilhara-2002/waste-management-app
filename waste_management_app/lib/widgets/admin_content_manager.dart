import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../utils/area_options.dart';

class AdminContentManager extends StatefulWidget {
  const AdminContentManager({super.key});

  @override
  State<AdminContentManager> createState() => _AdminContentManagerState();
}

class _AdminContentManagerState extends State<AdminContentManager> {
  final _firestore = FirebaseFirestore.instance;
  final _imagePicker = ImagePicker();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeading(
            'Schedules',
            Icons.calendar_month_outlined,
            () => _editSchedule(),
          ),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _firestore
                .collection('schedules')
                .orderBy('date')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty) return _emptyMessage('No schedules yet.');
              return Column(
                children: docs.map((doc) {
                  final schedule = {...doc.data(), 'id': doc.id};
                  return _scheduleTile(schedule);
                }).toList(),
              );
            },
          ),
          const SizedBox(height: 24),
          _sectionHeading(
            'Community Posts',
            Icons.campaign_outlined,
            () => _editPost(),
          ),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _firestore
                .collection('community_posts')
                .orderBy('createdAt', descending: true)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty) return _emptyMessage('No community posts yet.');
              return Column(
                children: docs.map((doc) {
                  final post = {...doc.data(), 'id': doc.id};
                  return _postTile(post);
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _sectionHeading(String title, IconData icon, VoidCallback onAdd) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF7C83FD)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(
          onPressed: onAdd,
          tooltip: 'Add $title',
          icon: const Icon(Icons.add_circle_outline, color: Color(0xFF7C83FD)),
        ),
      ],
    );
  }

  Widget _emptyMessage(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        message,
        style: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
      ),
    );
  }

  Widget _scheduleTile(Map<String, dynamic> schedule) {
    final id = schedule['id'].toString();
    return Card(
      color: const Color(0xFF1A2438),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          (schedule['wasteType'] ?? 'Schedule').toString(),
          style: const TextStyle(color: Colors.white),
        ),
        subtitle: Text(
          '${schedule['dayOfWeek'] ?? ''} • ${schedule['date'] ?? ''} • ${schedule['time'] ?? ''}\n${schedule['areaCode'] ?? schedule['areaName'] ?? ''}',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
        ),
        isThreeLine: true,
        trailing: Wrap(
          spacing: 0,
          children: [
            IconButton(
              tooltip: 'Edit schedule',
              icon: const Icon(Icons.edit_outlined, color: Colors.white70),
              onPressed: () => _editSchedule(schedule: schedule),
            ),
            IconButton(
              tooltip: 'Delete schedule',
              icon: const Icon(Icons.delete_outline, color: Color(0xFFEF5350)),
              onPressed: () => _deleteDocument('schedules', id),
            ),
          ],
        ),
      ),
    );
  }

  Widget _postTile(Map<String, dynamic> post) {
    final id = post['id'].toString();
    final imageData = (post['imageData'] ?? '').toString();
    return Card(
      color: const Color(0xFF1A2438),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          (post['caption'] ?? 'Community update').toString(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white),
        ),
        subtitle: Text(
          imageData.isEmpty ? 'No image' : 'Image attached',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
        ),
        trailing: Wrap(
          spacing: 0,
          children: [
            IconButton(
              tooltip: 'Edit post',
              icon: const Icon(Icons.edit_outlined, color: Colors.white70),
              onPressed: () => _editPost(post: post),
            ),
            IconButton(
              tooltip: 'Delete post',
              icon: const Icon(Icons.delete_outline, color: Color(0xFFEF5350)),
              onPressed: () => _deleteDocument('community_posts', id),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editSchedule({Map<String, dynamic>? schedule}) async {
    final isEditing = schedule != null;
    final wasteController = TextEditingController(
      text: (schedule?['wasteType'] ?? '').toString(),
    );
    final storedArea = (schedule?['areaCode'] ?? schedule?['areaName'] ?? '')
        .toString();
    String selectedArea = kAreaCodes.contains(storedArea)
        ? storedArea
        : kAreaCodes.first;
    DateTime selectedDate =
        DateTime.tryParse((schedule?['date'] ?? '').toString()) ??
        DateTime.now();
    TimeOfDay selectedTime = _parseTime((schedule?['time'] ?? '').toString());

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(isEditing ? 'Edit schedule' : 'Add schedule'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: wasteController,
                  decoration: const InputDecoration(labelText: 'Waste type'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedArea,
                  decoration: const InputDecoration(labelText: 'Area'),
                  items: kAreaCodes
                      .map(
                        (area) =>
                            DropdownMenuItem(value: area, child: Text(area)),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selectedArea = value);
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Date'),
                  subtitle: Text(_formatScheduleDate(selectedDate)),
                  trailing: const Icon(Icons.calendar_today_outlined),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: selectedDate,
                      firstDate: DateTime.now().subtract(
                        const Duration(days: 3650),
                      ),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (picked != null) {
                      setDialogState(() => selectedDate = picked);
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Time'),
                  subtitle: Text(selectedTime.format(context)),
                  trailing: const Icon(Icons.access_time),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: selectedTime,
                    );
                    if (picked != null) {
                      setDialogState(() => selectedTime = picked);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final wasteType = wasteController.text.trim();
                if (wasteType.isEmpty) return;
                final userId = FirebaseAuth.instance.currentUser?.uid ?? '';
                final docRef = isEditing
                    ? _firestore
                          .collection('schedules')
                          .doc(schedule['id'].toString())
                    : _firestore.collection('schedules').doc();
                final data = <String, dynamic>{
                  'date': _formatScheduleDate(selectedDate),
                  'dayOfWeek': _dayName(selectedDate),
                  'time': selectedTime.format(context),
                  'wasteType': wasteType,
                  'areaCode': selectedArea,
                  'areaName': selectedArea,
                  'status': 'upcoming',
                  'createdBy': schedule?['createdBy'] ?? userId,
                  'updatedBy': userId,
                  'published': true,
                  'updatedAt': FieldValue.serverTimestamp(),
                };
                if (!isEditing) {
                  data['createdAt'] = FieldValue.serverTimestamp();
                }
                await docRef.set(data, SetOptions(merge: true));
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: Text(isEditing ? 'Save changes' : 'Add schedule'),
            ),
          ],
        ),
      ),
    );
    wasteController.dispose();
  }

  Future<void> _editPost({Map<String, dynamic>? post}) async {
    final isEditing = post != null;
    final captionController = TextEditingController(
      text: (post?['caption'] ?? '').toString(),
    );
    String imageData = (post?['imageData'] ?? '').toString();
    if (imageData.isEmpty) {
      final imageUrl = (post?['imageUrl'] ?? '').toString();
      if (imageUrl.startsWith('data:image')) {
        imageData = imageUrl.split('base64,').last;
      }
    }
    bool isPickingImage = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(isEditing ? 'Edit community post' : 'Add community post'),
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
                OutlinedButton.icon(
                  onPressed: isPickingImage
                      ? null
                      : () async {
                          setDialogState(() => isPickingImage = true);
                          try {
                            final image = await _imagePicker.pickImage(
                              source: ImageSource.gallery,
                              imageQuality: 75,
                              maxWidth: 1600,
                            );
                            if (image != null) {
                              imageData = base64Encode(
                                await image.readAsBytes(),
                              );
                            }
                          } finally {
                            setDialogState(() => isPickingImage = false);
                          }
                        },
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(
                    isPickingImage ? 'Loading image...' : 'Choose image',
                  ),
                ),
                if (imageData.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      base64Decode(imageData),
                      height: 180,
                      fit: BoxFit.cover,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => setDialogState(() => imageData = ''),
                    icon: const Icon(Icons.remove_circle_outline),
                    label: const Text('Remove image'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final caption = captionController.text.trim();
                if (caption.isEmpty) return;
                final userId = FirebaseAuth.instance.currentUser?.uid ?? '';
                final docRef = isEditing
                    ? _firestore
                          .collection('community_posts')
                          .doc(post['id'].toString())
                    : _firestore.collection('community_posts').doc();
                final data = <String, dynamic>{
                  'caption': caption,
                  'imageData': imageData,
                  'imageUrl': imageData.isEmpty
                      ? ''
                      : 'data:image/jpeg;base64,$imageData',
                  'author': 'Admin Team',
                  'createdBy': post?['createdBy'] ?? userId,
                  'updatedBy': userId,
                  'published': true,
                  'updatedAt': FieldValue.serverTimestamp(),
                };
                if (!isEditing) {
                  data['createdAt'] = FieldValue.serverTimestamp();
                }
                await docRef.set(data, SetOptions(merge: true));
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: Text(isEditing ? 'Save changes' : 'Publish post'),
            ),
          ],
        ),
      ),
    );
    captionController.dispose();
  }

  Future<void> _deleteDocument(String collection, String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete item?'),
        content: const Text('This item will be removed for residents.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _firestore.collection(collection).doc(id).delete();
    }
  }

  TimeOfDay _parseTime(String value) {
    final match = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(value);
    if (match == null) return const TimeOfDay(hour: 8, minute: 0);
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    final isPm = value.toLowerCase().contains('pm');
    var hour24 = hour % 12;
    if (isPm) hour24 += 12;
    return TimeOfDay(hour: hour24, minute: minute);
  }

  String _formatScheduleDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _dayName(DateTime date) => const [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ][date.weekday - 1];
}
