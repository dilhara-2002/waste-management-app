import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class MapWidget extends StatelessWidget {
  const MapWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return FutureBuilder<DocumentSnapshot?>(
      future: user == null
          ? Future.value(null)
          : FirebaseFirestore.instance.collection('users').doc(user.uid).get(),
      builder: (context, userSnap) {
        String? areaCode;
        if (userSnap.hasData && userSnap.data != null && userSnap.data!.exists) {
          final data = userSnap.data!.data() as Map<String, dynamic>?;
          areaCode = data?['areaCode']?.toString()?.trim();
        }

        final stream = (areaCode != null && areaCode.isNotEmpty)
            ? FirebaseFirestore.instance.collection('truck_locations').where('areaCode', isEqualTo: areaCode).snapshots()
            : FirebaseFirestore.instance.collection('truck_locations').snapshots();

        return StreamBuilder<QuerySnapshot>(
          stream: stream,
          builder: (context, snapshot) {
        List<Marker> markers = [];

        // Add truck markers if data is available
        if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
          for (var doc in snapshot.data!.docs) {
            final data = doc.data() as Map<String, dynamic>;
            final latitude = data['latitude'] as double?;
            final longitude = data['longitude'] as double?;

            if (latitude != null && longitude != null) {
              markers.add(
                Marker(
                  point: LatLng(latitude, longitude),
                  width: 100,
                  height: 100,
                  builder: (context) => Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
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
                      const Icon(
                        Icons.local_shipping,
                        color: Colors.blue,
                        size: 40,
                      ),
                    ],
                  ),
                ),
              );
            }
          }
        }

        return Stack(
          children: [
            FlutterMap(
              options: MapOptions(
                center: LatLng(6.9271, 79.8612), // Colombo, Sri Lanka
                zoom: 13.0,
                minZoom: 5.0,
                maxZoom: 18.0,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.waste_management_app',
                  maxZoom: 19,
                ),
                MarkerLayer(markers: markers),
              ],
            ),
            // Info overlay
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, color: Colors.blue),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          snapshot.hasData && snapshot.data!.docs.isNotEmpty
                              ? '${markers.length} truck(s) active'
                              : 'No trucks currently active',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
