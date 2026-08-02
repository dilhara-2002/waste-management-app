import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _auth = FirebaseAuth.instance;
  final _firestore = FirebaseFirestore.instance;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _checkCurrentUser();
  }

  // Check if user is already logged in
  Future<void> _checkCurrentUser() async {
    final user = _auth.currentUser;
    if (user != null) {
      await _navigateBasedOnRole(user.uid);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      _showSnackBar('Please enter email and password');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      if (credential.user != null && mounted) {
        await _navigateBasedOnRole(credential.user!.uid);
      }
    } on FirebaseAuthException catch (e) {
      String message = 'Login failed';
      
      switch (e.code) {
        case 'user-not-found':
          message = '❌ No user found with this email.\nTry the Quick Register buttons below.';
          break;
        case 'wrong-password':
          message = '❌ Wrong password.\nTry: test123';
          break;
        case 'invalid-email':
          message = '❌ Invalid email format';
          break;
        case 'user-disabled':
          message = '❌ This account has been disabled';
          break;
        case 'invalid-credential':
          message = '❌ Invalid credentials.\nUse Quick Register buttons to create test account.';
          break;
        default:
          message = '❌ Login failed: ${e.code}\n${e.message}';
      }
      _showSnackBar(message);
      debugPrint('Firebase Auth Error: ${e.code} - ${e.message}');
    } catch (e) {
      _showSnackBar('❌ An error occurred: $e');
      debugPrint('Login Error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _navigateBasedOnRole(String uid) async {
    try {
      final userDoc = await _firestore.collection('users').doc(uid).get();

      if (!userDoc.exists) {
        _showSnackBar('User profile not found. Please register again.');
        await _auth.signOut();
        return;
      }

      final role = userDoc.data()?['role'] as String?;

      if (!mounted) return;

      if (role == 'resident') {
        Navigator.pushReplacementNamed(context, '/resident');
      } else if (role == 'collector') {
        Navigator.pushReplacementNamed(context, '/collector');
      } else {
        _showSnackBar('Invalid user role');
        await _auth.signOut();
      }
    } catch (e) {
      _showSnackBar('Error fetching user data: $e');
    }
  }

  // Quick register for testing
  Future<void> _quickRegister(String role) async {
    final email = '${role}@test.com';
    const password = 'test123';

    setState(() => _isLoading = true);

    try {
      // Try to sign in first
      try {
        final credential = await _auth.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
        
        if (credential.user != null && mounted) {
          _showSnackBar('✅ Logged in as $role');
          await _navigateBasedOnRole(credential.user!.uid);
        }
        return;
      } on FirebaseAuthException catch (e) {
        if (e.code != 'user-not-found' && e.code != 'invalid-credential') {
          throw e;
        }
        // User doesn't exist, continue to create
        debugPrint('User not found, creating new account...');
      }

      // User doesn't exist, create new account
      debugPrint('Creating new user: $email');
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (credential.user != null) {
        debugPrint('User created, adding to Firestore...');
        // Create user document in Firestore
        await _firestore.collection('users').doc(credential.user!.uid).set({
          'uid': credential.user!.uid,
          'email': email,
          'role': role,
          'address': 'Colombo, Sri Lanka',
          'createdAt': FieldValue.serverTimestamp(),
        });

        debugPrint('User document created successfully');
        if (mounted) {
          _showSnackBar('✅ Test account created!\nEmail: $email\nPassword: $password');
          await _navigateBasedOnRole(credential.user!.uid);
        }
      }
    } on FirebaseAuthException catch (e) {
      String message = 'Registration failed';
      
      switch (e.code) {
        case 'email-already-in-use':
          message = '⚠️ Account exists. Trying to login...';
          // Try to login
          try {
            final credential = await _auth.signInWithEmailAndPassword(
              email: email,
              password: password,
            );
            if (credential.user != null && mounted) {
              await _navigateBasedOnRole(credential.user!.uid);
              return;
            }
          } catch (loginError) {
            message = '❌ Account exists but password might be different';
          }
          break;
        case 'operation-not-allowed':
          message = '❌ Email/Password authentication is not enabled.\n\n'
              'Please enable it in Firebase Console:\n'
              '1. Go to Firebase Console\n'
              '2. Authentication > Sign-in method\n'
              '3. Enable Email/Password';
          break;
        default:
          message = '❌ Registration failed: ${e.code}\n${e.message}';
      }
      _showSnackBar(message);
      debugPrint('Firebase Auth Error: ${e.code} - ${e.message}');
    } catch (e) {
      _showSnackBar('❌ An error occurred: $e');
      debugPrint('Registration Error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      _showSnackBar('Please enter your email to reset password');
      return;
    }

    try {
      setState(() => _isLoading = true);
      await _auth.sendPasswordResetEmail(email: email);

      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Password Reset Email Sent'),
          content: Text('A password reset link has been sent to $email. Check your inbox.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } on FirebaseAuthException catch (e) {
      String message = 'Failed to send reset email.';
      switch (e.code) {
        case 'user-not-found':
          message = 'No user found for this email.';
          break;
        case 'invalid-email':
          message = 'Invalid email format.';
          break;
        default:
          message = 'Error: ${e.message ?? e.code}';
      }
      _showSnackBar(message);
      debugPrint('Password reset error: ${e.code} - ${e.message}');
    } catch (e) {
      _showSnackBar('An error occurred: $e');
      debugPrint('Password reset exception: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'OK',
          onPressed: () {},
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // App Logo/Title
                const Icon(
                  Icons.recycling,
                  size: 80,
                  color: Colors.green,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Waste Management',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Text(
                  'MVP System',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 48),

                // Email field
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.email),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),

                // Password field
                TextField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 24),

                // Login button
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _login,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Login',
                            style: TextStyle(fontSize: 16),
                          ),
                  ),
                ),

                const SizedBox(height: 12),

                // Forgot password
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _isLoading ? null : _forgotPassword,
                    child: const Text('Forgot Password?'),
                  ),
                ),

                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 16),

                // Quick Register Section
                const Text(
                  'Quick Test Accounts',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),

                // Quick register buttons
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isLoading ? null : () => _quickRegister('resident'),
                        icon: const Icon(Icons.person),
                        label: const Text('Resident'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.blue,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isLoading ? null : () => _quickRegister('collector'),
                        icon: const Icon(Icons.local_shipping),
                        label: const Text('Collector'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.orange,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 8),
                Text(
                  'Creates test@test.com / test123',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
