import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import '../services/signup_access_code_service.dart';
import '../utils/area_options.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  static String? normalizeResidentAccessCode(String value) {
    final normalized = value.trim().toUpperCase().replaceFirst('/', '');
    return RegExp(r'^R(00[1-9]|0[1-9][0-9]|100)$').hasMatch(normalized)
        ? normalized
        : null;
  }

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _accessCodeController = TextEditingController();
  final _auth = FirebaseAuth.instance;
  final _firestore = FirebaseFirestore.instance;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  String _role = 'resident';
  String _selectedAreaCode = kAreaCodes.first;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Get role from navigation arguments
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is String && args != _role) {
      setState(() {
        _role = args;
      });
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _accessCodeController.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    if (!_formKey.currentState!.validate()) return;

    final accessCode = _role == 'resident'
        ? SignUpScreen.normalizeResidentAccessCode(_accessCodeController.text)
        : null;
    setState(() => _isLoading = true);
    User? newUser;

    try {
      if (_role == 'collector') {
        final collectorCode = await SignupAccessCodeService.getCode(
          _firestore,
          SignupAccessCodeType.collector,
        );
        if (!SignupAccessCodeType.collector.matches(
          _accessCodeController.text,
          collectorCode,
        )) {
          _showSnackBar('Invalid collector access code.', isError: true);
          return;
        }
      }

      final credential = await _auth.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      newUser = credential.user;

      if (newUser != null) {
        final userDocRef = _firestore.collection('users').doc(newUser.uid);
        final accessCodeRef = accessCode == null
            ? null
            : _firestore.collection('resident_access_codes').doc(accessCode);

        await _firestore.runTransaction((transaction) async {
          if (accessCodeRef != null) {
            final accessCodeSnapshot = await transaction.get(accessCodeRef);
            if (accessCodeSnapshot.exists) {
              throw _ResidentAccessCodeAlreadyUsedException();
            }
            transaction.set(accessCodeRef, {
              'uid': newUser!.uid,
              'code': accessCode,
              'claimedAt': FieldValue.serverTimestamp(),
            });
          }

          transaction.set(userDocRef, {
            'uid': credential.user!.uid,
            'email': _emailController.text.trim(),
            'role': _role,
            'name': _nameController.text.trim(),
            'phone': _phoneController.text.trim(),
            'areaCode': _role == 'resident' ? _selectedAreaCode : '',
            if (accessCode != null) 'accessCode': accessCode,
            'createdAt': FieldValue.serverTimestamp(),
          });
        });

        if (mounted) {
          _showSnackBar('Account created successfully! Redirecting...');
          final targetRoute = _role == 'collector' ? '/collector' : '/resident';
          Navigator.pushReplacementNamed(context, targetRoute);
        }
      }
    } on _ResidentAccessCodeAlreadyUsedException {
      final cleanupError = await _deleteUnfinishedUser(newUser);
      _showSnackBar(
        cleanupError == null
            ? 'This resident access code has already been used.'
            : 'This resident access code has already been used. $cleanupError',
        isError: true,
      );
    } on FirebaseAuthException catch (e) {
      String message = 'Sign up failed';

      switch (e.code) {
        case 'email-already-in-use':
          message = 'An account already exists with this email';
          break;
        case 'invalid-email':
          message = 'Invalid email format';
          break;
        case 'weak-password':
          message = 'Password is too weak';
          break;
        case 'operation-not-allowed':
          message = 'Email/Password authentication is not enabled';
          break;
        default:
          message = 'Sign up failed: ${e.message}';
      }
      _showSnackBar(message, isError: true);
    } on FirebaseException catch (e) {
      final cleanupError = await _deleteUnfinishedUser(newUser);
      final message = e.code == 'permission-denied'
          ? 'Signup was blocked by Firestore security rules. Publish the current Firestore rules and try again.'
          : 'Could not save signup data (${e.code}): ${e.message ?? 'Unknown Firebase error'}';
      _showSnackBar(
        cleanupError == null ? message : '$message $cleanupError',
        isError: true,
      );
    } catch (e) {
      final cleanupError = await _deleteUnfinishedUser(newUser);
      final message = 'An error occurred: $e';
      _showSnackBar(
        cleanupError == null ? message : '$message $cleanupError',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<String?> _deleteUnfinishedUser(User? user) async {
    if (user == null) return null;
    try {
      await user.delete();
      return null;
    } on FirebaseAuthException catch (e) {
      return 'The incomplete account could not be removed (${e.code}).';
    } catch (e) {
      return 'The incomplete account could not be removed: $e';
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Color get _roleColor => _role == 'resident' ? Colors.blue : Colors.orange;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign Up'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Role indicator
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _roleColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _roleColor),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _role == 'resident'
                              ? Icons.home
                              : Icons.local_shipping,
                          color: _roleColor,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Signing up as ${_role == 'resident' ? 'Resident' : 'Collector'}',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: _roleColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Full Name field
                  TextFormField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: 'Full Name',
                      prefixIcon: const Icon(Icons.person_outline),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: Colors.grey[50],
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter your full name';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Email field
                  TextFormField(
                    controller: _emailController,
                    decoration: InputDecoration(
                      labelText: 'Email',
                      prefixIcon: const Icon(Icons.email_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: Colors.grey[50],
                    ),
                    keyboardType: TextInputType.emailAddress,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter your email';
                      }
                      if (!value.contains('@')) {
                        return 'Please enter a valid email';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Password field
                  TextFormField(
                    controller: _passwordController,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: Colors.grey[50],
                    ),
                    obscureText: _obscurePassword,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter a password';
                      }
                      if (value.length < 6) {
                        return 'Password must be at least 6 characters';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Confirm Password field
                  TextFormField(
                    controller: _confirmPasswordController,
                    decoration: InputDecoration(
                      labelText: 'Confirm Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureConfirmPassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscureConfirmPassword = !_obscureConfirmPassword;
                          });
                        },
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: Colors.grey[50],
                    ),
                    obscureText: _obscureConfirmPassword,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please confirm your password';
                      }
                      if (value != _passwordController.text) {
                        return 'Passwords do not match';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Phone field
                  TextFormField(
                    controller: _phoneController,
                    decoration: InputDecoration(
                      labelText: 'Phone Number',
                      prefixIcon: const Icon(Icons.phone_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: Colors.grey[50],
                    ),
                    keyboardType: TextInputType.phone,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter your phone number';
                      }
                      return null;
                    },
                  ),
                  if (_role == 'resident' || _role == 'collector') ...[
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _accessCodeController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        labelText:
                            '${_role == 'resident' ? 'Resident' : 'Collector'} access code',
                        prefixIcon: const Icon(Icons.key_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: Colors.grey[50],
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter your ${_role == 'resident' ? 'resident' : 'collector'} access code';
                        }
                        if (_role == 'resident' &&
                            SignUpScreen.normalizeResidentAccessCode(value) ==
                                null) {
                          return 'Invalid resident access code';
                        }
                        return null;
                      },
                    ),
                  ],
                  if (_role == 'resident') ...[
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: _selectedAreaCode,
                      decoration: InputDecoration(
                        labelText: 'Area code',
                        prefixIcon: const Icon(Icons.map_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: Colors.grey[50],
                      ),
                      items: kAreaCodes
                          .map(
                            (area) => DropdownMenuItem<String>(
                              value: area,
                              child: Text(area),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _selectedAreaCode = value;
                        });
                      },
                    ),
                  ],
                  const SizedBox(height: 24),

                  // Sign Up button
                  SizedBox(
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _signUp,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _roleColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
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
                              'Sign Up',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Already have account
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Already have an account?',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pushReplacementNamed(context, '/signin');
                        },
                        child: const Text(
                          'Sign In',
                          style: TextStyle(fontWeight: FontWeight.bold),
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
    );
  }
}

class _ResidentAccessCodeAlreadyUsedException implements Exception {}
