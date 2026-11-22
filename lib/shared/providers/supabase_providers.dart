import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The single Supabase client. Only valid after `Supabase.initialize`, which
/// bootstrap performs when configuration is present. Tests override this.
final supabaseClientProvider = Provider<SupabaseClient>((ref) => Supabase.instance.client);
