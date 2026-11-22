# Tetapan Auth Supabase untuk FamilySync

Projek: `bdakjtyxpgfkgfwjvlfq` (dahulu `smartstock`). Semua tetapan di bawah dibuat di
**supabase.com → projek → Authentication**.

> Mengapa perlu? Projek ini masih memakai tetapan Auth lama smartstock: *Site URL* dan templat e-mel.
> Sebab itu e-mel reset kata laluan membuka laman log masuk smartstock.

## 1. URL Configuration (Authentication → URL Configuration)

| Medan | Nilai |
|---|---|
| Site URL | `familysync://auth-callback` |
| Redirect URLs | tambah `familysync://auth-callback` dan **buang** URL smartstock lama |

## 2. Templat e-mel (Authentication → Emails → Templates)

Mulai versi 0.1.2, aplikasi menggunakan **kod**, bukan pautan. Pengguna menaip kod dari e-mel ke dalam
skrin *Masukkan kod*. Setiap templat **mesti** mengandungi `{{ .Token }}`.

| Templat | Subjek | Kandungan (salin keseluruhan fail) |
|---|---|---|
| Confirm signup | `Kod pengesahan FamilySync` | `supabase/templates/confirmation.html` |
| Reset password | `Kod set semula kata laluan FamilySync` | `supabase/templates/recovery.html` |
| Change email address | `Sahkan e-mel baharu FamilySync` | `supabase/templates/email_change.html` |

## 3. E-mel lambat atau tidak sampai

Pelayan e-mel terbina dalam Supabase hanya untuk percubaan. Ia terhad kepada beberapa e-mel sejam dan
boleh lewat atau masuk ke folder Spam. Untuk kegunaan keluarga, pasang **SMTP sendiri**
(Authentication → Emails → SMTP Settings), contohnya:

- **Gmail**: host `smtp.gmail.com`, port `587`, nama pengguna = alamat Gmail, kata laluan = *App Password*
  (Akaun Google → Keselamatan → Pengesahan 2 Langkah → App passwords).
- **Resend / Brevo / SendGrid**: pelan percuma tersedia; ikut panduan SMTP mereka.

Sender name: `FamilySync`. Selepas SMTP dipasang, naikkan had *Rate Limits → emails sent per hour*
(contoh 30).

## 4. Lain-lain (Authentication → Sign In / Providers → Email)

- *Confirm email*: **ON**
- *Minimum password length*: **8**
- *Leaked password protection*: ON (jika tersedia pada pelan anda)

## Pilihan: biar Claude yang tetapkan

Cipta **Personal Access Token** di supabase.com → Account → **Access Tokens**. Token yang betul bermula
dengan `sbp_`. Simpan token itu melalui borang kredensial sesi, bukan dalam chat. Selepas itu, langkah 1,
2 dan 4 boleh dibuat secara automatik melalui Management API.
