import 'package:flutter/material.dart';

class SegregationGuide extends StatelessWidget {
  const SegregationGuide({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Waste Segregation Guide'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Resident Guidelines: clear, action-oriented guidance for residents
          Card(
            color: Colors.green[50],
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.home, size: 36, color: Colors.green[700]),
                      const SizedBox(width: 12),
                      Text(
                        'Resident Guidelines',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.green[900],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Practical steps every resident can take to segregate and recycle waste effectively:',
                    style: TextStyle(color: Colors.green[900]),
                  ),
                  const SizedBox(height: 12),
                  _buildTipItem('Separate at source: use separate bags/bins for organics, recyclables, and general waste.'),
                  _buildTipItem('Clean & dry: rinse food residue from cans, bottles and containers before recycling.'),
                  _buildTipItem('Flatten cardboard and remove inserts to save space and improve processing.'),
                  _buildTipItem('Keep hazardous and sharp items (batteries, needles, chemicals) out of household bins — take them to designated collection points.'),
                  _buildTipItem('E-waste: take old electronics to e-waste collection events or drop-off centers.'),
                  _buildTipItem('Compost food scraps and small yard waste at home or use community composting where available.'),
                  _buildTipItem('Bulk items (furniture, mattresses): schedule a special pickup or bring them to the municipal depot.'),
                  const SizedBox(height: 8),
                  Text(
                    'How to recycle correctly:',
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green[900]),
                  ),
                  const SizedBox(height: 8),
                  _buildTipItem('Paper: keep dry and free of food — no greasy pizza boxes.'),
                  _buildTipItem('Plastics: check the recycling number; rinse bottles and remove lids when instructed.'),
                  _buildTipItem('Glass: sort clear/colored when required; wrap broken glass before disposal.'),
                  _buildTipItem('Metals: empty and rinse cans; remove food residue.'),
                  const SizedBox(height: 12),
                  Text(
                    'Reduce & Reuse suggestions:',
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green[900]),
                  ),
                  const SizedBox(height: 8),
                  _buildTipItem('Refuse single-use items when possible; carry a reusable bag and bottle.'),
                  _buildTipItem('Repair and donate usable items instead of throwing them away.'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          // Header
          Card(
            color: Colors.green[50],
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.eco, size: 40, color: Colors.green[700]),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'Proper waste segregation helps protect our environment and makes recycling more efficient.',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.green[900],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Recyclable Section
          _buildSectionHeader(
            'Recyclable Waste',
            Colors.green,
            Icons.recycling,
          ),
          const SizedBox(height: 12),
          _buildWasteCard(
            'Paper & Cardboard',
            Icons.article,
            Colors.blue,
            [
              'Newspapers',
              'Magazines',
              'Office paper',
              'Cardboard boxes',
              'Paper bags',
            ],
          ),
          _buildWasteCard(
            'Plastics',
            Icons.water_drop,
            Colors.cyan,
            [
              'Plastic bottles (PET)',
              'Plastic containers',
              'Plastic bags',
              'Packaging materials',
            ],
          ),
          _buildWasteCard(
            'Glass',
            Icons.wine_bar,
            Colors.teal,
            [
              'Glass bottles',
              'Glass jars',
              'Broken glass (wrapped safely)',
            ],
          ),
          _buildWasteCard(
            'Metals',
            Icons.construction,
            Colors.grey,
            [
              'Aluminum cans',
              'Steel cans',
              'Metal foil',
              'Metal containers',
            ],
          ),

          const SizedBox(height: 32),

          // Non-Recyclable Section
          _buildSectionHeader(
            'Non-Recyclable (General) Waste',
            Colors.grey,
            Icons.delete,
          ),
          const SizedBox(height: 12),
          _buildWasteCard(
            'Food Waste',
            Icons.restaurant,
            Colors.brown,
            [
              'Food scraps',
              'Fruit & vegetable peels',
              'Leftover food',
              'Tea bags',
            ],
          ),
          _buildWasteCard(
            'Mixed/Contaminated Materials',
            Icons.warning,
            Colors.orange,
            [
              'Dirty diapers',
              'Sanitary products',
              'Tissues & napkins',
              'Wax-coated paper',
              'Styrofoam',
            ],
          ),
          _buildWasteCard(
            'Electronic Waste (E-Waste)',
            Icons.phone_android,
            Colors.purple,
            [
              'Old phones',
              'Batteries',
              'Computer parts',
              'Small appliances',
              '⚠️ Take to special collection centers',
            ],
          ),

          const SizedBox(height: 32),

          // Tips Section
          Card(
            color: Colors.blue[50],
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lightbulb, color: Colors.blue[700]),
                      const SizedBox(width: 8),
                      Text(
                        'Quick Tips',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue[900],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildTipItem('Clean and dry recyclables before disposal'),
                  _buildTipItem('Remove caps from bottles'),
                  _buildTipItem('Flatten cardboard boxes to save space'),
                  _buildTipItem('Keep recyclables and general waste separate'),
                  _buildTipItem('Use separate bins for different waste types'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, Color color, IconData icon) {
    return Row(
      children: [
        CircleAvatar(
          backgroundColor: color.withOpacity(0.2),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: 12),
        Text(
          title,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildWasteCard(
    String title,
    IconData icon,
    Color color,
    List<String> items,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 28),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...items.map((item) => Padding(
                  padding: const EdgeInsets.only(left: 40, bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '• ',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[700],
                        ),
                      ),
                      Expanded(
                        child: Text(
                          item,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[700],
                          ),
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildTipItem(String tip) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle, size: 16, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tip,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
