import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Secret code that must be entered to register as an admin.
/// Change this to a more secure value in production.
const String _kAdminCode = 'WASTE_ADMIN_2024';

class AdminSignUpScreen extends StatefulWidget {
  const AdminSignUpScreen({super.key});

  @override
  State<AdminSignUpScreen> createState() => _AdminSignUpScreenState();
}

class _AdminSignUpScreenState extends State<AdminSignUpScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _adminCodeController = TextEditingController();
  final _auth = FirebaseAuth.instance;
  final _firestore = FirebaseFirestore.instance;

  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _obscureAdminCode = true;

  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700));
    _fadeAnim =
        CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
            begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(
            CurvedAnimation(parent: _animController, curve: Curves.easeOut));
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _adminCodeController.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    if (!_formKey.currentState!.validate()) return;

    // Verify admin code
    if (_adminCodeController.text.trim() != _kAdminCode) {
      _showSnackBar('Invalid admin access code.', isError: true);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      if (credential.user != null) {
        final userDocRef =
            _firestore.collection('users').doc(credential.user!.uid);
        Exception? lastError;
        for (int attempt = 1; attempt <= 3; attempt++) {
          try {
            await userDocRef.set({
              'uid': credential.user!.uid,
              'email': _emailController.text.trim(),
              'role': 'admin',
              'name': _nameController.text.trim(),
              'phone': _phoneController.text.trim(),
              'createdAt': FieldValue.serverTimestamp(),
            });
            lastError = null;
            break;
          } catch (e) {
            lastError = Exception(e.toString());
            if (attempt < 3) {
              await Future.delayed(const Duration(milliseconds: 800));
            }
          }
        }
        if (lastError != null) throw lastError;

        if (mounted) {
          _showSnackBar('Admin account created! Redirecting...');
          Navigator.pushReplacementNamed(context, '/admin');
        }
      }
    } on FirebaseAuthException catch (e) {
      String message;
      switch (e.code) {
        case 'email-already-in-use':
          message = 'An account already exists with this email.';
          break;
        case 'invalid-email':
          message = 'Invalid email format.';
          break;
        case 'weak-password':
          message = 'Password is too weak.';
          break;
        default:
          message = 'Sign up failed: ${e.message}';
      }
      _showSnackBar(message, isError: true);
    } catch (e) {
      _showSnackBar('An error occurred: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor:
          isError ? const Color(0xFFD32F2F) : const Color(0xFF388E3C),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  InputDecoration _inputDecoration(String label, IconData icon,
      {Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: const Color(0xFF5C6BC0)),
      suffixIcon: suffix,
      filled: true,
      fillColor: const Color(0xFF1E2A45),
      labelStyle: const TextStyle(color: Color(0xFF8A9BB5)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide:
            const BorderSide(color: Color(0xFF2E3D5E), width: 1.2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide:
            const BorderSide(color: Color(0xFF7C83FD), width: 1.8),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide:
            const BorderSide(color: Color(0xFFEF5350), width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide:
            const BorderSide(color: Color(0xFFEF5350), width: 1.8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101826),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: Color(0xFF8A9BB5)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Admin Registration',
          style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: FadeTransition(
        opacity: _fadeAnim,
        child: SlideTransition(
          position: _slideAnim,
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 16),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header icon
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            colors: [Color(0xFF5C6BC0), Color(0xFF7C83FD)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF5C6BC0)
                                  .withOpacity(0.4),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.admin_panel_settings,
                            size: 40, color: Colors.white),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Create Admin Account',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Enter your details and admin access code',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 32),

                      // Full Name
                      TextFormField(
                        controller: _nameController,
                        style: const TextStyle(color: Colors.white),
                        decoration: _inputDecoration(
                            'Full Name', Icons.person_outline),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return 'Please enter your full name';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),

                      // Email
                      TextFormField(
                        controller: _emailController,
                        style: const TextStyle(color: Colors.white),
                        keyboardType: TextInputType.emailAddress,
                        decoration: _inputDecoration(
                            'Email Address', Icons.email_outlined),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return 'Please enter your email';
                          }
                          if (!v.contains('@')) {
                            return 'Please enter a valid email';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),

                      // Phone
                      TextFormField(
                        controller: _phoneController,
                        style: const TextStyle(color: Colors.white),
                        keyboardType: TextInputType.phone,
                        decoration: _inputDecoration(
                            'Phone Number', Icons.phone_outlined),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return 'Please enter your phone number';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),

                      // Password
                      TextFormField(
                        controller: _passwordController,
                        style: const TextStyle(color: Colors.white),
                        obscureText: _obscurePassword,
                        decoration: _inputDecoration(
                          'Password',
                          Icons.lock_outline,
                          suffix: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              color: const Color(0xFF8A9BB5),
                            ),
                            onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        validator: (v) {
                          if (v == null || v.isEmpty) {
                            return 'Please enter a password';
                          }
                          if (v.length < 6) {
                            return 'Password must be at least 6 characters';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),

                      // Confirm Password
                      TextFormField(
                        controller: _confirmPasswordController,
                        style: const TextStyle(color: Colors.white),
                        obscureText: _obscureConfirm,
                        decoration: _inputDecoration(
                          'Confirm Password',
                          Icons.lock_outline,
                          suffix: IconButton(
                            icon: Icon(
                              _obscureConfirm
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              color: const Color(0xFF8A9BB5),
                            ),
                            onPressed: () => setState(
                                () => _obscureConfirm = !_obscureConfirm),
                          ),
                        ),
                        validator: (v) {
                          if (v == null || v.isEmpty) {
                            return 'Please confirm your password';
                          }
                          if (v != _passwordController.text) {
                            return 'Passwords do not match';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 22),

                      // Admin Code section
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A2438),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: const Color(0xFF5C6BC0).withOpacity(0.4)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.shield_outlined,
                                    color: Color(0xFF7C83FD), size: 18),
                                const SizedBox(width: 8),
                                const Text(
                                  'Admin Access Code',
                                  style: TextStyle(
                                    color: Color(0xFF7C83FD),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Contact your system administrator for this code.',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.4),
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _adminCodeController,
                              style: const TextStyle(
                                  color: Colors.white,
                                  letterSpacing: 2,
                                  fontWeight: FontWeight.w600),
                              obscureText: _obscureAdminCode,
                              decoration: _inputDecoration(
                                'Access Code',
                                Icons.key_outlined,
                                suffix: IconButton(
                                  icon: Icon(
                                    _obscureAdminCode
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    color: const Color(0xFF8A9BB5),
                                  ),
                                  onPressed: () => setState(() =>
                                      _obscureAdminCode = !_obscureAdminCode),
                                ),
                              ),
                              validator: (v) {
                                if (v == null || v.trim().isEmpty) {
                                  return 'Please enter the admin access code';
                                }
                                return null;
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),

                      // Sign Up Button
                      SizedBox(
                        height: 56,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _signUp,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: EdgeInsets.zero,
                          ),
                          child: Ink(
                            decoration: BoxDecoration(
                              gradient: _isLoading
                                  ? const LinearGradient(
                                      colors: [
                                        Color(0xFF3A4060),
                                        Color(0xFF3A4060),
                                      ],
                                    )
                                  : const LinearGradient(
                                      colors: [
                                        Color(0xFF5C6BC0),
                                        Color(0xFF7C83FD),
                                      ],
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                    ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Container(
                              alignment: Alignment.center,
                              child: _isLoading
                                  ? const SizedBox(
                                      height: 22,
                                      width: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text(
                                      'Create Admin Account',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Already have account
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'Already have an admin account?',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.5),
                                fontSize: 14),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pushReplacementNamed(
                                  context, '/admin-signin');
                            },
                            child: const Text(
                              'Sign In',
                              style: TextStyle(
                                color: Color(0xFF7C83FD),
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
