import 'package:flutter/material.dart';
import 'package:snap_salat_api/snap_salat_api.dart';

import '../main.dart';
import '../theme.dart';

enum _Mode { signIn, register, token }

/// Signs in to the chosen masjid's endpoint, or registers as a new
/// volunteer (who then waits for the masjid to approve them), or uses an
/// access token the masjid issued. Pops with `true` once signed in.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  final _contact = TextEditingController();
  final _note = TextEditingController();
  final _token = TextEditingController();
  ServerInfo? _info;
  _Mode _mode = _Mode.signIn;
  String? _error;
  Map<String, String> _fieldErrors = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = AppScope.read(context);
    setState(() => _error = null);
    final info = state.serverInfo ?? await state.refreshServerInfo();
    if (!mounted) return;
    setState(() {
      _info = info;
      if (info != null && !info.authMethods.contains(AuthMethod.password)) {
        _mode = _Mode.token;
      }
      if (info == null) {
        _error = "Couldn't reach ${state.masjid?.api.host}. "
            'Check your connection and try again.';
      }
    });
  }

  Future<void> _submit() async {
    final state = AppScope.read(context);
    final api = state.api!;
    setState(() {
      _busy = true;
      _error = null;
      _fieldErrors = const {};
    });
    try {
      switch (_mode) {
        case _Mode.register:
          await api.register(
            username: _user.text.trim(),
            password: _password.text,
            name: _name.text.trim(),
            contact: _contact.text.trim(),
            note: _note.text.trim(),
          );
          // Sign straight in, so the app can show their approval status.
          await state
              .saveSession(await api.login(_user.text.trim(), _password.text));
        case _Mode.signIn:
          await state
              .saveSession(await api.login(_user.text.trim(), _password.text));
        case _Mode.token:
          final token = _token.text.trim();
          final volunteer = await api.check(token);
          await state.saveSession(Session(token, userName: volunteer.name));
      }
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() {
        _fieldErrors = e.fields;
        _error = e.status == 401
            ? (_mode == _Mode.token
                ? 'That token was not accepted.'
                : 'Wrong username or password.')
            : e.message;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    for (final c in [_user, _password, _name, _contact, _note, _token]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(TextEditingController c, String label,
          {String? key,
          String? helper,
          bool obscure = false,
          List<String> autofill = const [],
          TextInputType? keyboard,
          int maxLines = 1,
          bool last = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          obscureText: obscure,
          autocorrect: false,
          keyboardType: keyboard,
          maxLines: maxLines,
          autofillHints: autofill,
          textInputAction: last ? TextInputAction.done : TextInputAction.next,
          onSubmitted: last ? (_) => _submit() : null,
          decoration: InputDecoration(
              labelText: label,
              helperText: helper,
              errorText: key == null ? null : _fieldErrors[key]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final info = _info;
    final modes = [
      if (info?.authMethods.contains(AuthMethod.password) ?? false) ...[
        _Mode.signIn,
        if (info!.canRegister) _Mode.register,
      ],
      if (info?.authMethods.contains(AuthMethod.token) ?? false) _Mode.token,
    ];
    final title = switch (_mode) {
      _Mode.register => 'Register',
      _ => 'Sign in',
    };

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: AutofillGroup(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(info?.masjidName ?? state.masjid?.name ?? '',
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            Text(state.masjid?.api.toString() ?? '',
                style: const TextStyle(fontSize: 13, color: Brand.muted)),
            const SizedBox(height: 24),
            if (info == null && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (modes.length > 1) ...[
              SegmentedButton<_Mode>(
                segments: [
                  for (final m in modes)
                    ButtonSegment(
                        value: m,
                        label: Text(switch (m) {
                          _Mode.signIn => 'Sign in',
                          _Mode.register => 'Register',
                          _Mode.token => 'Token',
                        })),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() {
                  _mode = s.first;
                  _error = null;
                }),
              ),
              const SizedBox(height: 20),
            ],
            if (info != null && _mode == _Mode.register) ...[
              const Text(
                'New volunteers ask for an account here. Someone at the '
                'masjid then approves you before you can send times.',
                style: TextStyle(color: Brand.muted),
              ),
              const SizedBox(height: 16),
              _field(_name, 'Your name',
                  key: 'name',
                  helper: 'So the masjid knows who you are',
                  autofill: const [AutofillHints.name]),
              _field(_user, 'Choose a username',
                  key: 'username', autofill: const [AutofillHints.newUsername]),
              _field(_password, 'Choose a password',
                  key: 'password',
                  helper: 'At least 8 characters',
                  obscure: true,
                  autofill: const [AutofillHints.newPassword]),
              _field(_contact, 'Phone or email (optional)',
                  keyboard: TextInputType.emailAddress),
              _field(_note, 'Note for the masjid (optional)',
                  helper: 'e.g. “I help set up for Jumu’ah”',
                  maxLines: 2,
                  last: true),
            ],
            if (info != null && _mode == _Mode.signIn) ...[
              _field(_user, 'Username',
                  autofill: const [AutofillHints.username]),
              _field(_password, 'Password',
                  obscure: true,
                  autofill: const [AutofillHints.password],
                  last: true),
            ],
            if (info != null && _mode == _Mode.token)
              _field(_token, 'Access token',
                  helper: 'Given to you by the masjid', last: true),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_error ?? '',
                    style: const TextStyle(color: Brand.error)),
              ),
            const SizedBox(height: 24),
            if (info != null)
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5))
                    : Text(_mode == _Mode.register ? 'Ask to join' : 'Sign in'),
              )
            else if (_error != null)
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
