// FamilySync — delete-account
//
// Permanently deletes the CALLING user's account. The caller is identified
// only from their verified JWT (never from the request body), so a user can
// never delete someone else.
//
// Steps:
//   1. Verify the JWT (getUser) using the caller's Authorization header.
//   2. Refuse when the user still owns a family with other active members
//      (they must transfer ownership first) — checked with the user's own
//      privileges via the account_deletion_blockers() RPC.
//   3. Remove the user's avatar files.
//   4. Delete the auth user with the service role. Profiles, memberships,
//      preferences and device tokens cascade in the database.
//
// Secrets (set by the platform, never shipped in the app):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
import { createClient } from "npm:@supabase/supabase-js@2.119.2";
import { corsHeaders, json } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return json({ error: "not_authenticated" }, 401);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Client acting AS the caller (RLS applies).
  const asUser = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const token = authHeader.slice("Bearer ".length);
  const { data: userData, error: userError } = await asUser.auth.getUser(token);
  if (userError || !userData?.user) return json({ error: "not_authenticated" }, 401);
  const userId = userData.user.id;

  const { data: blockers, error: blockersError } = await asUser.rpc("account_deletion_blockers");
  if (blockersError) return json({ error: "precheck_failed" }, 500);
  if (Array.isArray(blockers) && blockers.length > 0) {
    return json({ error: "owner_must_transfer", families: blockers }, 409);
  }

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Best-effort removal of the user's own avatar folder.
  const { data: files } = await admin.storage.from("avatars").list(userId, { limit: 1000 });
  if (files && files.length > 0) {
    await admin.storage.from("avatars").remove(files.map((f) => `${userId}/${f.name}`));
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(userId);
  if (deleteError) return json({ error: "delete_failed" }, 500);

  return json({ deleted: true });
});
