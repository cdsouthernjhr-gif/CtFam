// FamilySync — send-push
//
// Delivers queued notifications (public.notification_queue) through Firebase
// Cloud Messaging HTTP v1.
//
// Invoked by the database (pg_net on new queue rows + pg_cron every minute)
// with header `x-push-secret`. The secret is stored only in Supabase Vault;
// this function asks the database to verify it (verify_push_secret, service
// role only). JWT verification is therefore disabled for this function.
//
// Secrets (Edge Function environment, never in the app):
//   FCM_SERVICE_ACCOUNT_JSON  Firebase service account JSON
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  (injected by the platform)
import { createClient } from "npm:@supabase/supabase-js@2.119.2";
import { getAccessToken, parseServiceAccount, type QueueJob, sendJob } from "./fcm.ts";

const BATCH = 100;
const MAX_BATCHES = 5;
const CONCURRENCY = 10;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    {
      auth: { persistSession: false, autoRefreshToken: false },
    },
  );

  const { data: ok, error: verifyError } = await admin.rpc("verify_push_secret", {
    p_secret: req.headers.get("x-push-secret") ?? "",
  });
  if (verifyError || ok !== true) return json({ error: "unauthorized" }, 401);

  const sa = parseServiceAccount(Deno.env.get("FCM_SERVICE_ACCOUNT_JSON"));
  if (!sa) {
    // Not configured yet: leave jobs pending; they are sent once configured.
    return json({ configured: false });
  }

  let accessToken: string;
  try {
    accessToken = await getAccessToken(sa, fetch, Math.floor(Date.now() / 1000));
  } catch (e) {
    console.error("FCM auth failed", String(e));
    return json({ error: "fcm_auth_failed" }, 502);
  }

  let sent = 0, failed = 0;
  for (let b = 0; b < MAX_BATCHES; b++) {
    const { data: jobs, error } = await admin.rpc("claim_push_batch", { p_limit: BATCH });
    if (error) {
      console.error("claim failed", error.message);
      return json({ error: "claim_failed" }, 500);
    }
    const list = (jobs ?? []) as QueueJob[];
    if (list.length === 0) break;

    for (let i = 0; i < list.length; i += CONCURRENCY) {
      await Promise.all(
        list.slice(i, i + CONCURRENCY).map(async (job) => {
          const result = await sendJob(job, sa, accessToken, fetch);
          result.success ? sent++ : failed++;
          const { error: completeError } = await admin.rpc("complete_push", {
            p_queue_id: job.queue_id,
            p_success: result.success,
            p_error: result.error ?? null,
            p_invalid_tokens: result.invalidTokens,
          });
          if (completeError) console.error("complete failed", job.queue_id, completeError.message);
        }),
      );
    }
    if (list.length < BATCH) break;
  }
  return json({ configured: true, sent, failed });
});
