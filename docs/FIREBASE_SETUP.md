# Persediaan Firebase (notifikasi tolak) untuk FamilySync

Notifikasi **dalam aplikasi** (ikon loceng) sudah berfungsi tanpa Firebase. Langkah di bawah diperlukan
supaya telefon menerima **notifikasi tolak (push)** walaupun aplikasi ditutup.

Bahagian pelayan sudah siap dan di-deploy: giliran notifikasi, `pg_net`, `pg_cron`, Edge Function
`send-push` dan rahsia webhook dalam Vault. Yang tinggal hanyalah projek Firebase anda.

## 1. Cipta projek Firebase

1. Buka **console.firebase.google.com**, kemudian **Add project** (cth. `familysync`). Google Analytics tidak
   diperlukan.
2. Dalam projek itu: **Add app**, pilih ikon **Android**.
   - **Android package name:** `com.familysync.app` (mesti tepat)
   - Nama panggilan: `FamilySync`
   - SHA-1 tidak diperlukan untuk notifikasi.
3. Muat turun `google-services.json`. Fail ini **tidak perlu** dimasukkan ke dalam projek; kita cuma perlukan
   4 nilai daripadanya.

## 2. Empat nilai awam untuk aplikasi

Nilai-nilai ini **bukan rahsia**; ia memang dibina ke dalam setiap aplikasi Android yang menggunakan Firebase.

| Medan dalam `env/dev.json` | Dari `google-services.json` |
|---|---|
| `FIREBASE_API_KEY` | `client[0].api_key[0].current_key` |
| `FIREBASE_APP_ID` | `client[0].client_info.mobilesdk_app_id` (bentuk `1:123…:android:abc…`) |
| `FIREBASE_MESSAGING_SENDER_ID` | `project_info.project_number` |
| `FIREBASE_PROJECT_ID` | `project_info.project_id` |

Anda boleh menghantar empat nilai ini kepada pembangun, atau menambahnya sendiri ke `env/dev.json`, kemudian
bina semula APK.

## 3. Akaun perkhidmatan FCM (RAHSIA, untuk pelayan sahaja)

1. Firebase console → ⚙️ **Project settings** → **Service accounts** → **Generate new private key**. Satu
   fail JSON akan dimuat turun.
2. Supabase dashboard → projek → **Edge Functions** → **Secrets** → **Add new secret**:
   - Name: `FCM_SERVICE_ACCOUNT_JSON`
   - Value: tampal **keseluruhan** kandungan fail JSON itu
3. Simpan.

> ⚠️ Jangan hantar fail JSON ini melalui chat, e-mel atau git. Ia memberi akses penuh untuk menghantar
> notifikasi atas nama projek anda. Jika terdedah, padam kunci itu di Firebase dan jana yang baharu.

## 4. Semak

1. Pasang APK yang dibina dengan nilai Firebase, log masuk, dan benarkan notifikasi apabila diminta.
2. Dari telefon lain, hantar mesej kepada anda, atau (pemilik/pentadbir) buat **pengumuman** dari tab
   Keluarga → ikon 📣.
3. Notifikasi sepatutnya muncul dalam beberapa saat. Jika tidak:
   - Supabase → **Edge Functions → send-push → Logs**
   - SQL: `select status, attempts, last_error from public.notification_queue order by id desc limit 10;`

## Cara ia berfungsi

```
peristiwa (mesej / tugasan / pengumuman)
  → private.notify(): pilihan pengguna, dibisukan, waktu senyap, privasi, bahasa, dedupe
  → notifications (peti masuk) + notification_queue (jika ada telefon berdaftar)
  → pg_net (serta-merta) / pg_cron (setiap minit, untuk cubaan semula)
  → Edge Function send-push (rahsia Vault disahkan oleh pangkalan data)
  → FCM HTTP v1 → telefon
```

- Kandungan mesej **tidak dipaparkan** pada skrin kunci secara lalai. Pengguna boleh menghidupkannya di
  Profil → Tetapan notifikasi.
- Token yang tidak sah dipadam secara automatik. Kegagalan dicuba semula (1, 2, 4, 8 minit, hingga 5 kali).
- Token peranti dipadam apabila pengguna log keluar.
