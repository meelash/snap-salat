import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:snap_salat_api/snap_salat_api.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../main.dart';
import '../services/recognition.dart';
import '../theme.dart';
import 'masjid_picker_screen.dart';
import 'review_screen.dart';
import 'sign_in_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _snap(BuildContext context, ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source);
    if (picked == null || !context.mounted) return;
    final file = File(picked.path);
    final photo = PhotoInput(
      await file.readAsBytes(),
      picked.path,
      fromCamera: source == ImageSource.camera,
      fileModified: await file.lastModified(),
    );
    if (!context.mounted) return;
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ReviewScreen(photo: photo)));
  }

  void _open(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final masjid = state.masjid;

    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          // Header: pattern, name, Arabic title.
          SizedBox(
            height: 250 + MediaQuery.paddingOf(context).top,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const GirihPattern(),
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 12, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text('Snap Salat',
                                  style: TextStyle(
                                      fontSize: 21,
                                      fontWeight: FontWeight.w800,
                                      color: Brand.brass)),
                            ),
                            IconButton(
                              tooltip: 'Help',
                              icon: const Icon(Icons.help_outline),
                              onPressed: () => launchUrl(AppConfig.helpUrl),
                            ),
                          ],
                        ),
                        const Spacer(),
                        const Text('أوقات الصلاة',
                            textDirection: TextDirection.rtl,
                            style: TextStyle(
                                fontFamily: Brand.arabicFont,
                                fontSize: 32,
                                fontWeight: FontWeight.w700,
                                color: Brand.brass)),
                        const SizedBox(height: 6),
                        const Text('Keep your masjid’s prayer times up to date',
                            style: TextStyle(fontSize: 16, color: Brand.muted)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF2B5143)),

          // Masjid and sign-in.
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            child: Material(
              color: Brand.surface,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => _open(context, const MasjidPickerScreen()),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Brand.brass),
                        ),
                        child: const Icon(Icons.mosque_outlined,
                            color: Brand.brass),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(masjid?.name ?? 'Choose your masjid',
                                style: const TextStyle(
                                    fontSize: 17, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 3),
                            Text(
                              masjid == null
                                  ? 'From the directory, or by address'
                                  : (masjid.place.isNotEmpty
                                      ? masjid.place
                                      : masjid.api.host),
                              style: const TextStyle(
                                  fontSize: 14, color: Brand.muted),
                            ),
                            if (masjid != null && state.signedIn) ...[
                              const SizedBox(height: 3),
                              _StatusLine(
                                  state.status, state.session?.userName),
                            ],
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: Brand.muted),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (masjid != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Align(
                alignment: Alignment.centerRight,
                child: state.signedIn
                    ? Wrap(
                        alignment: WrapAlignment.end,
                        children: [
                          if (state.status == VolunteerStatus.pending)
                            TextButton.icon(
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Check again'),
                              onPressed: state.refreshStatus,
                            ),
                          TextButton(
                              onPressed: state.signOut,
                              child: const Text('Sign out')),
                        ],
                      )
                    : TextButton.icon(
                        icon: const Icon(Icons.lock_outline, size: 18),
                        label: const Text('Sign in to send times'),
                        onPressed: () => _open(context, const SignInScreen()),
                      ),
              ),
            ),

          // How it works.
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Column(
              children: [
                _Step(1, 'Photograph the prayer-time board'),
                SizedBox(height: 18),
                _Step(2, 'Check each time the app read'),
                SizedBox(height: 18),
                _Step(3, 'Send it to the masjid’s website'),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Take photo'),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(60)),
                  onPressed: () => _snap(context, ImageSource.camera),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(56)),
                  onPressed: () => _snap(context, ImageSource.gallery),
                  child: const Text('Choose a photo'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int n;
  final String text;
  const _Step(this.n, this.text);

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Brand.brass),
            ),
            child: Text('$n',
                style: const TextStyle(
                    color: Brand.brass,
                    fontSize: 14,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 16))),
        ],
      );
}

/// "Signed in as …", or why this volunteer can't send times yet.
class _StatusLine extends StatelessWidget {
  final VolunteerStatus? status;
  final String? name;
  const _StatusLine(this.status, this.name);

  @override
  Widget build(BuildContext context) {
    final (text, colour) = switch (status) {
      VolunteerStatus.pending => (
          'Waiting for the masjid to approve you',
          Brand.check
        ),
      VolunteerStatus.revoked => (
          'Not allowed to send times. Ask the masjid.',
          Brand.error
        ),
      _ => ('Signed in${name != null ? ' as $name' : ''}', Brand.ok),
    };
    return Text(text,
        style: TextStyle(
            fontSize: 13, color: colour, fontWeight: FontWeight.w600));
  }
}
