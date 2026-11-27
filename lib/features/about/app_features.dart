import 'package:material_ui/material_ui.dart';

/// Everything FamilySync can do, for the About screen.
///
/// RELEASE RULE: every release that adds or changes a feature adds it here,
/// with [AppFeature.since] set to the new version from pubspec.yaml. A unit
/// test (test/unit/app_features_test.dart) fails if the newest version listed
/// here is not the version in pubspec.yaml.
class AppFeature {
  const AppFeature(this.since, this.ms, this.en);

  /// Version that added it (e.g. "0.9.8").
  final String since;
  final String ms;
  final String en;

  String text(String locale) => locale == 'en' ? en : ms;
}

class FeatureArea {
  const FeatureArea(this.icon, this.ms, this.en, this.features);

  final IconData icon;
  final String ms;
  final String en;
  final List<AppFeature> features;

  String title(String locale) => locale == 'en' ? en : ms;
}

const appFeatureAreas = <FeatureArea>[
  FeatureArea(Icons.lock_outline, 'Akaun & keselamatan', 'Account & security', [
    AppFeature(
      '0.1.0',
      'Daftar dan log masuk dengan emel serta kata laluan',
      'Sign up and sign in with email and password',
    ),
    AppFeature(
      '0.1.2',
      'Pengesahan emel dan tetapan semula kata laluan dengan kod',
      'Email verification and password reset with a code',
    ),
    AppFeature(
      '0.1.0',
      'Profil, gambar profil, bahasa (BM/EN) dan tema gelap',
      'Profile, avatar, language (Malay/English) and dark theme',
    ),
    AppFeature('0.1.0', 'Log keluar di semua peranti dan padam akaun', 'Sign out everywhere and delete your account'),
    AppFeature(
      '0.7.0',
      'Semakan keselamatan: data setiap keluarga terasing dan dilindungi',
      'Security review: each family\'s data is isolated and protected',
    ),
  ]),
  FeatureArea(Icons.family_restroom, 'Keluarga', 'Family', [
    AppFeature(
      '0.1.0',
      'Cipta keluarga, jemput ahli dengan kod atau QR',
      'Create a family, invite members with a code or QR',
    ),
    AppFeature('0.1.0', 'Peranan: pemilik, pentadbir, moderator, ahli', 'Roles: owner, admin, moderator, member'),
    AppFeature('0.1.0', 'Pengumuman dan log aktiviti keluarga', 'Announcements and family activity log'),
    AppFeature(
      '0.9.3',
      'Cipta atau sertai keluarga lain dari menu "Keluarga saya"',
      'Create or join another family from "My families"',
    ),
    AppFeature(
      '0.9.0',
      'Keluarga berkaitan (rumpun): sambungkan keluarga induk dan cabang',
      'Linked families (clan): connect parent and branch families',
    ),
  ]),
  FeatureArea(Icons.task_alt, 'To-do', 'To-Do', [
    AppFeature('0.2.0', 'Senarai tugasan dikongsi secara masa nyata', 'Shared task lists in real time'),
    AppFeature(
      '0.2.0',
      'Tugaskan ahli, tarikh akhir, keutamaan, ulangan dan komen',
      'Assign members, due dates, priority, repeats and comments',
    ),
    AppFeature('0.2.0', 'Senarai peribadi untuk ahli tertentu sahaja', 'Private lists for selected members only'),
    AppFeature(
      '0.9.7',
      'Gambar Sebelum dan Selepas (sehingga 4 setiap satu) dengan perbandingan',
      'Before and After photos (up to 4 each) with comparison',
    ),
    AppFeature('0.9.7', 'Gambar sampul untuk senarai', 'Cover photo for a list'),
  ]),
  FeatureArea(Icons.chat_bubble_outline, 'Chat', 'Chat', [
    AppFeature('0.3.0', 'Chat peribadi dan kumpulan dalam keluarga', 'Private and group chats within the family'),
    AppFeature(
      '0.3.0',
      'Lampiran gambar dan fail, balas, sunting, padam, pin mesej',
      'Photo and file attachments, reply, edit, delete, pin',
    ),
    AppFeature('0.3.0', 'Tanda sudah dibaca dan carian mesej', 'Read receipts and message search'),
  ]),
  FeatureArea(Icons.notifications_outlined, 'Notifikasi', 'Notifications', [
    AppFeature('0.4.0', 'Notifikasi push dan peti notifikasi dalam aplikasi', 'Push notifications and an in-app inbox'),
    AppFeature('0.4.0', 'Tetapan setiap jenis notifikasi dan waktu senyap', 'Per-type settings and quiet hours'),
  ]),
  FeatureArea(Icons.event_outlined, 'Kalendar', 'Calendar', [
    AppFeature('0.5.0', 'Kalendar keluarga dengan acara berulang', 'Family calendar with recurring events'),
    AppFeature('0.5.0', 'Jemputan, RSVP dan peringatan acara', 'Invitations, RSVP and event reminders'),
    AppFeature(
      '0.9.0',
      'Acara untuk seluruh rumpun dan paparan "Semua keluarga saya"',
      'Clan-wide events and an "All my families" view',
    ),
  ]),
  FeatureArea(Icons.account_tree_outlined, 'Salasilah', 'Family tree', [
    AppFeature(
      '0.8.0',
      'Salasilah keluarga dengan hubungan dikira automatik (cth. anak saudara)',
      'Family tree with relationships worked out automatically (e.g. nephew)',
    ),
    AppFeature('0.8.0', 'Hari jadi akan datang di papan utama', 'Upcoming birthdays on the dashboard'),
    AppFeature(
      '0.8.1',
      'Gambar setiap orang dan gambar sampul salasilah',
      'A photo for each person and a tree cover photo',
    ),
    AppFeature(
      '0.9.0',
      'Salasilah dikongsi seluruh rumpun, dengan cadangan gabung rekod',
      'Tree shared across the clan, with record merge suggestions',
    ),
    AppFeature('0.9.1', 'Edit carta terus, zum dengan jari', 'Edit the chart directly, pinch to zoom'),
    AppFeature('0.9.2', 'Susunan carta ikut pasangan dan anak', 'Chart layout follows spouses and children'),
    AppFeature(
      '0.9.4',
      'Hari jadi dalam 7 hari berkelip dengan kiraan hari',
      'Birthdays within 7 days blink with a countdown',
    ),
    AppFeature(
      '0.9.5',
      'Semua keturunan (cucu, cicit, piut…) di halaman seseorang',
      'All descendants (grandchildren and beyond) on a person\'s page',
    ),
    AppFeature(
      '0.9.5',
      'PDF A4 untuk cetakan: pecah halaman, peta halaman, pilih cabang, gaya senarai',
      'Print-ready A4 PDF: pages, page map, branch choice, list style',
    ),
    AppFeature(
      '0.9.6',
      'Kad gambar 3D berputar dengan butiran seseorang',
      'Spinning 3D photo card with a person\'s details',
    ),
  ]),
  FeatureArea(Icons.payments_outlined, 'Kutipan', 'Collections', [
    AppFeature(
      '0.9.8',
      'Kutipan duit dengan tujuan: sasaran sekaligus, ikut ahli atau tanpa sasaran',
      'Money collections with a purpose: one total, per member or no target',
    ),
    AppFeature(
      '0.9.8',
      'Bendahari mengesahkan bayaran; resit, perbelanjaan dan baki',
      'Treasurers confirm payments; receipts, expenses and balance',
    ),
    AppFeature(
      '0.9.8',
      'Peringatan kepada yang belum bayar, boleh dikongsi dengan rumpun',
      'Reminders to those who still owe; can be shared with the clan',
    ),
  ]),
  FeatureArea(Icons.cloud_off_outlined, 'Luar talian', 'Offline', [
    AppFeature('0.6.0', 'Data terakhir boleh dilihat tanpa internet', 'Last data can be viewed without internet'),
    AppFeature(
      '0.6.0',
      'Tugasan yang diubah semasa luar talian dihantar apabila kembali dalam talian',
      'Task changes made offline are sent when back online',
    ),
  ]),
  FeatureArea(Icons.info_outline, 'Aplikasi', 'App', [
    AppFeature(
      '0.9.11',
      'Menu Tentang: versi dan senarai semua fungsi',
      'About menu: version and a list of all features',
    ),
  ]),
];

/// Compares "0.9.10" > "0.9.9" numerically.
int compareVersions(String a, String b) {
  final x = a.split('.').map(int.parse).toList();
  final y = b.split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    final c = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (c != 0) return c;
  }
  return 0;
}

/// Newest version that added features.
String get latestFeatureVersion => [
  for (final a in appFeatureAreas)
    for (final f in a.features) f.since,
].reduce((a, b) => compareVersions(a, b) >= 0 ? a : b);
