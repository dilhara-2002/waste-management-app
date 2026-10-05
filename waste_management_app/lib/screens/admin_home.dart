import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';

class AdminHome extends StatefulWidget {
  const AdminHome({super.key});

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome>
    with SingleTickerProviderStateMixin {
  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  int _currentTab = 0; // 0: Dashboard, 1: Reports, 2: Feedback, 3: Users
  Map<String, dynamic>? _adminData;
  late TabController _tabController;

  // Stats
  int _totalReports = 0;
  int _pendingReports = 0;
  int _resolvedReports = 0;
  int _totalFeedback = 0;
  int _totalUsers = 0;
  int _totalCollectors = 0;

  StreamSubscription? _reportsSub;
  StreamSubscription? _feedbackSub;
  StreamSubscription? _usersSub;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        setState(() => _currentTab = _tabController.index);
      }
    });
    _loadAdminData();
    _subscribeToStats();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _reportsSub?.cancel();
    _feedbackSub?.cancel();
    _usersSub?.cancel();
    super.dispose();
  }

  Future<void> _loadAdminData() async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      final doc = await _firestore.collection('users').doc(user.uid).get();
      if (mounted && doc.exists) {
        setState(() => _adminData = doc.data());
      }
    } catch (_) {}
  }

  void _subscribeToStats() {
    // Reports stats
    _reportsSub = _firestore
        .collection('reports')
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      final docs = snapshot.docs;
      int pending = 0, resolved = 0;
      for (final doc in docs) {
        final status =
            ((doc.data()['status'] ?? '') as String).toLowerCase();
        if (status.contains('resolved')) {
          resolved++;
        } else {
          pending++;
        }
      }
      setState(() {
        _totalReports = docs.length;
        _pendingReports = pending;
        _resolvedReports = resolved;
      });
    });

    // Feedback stats
    _feedbackSub = _firestore
        .collection('feedback')
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      setState(() => _totalFeedback = snapshot.docs.length);
    });

    // Users stats
    _usersSub = _firestore
        .collection('users')
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      int collectors = 0;
      for (final doc in snapshot.docs) {
        if ((doc.data()['role'] ?? '') == 'collector') collectors++;
      }
      setState(() {
        _totalUsers = snapshot.docs.length;
        _totalCollectors = collectors;
      });
    });
  }

  Future<void> _updateReportStatus(String docId, String newStatus) async {
    try {
      await _firestore
          .collection('reports')
          .doc(docId)
          .update({'status': newStatus});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Status updated to "$newStatus"'),
          backgroundColor: const Color(0xFF388E3C),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to update: $e'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  Future<void> _deleteFeedback(String docId) async {
    try {
      await _firestore.collection('feedback').doc(docId).delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Feedback deleted.'),
          backgroundColor: const Color(0xFF388E3C),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to delete: $e'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  Future<void> _signOut() async {
    await _auth.signOut();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/');
    }
  }

  // ─────────────────────────────────── BUILD ───────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101826),
      body: Column(
        children: [
          _buildHeader(),
          _buildTabBar(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildDashboardTab(),
                _buildReportsTab(),
                _buildFeedbackTab(),
                _buildUsersTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────── HEADER ──────────────────────────────────

  Widget _buildHeader() {
    final name = _adminData?['name'] as String? ?? 'Admin';
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 12,
        left: 20,
        right: 20,
        bottom: 16,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1A2438), Color(0xFF141E30)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFF5C6BC0), Color(0xFF7C83FD)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF5C6BC0).withOpacity(0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(Icons.admin_panel_settings,
                color: Colors.white, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hello, $name 👋',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Admin Dashboard',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: Color(0xFF8A9BB5)),
            tooltip: 'Sign Out',
            onPressed: _confirmSignOut,
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2A45),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Sign Out',
            style: TextStyle(color: Colors.white)),
        content: Text('Are you sure you want to sign out?',
            style: TextStyle(color: Colors.white.withOpacity(0.7))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel',
                style: TextStyle(color: Colors.white.withOpacity(0.5))),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign Out',
                style: TextStyle(
                    color: Color(0xFF7C83FD),
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed == true) _signOut();
  }

  // ──────────────────────────────────── TAB BAR ────────────────────────────────

  Widget _buildTabBar() {
    final tabs = [
      (Icons.dashboard_rounded, 'Dashboard'),
      (Icons.article_outlined, 'Reports'),
      (Icons.feedback_outlined, 'Feedback'),
      (Icons.people_outline, 'Users'),
    ];

    return Container(
      color: const Color(0xFF141E30),
      child: TabBar(
        controller: _tabController,
        indicatorColor: const Color(0xFF7C83FD),
        indicatorWeight: 3,
        labelColor: const Color(0xFF7C83FD),
        unselectedLabelColor: const Color(0xFF8A9BB5),
        labelStyle:
            const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        tabs: tabs
            .map((t) => Tab(icon: Icon(t.$1, size: 20), text: t.$2))
            .toList(),
      ),
    );
  }

  // ─────────────────────────────── DASHBOARD TAB ───────────────────────────────

  Widget _buildDashboardTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          _sectionLabel('Overview'),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.5,
            children: [
              _statCard('Total Reports', '$_totalReports',
                  Icons.article_rounded, const Color(0xFF5C6BC0)),
              _statCard('Pending', '$_pendingReports',
                  Icons.pending_actions_rounded, const Color(0xFFF57C00)),
              _statCard('Resolved', '$_resolvedReports',
                  Icons.check_circle_rounded, const Color(0xFF388E3C)),
              _statCard('Feedback', '$_totalFeedback',
                  Icons.star_rounded, const Color(0xFFAB47BC)),
              _statCard('Total Users', '$_totalUsers',
                  Icons.people_rounded, const Color(0xFF0288D1)),
              _statCard('Collectors', '$_totalCollectors',
                  Icons.local_shipping_rounded, const Color(0xFFE53935)),
            ],
          ),
          const SizedBox(height: 24),
          _sectionLabel('Recent Reports'),
          const SizedBox(height: 12),
          _buildRecentReportsMini(),
          const SizedBox(height: 24),
          _sectionLabel('Recent Feedback'),
          const SizedBox(height: 12),
          _buildRecentFeedbackMini(),
        ],
      ),
    );
  }

  Widget _statCard(
      String label, String value, IconData icon, Color color) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A2438),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: color,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecentReportsMini() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('reports')
          .orderBy('createdAt', descending: true)
          .limit(3)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return _emptyCard('No reports yet');
        }
        return Column(
          children: snapshot.data!.docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            return _miniReportCard(data);
          }).toList(),
        );
      },
    );
  }

  Widget _miniReportCard(Map<String, dynamic> data) {
    final status = (data['status'] ?? 'Submitted') as String;
    final type = (data['type'] ?? 'Issue') as String;
    final ts = data['createdAt'] as Timestamp?;
    final dateStr = ts != null
        ? _formatDate(ts.toDate())
        : 'Just now';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2438),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2E3D5E)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF5C6BC0).withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.article_outlined,
                color: Color(0xFF7C83FD), size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(type,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                Text(dateStr,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.4), fontSize: 12)),
              ],
            ),
          ),
          _statusChip(status),
        ],
      ),
    );
  }

  Widget _buildRecentFeedbackMini() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('feedback')
          .orderBy('createdAt', descending: true)
          .limit(3)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return _emptyCard('No feedback yet');
        }
        return Column(
          children: snapshot.data!.docs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final msg = (data['message'] ?? '') as String;
            final ts = data['createdAt'] as Timestamp?;
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2438),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF2E3D5E)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFAB47BC).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.feedback_outlined,
                        color: Color(0xFFAB47BC), size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          msg.length > 80
                              ? '${msg.substring(0, 80)}...'
                              : msg,
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontSize: 13),
                        ),
                        if (ts != null) ...[
                          const SizedBox(height: 4),
                          Text(_formatDate(ts.toDate()),
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.4),
                                  fontSize: 12)),
                        ]
                      ],
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

  // ─────────────────────────────── REPORTS TAB ─────────────────────────────────

  Widget _buildReportsTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Icon(Icons.article_rounded,
                  color: Color(0xFF7C83FD), size: 22),
              const SizedBox(width: 8),
              const Text(
                'All Reports',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF5C6BC0).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$_totalReports total',
                  style: const TextStyle(
                      color: Color(0xFF7C83FD),
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: _firestore
                .collection('reports')
                .orderBy('createdAt', descending: true)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFF7C83FD)));
              }
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return _emptyScreen(Icons.article_outlined,
                    'No reports submitted yet');
              }

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: snapshot.data!.docs.length,
                itemBuilder: (context, index) {
                  final doc = snapshot.data!.docs[index];
                  final data = doc.data() as Map<String, dynamic>;
                  return _reportCard(doc.id, data);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _reportCard(String docId, Map<String, dynamic> data) {
    final status = (data['status'] ?? 'Submitted') as String;
    final type = (data['type'] ?? 'Issue') as String;
    final description = (data['description'] ?? '') as String;
    final userId = (data['userId'] ?? '') as String;
    final ts = data['createdAt'] as Timestamp?;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2438),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF2E3D5E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF5C6BC0).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.report_problem_outlined,
                      color: Color(0xFF7C83FD), size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(type,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 15)),
                      if (ts != null)
                        Text(_formatDate(ts.toDate()),
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.4),
                                fontSize: 12)),
                    ],
                  ),
                ),
                _statusChip(status),
              ],
            ),
          ),
          if (description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text(
                description,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 13,
                    height: 1.4),
              ),
            ),
          if (userId.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: FutureBuilder<DocumentSnapshot>(
                future:
                    _firestore.collection('users').doc(userId).get(),
                builder: (ctx, snap) {
                  String name = userId;
                  if (snap.hasData && snap.data != null && snap.data!.exists) {
                    final d = snap.data!.data() as Map<String, dynamic>?;
                    name = (d?['name'] as String?) ?? userId;
                  }
                  return Row(
                    children: [
                      Icon(Icons.person_outline,
                          size: 14,
                          color: Colors.white.withOpacity(0.35)),
                      const SizedBox(width: 4),
                      Text(
                        'Submitted by: $name',
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.4),
                            fontSize: 12),
                      ),
                    ],
                  );
                },
              ),
            ),
          const SizedBox(height: 12),
          Divider(height: 1, color: const Color(0xFF2E3D5E)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _actionBtn(
                  'In Review',
                  Icons.visibility_outlined,
                  const Color(0xFFF57C00),
                  () => _updateReportStatus(docId, 'In Review'),
                ),
                _dividerV(),
                _actionBtn(
                  'Resolved',
                  Icons.check_circle_outline,
                  const Color(0xFF388E3C),
                  () => _updateReportStatus(docId, 'Resolved'),
                ),
                _dividerV(),
                _actionBtn(
                  'Rejected',
                  Icons.cancel_outlined,
                  const Color(0xFFD32F2F),
                  () => _updateReportStatus(docId, 'Rejected'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────── FEEDBACK TAB ────────────────────────────────

  Widget _buildFeedbackTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Icon(Icons.feedback_rounded,
                  color: Color(0xFFAB47BC), size: 22),
              const SizedBox(width: 8),
              const Text(
                'Resident Feedback',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFAB47BC).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$_totalFeedback total',
                  style: const TextStyle(
                      color: Color(0xFFAB47BC),
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: _firestore
                .collection('feedback')
                .orderBy('createdAt', descending: true)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFFAB47BC)));
              }
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return _emptyScreen(Icons.feedback_outlined,
                    'No feedback submitted yet');
              }

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: snapshot.data!.docs.length,
                itemBuilder: (context, index) {
                  final doc = snapshot.data!.docs[index];
                  final data = doc.data() as Map<String, dynamic>;
                  return _feedbackCard(doc.id, data);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _feedbackCard(String docId, Map<String, dynamic> data) {
    final message = (data['message'] ?? '') as String;
    final userId = (data['userId'] ?? '') as String;
    final ts = data['createdAt'] as Timestamp?;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2438),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF2E3D5E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFAB47BC).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.chat_bubble_outline,
                    color: Color(0xFFAB47BC), size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FutureBuilder<DocumentSnapshot?>(
                      future: userId.isNotEmpty
                          ? _firestore.collection('users').doc(userId).get()
                          : Future<DocumentSnapshot?>.value(null),
                      builder: (ctx, snap) {
                        String name = 'Anonymous';
                        if (snap.hasData &&
                            snap.data != null &&
                            snap.data!.exists) {
                          final d = snap.data!.data() as Map<String, dynamic>?;
                          name = (d?['name'] as String?) ?? 'Anonymous';
                        }
                        return Text(name,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 14));
                      },
                    ),
                    if (ts != null)
                      Text(_formatDate(ts.toDate()),
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.4),
                              fontSize: 12)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: Color(0xFFEF5350), size: 20),
                tooltip: 'Delete',
                onPressed: () => _confirmDeleteFeedback(docId),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: TextStyle(
                color: Colors.white.withOpacity(0.8),
                fontSize: 14,
                height: 1.5),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteFeedback(String docId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2A45),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete Feedback',
            style: TextStyle(color: Colors.white)),
        content: Text('Remove this feedback entry?',
            style: TextStyle(color: Colors.white.withOpacity(0.7))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel',
                style: TextStyle(color: Colors.white.withOpacity(0.5))),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete',
                style: TextStyle(
                    color: Color(0xFFEF5350),
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed == true) _deleteFeedback(docId);
  }

  // ─────────────────────────────────── USERS TAB ───────────────────────────────

  Widget _buildUsersTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Icon(Icons.people_rounded,
                  color: Color(0xFF0288D1), size: 22),
              const SizedBox(width: 8),
              const Text(
                'All Users',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF0288D1).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$_totalUsers total',
                  style: const TextStyle(
                      color: Color(0xFF0288D1),
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: _firestore
                .collection('users')
                .orderBy('createdAt', descending: true)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFF0288D1)));
              }
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return _emptyScreen(
                    Icons.people_outline, 'No users found');
              }

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: snapshot.data!.docs.length,
                itemBuilder: (context, index) {
                  final doc = snapshot.data!.docs[index];
                  final data = doc.data() as Map<String, dynamic>;
                  return _userCard(data);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _userCard(Map<String, dynamic> data) {
    final name = (data['name'] ?? 'Unknown') as String;
    final email = (data['email'] ?? '') as String;
    final role = (data['role'] ?? 'resident') as String;
    final phone = (data['phone'] ?? '') as String;
    final ts = data['createdAt'] as Timestamp?;

    Color roleColor;
    IconData roleIcon;
    switch (role) {
      case 'admin':
        roleColor = const Color(0xFF7C83FD);
        roleIcon = Icons.admin_panel_settings;
        break;
      case 'collector':
        roleColor = const Color(0xFFE53935);
        roleIcon = Icons.local_shipping;
        break;
      default:
        roleColor = const Color(0xFF0288D1);
        roleIcon = Icons.home;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2438),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2E3D5E)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: roleColor.withOpacity(0.15),
            ),
            child: Icon(roleIcon, color: roleColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14)),
                Text(email,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 12)),
                if (phone.isNotEmpty)
                  Text(phone,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.4),
                          fontSize: 12)),
                if (ts != null)
                  Text('Joined ${_formatDate(ts.toDate())}',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.3),
                          fontSize: 11)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: roleColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: roleColor.withOpacity(0.3)),
            ),
            child: Text(
              role[0].toUpperCase() + role.substring(1),
              style: TextStyle(
                  color: roleColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────── HELPERS ─────────────────────────────────

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 18,
        fontWeight: FontWeight.w800,
      ),
    );
  }

  Widget _statusChip(String status) {
    Color color;
    if (status.toLowerCase().contains('resolved')) {
      color = const Color(0xFF388E3C);
    } else if (status.toLowerCase().contains('review')) {
      color = const Color(0xFFF57C00);
    } else if (status.toLowerCase().contains('reject')) {
      color = const Color(0xFFD32F2F);
    } else {
      color = const Color(0xFF5C6BC0);
    }
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        status,
        style: TextStyle(
            color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _actionBtn(
      String label, IconData icon, Color color, VoidCallback onTap) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: color),
      label: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      ),
    );
  }

  Widget _dividerV() {
    return Container(
        width: 1, height: 24, color: const Color(0xFF2E3D5E));
  }

  Widget _emptyCard(String text) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2438),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2E3D5E)),
      ),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
              color: Colors.white.withOpacity(0.4), fontSize: 14),
        ),
      ),
    );
  }

  Widget _emptyScreen(IconData icon, String text) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 60, color: Colors.white.withOpacity(0.15)),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(
                color: Colors.white.withOpacity(0.3), fontSize: 16),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }
}
