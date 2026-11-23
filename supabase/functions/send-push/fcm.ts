// Pure FCM HTTP v1 helpers (no I/O except the injected fetch), unit-tested in
// fcm_test.ts.

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

export interface QueueJob {
  queue_id: number;
  notification_id: string;
  user_id: string;
  type: string;
  title: string;
  body: string;
  data: Record<string, unknown> | null;
  attempts: number;
  tokens: string[];
}

export type Fetch = (input: string | URL, init?: RequestInit) => Promise<Response>;

const ANDROID_CHANNELS: Record<string, string> = {
  messages: "familysync_messages",
  tasks: "familysync_tasks",
  family: "familysync_family",
};

export function parseServiceAccount(raw: string | undefined): ServiceAccount | null {
  if (!raw) return null;
  try {
    const sa = JSON.parse(raw);
    if (
      typeof sa.project_id !== "string" || typeof sa.client_email !== "string" ||
      typeof sa.private_key !== "string"
    ) return null;
    return sa as ServiceAccount;
  } catch {
    return null;
  }
}

/** FCM v1 message for one device token. All data values must be strings. */
export function buildMessage(job: QueueJob, token: string) {
  const data: Record<string, string> = {
    notification_id: job.notification_id,
    type: job.type,
  };
  for (const [k, v] of Object.entries(job.data ?? {})) {
    if (v !== null && v !== undefined) data[k] = String(v);
  }
  const channel = ANDROID_CHANNELS[data.channel ?? ""] ?? "familysync_family";
  const isMessage = job.type === "private_message" || job.type === "group_message";
  return {
    message: {
      token,
      notification: { title: job.title, body: job.body },
      data,
      android: {
        priority: isMessage ? "HIGH" : "NORMAL",
        ...(data.tag ? { collapse_key: data.tag.slice(0, 64) } : {}),
        notification: {
          channel_id: channel,
          // One visible notification per conversation / list instead of a pile.
          ...(data.tag ? { tag: data.tag } : {}),
          // Lock screen shows a redacted version unless the user allows more.
          visibility: "PRIVATE",
          click_action: "FLUTTER_NOTIFICATION_CLICK",
        },
      },
    },
  };
}

export type SendOutcome = "ok" | "invalid_token" | "retry";

/** Maps an FCM v1 response to an outcome. */
export async function classifyResponse(
  res: Response,
): Promise<{ outcome: SendOutcome; error?: string }> {
  if (res.ok) return { outcome: "ok" };
  let code = "";
  let text = "";
  try {
    const body = await res.json();
    text = body?.error?.message ?? "";
    const details = body?.error?.details ?? [];
    code = details.find((d: { errorCode?: string }) => d?.errorCode)?.errorCode ??
      body?.error?.status ?? "";
  } catch {
    // non-JSON error body
  }
  if (res.status === 404 || code === "UNREGISTERED") {
    return { outcome: "invalid_token", error: code || "UNREGISTERED" };
  }
  if (res.status === 400 && (code === "INVALID_ARGUMENT" && /registration token/i.test(text))) {
    return { outcome: "invalid_token", error: "INVALID_TOKEN" };
  }
  return { outcome: "retry", error: `${res.status} ${code} ${text}`.trim().slice(0, 300) };
}

function base64url(bytes: Uint8Array | string): string {
  const b = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToPkcs8(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const raw = atob(b64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out.buffer;
}

/** RS256-signed JWT assertion for Google's OAuth 2.0 token endpoint. */
export async function signAssertion(sa: ServiceAccount, nowSeconds: number): Promise<string> {
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: sa.token_uri ?? "https://oauth2.googleapis.com/token",
    iat: nowSeconds,
    exp: nowSeconds + 3600,
  };
  const unsigned = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  return `${unsigned}.${base64url(new Uint8Array(sig))}`;
}

export async function getAccessToken(
  sa: ServiceAccount,
  fetchFn: Fetch,
  nowSeconds: number,
): Promise<string> {
  const assertion = await signAssertion(sa, nowSeconds);
  const res = await fetchFn(sa.token_uri ?? "https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) throw new Error(`oauth_failed ${res.status}`);
  const body = await res.json();
  if (typeof body.access_token !== "string") throw new Error("oauth_no_token");
  return body.access_token;
}

/**
 * Sends one job to all of the user's devices. Success when at least one
 * device accepted it; tokens FCM reports as unregistered are returned for
 * deletion. A job without devices counts as done (nothing to deliver).
 */
export async function sendJob(
  job: QueueJob,
  sa: ServiceAccount,
  accessToken: string,
  fetchFn: Fetch,
): Promise<{ success: boolean; invalidTokens: string[]; error?: string }> {
  if (job.tokens.length === 0) return { success: true, invalidTokens: [] };
  const url = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
  const invalid: string[] = [];
  const errors: string[] = [];
  let delivered = 0;
  for (const token of job.tokens) {
    try {
      const res = await fetchFn(url, {
        method: "POST",
        headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify(buildMessage(job, token)),
      });
      const { outcome, error } = await classifyResponse(res);
      if (outcome === "ok") delivered++;
      else if (outcome === "invalid_token") invalid.push(token);
      else errors.push(error ?? "error");
    } catch (e) {
      errors.push(String(e).slice(0, 200));
    }
  }
  const onlyInvalid = errors.length === 0 && delivered === 0 && invalid.length > 0;
  return {
    success: delivered > 0 || onlyInvalid,
    invalidTokens: invalid,
    error: errors.length ? errors.join("; ").slice(0, 500) : undefined,
  };
}
