import {
  buildMessage,
  classifyResponse,
  type Fetch,
  getAccessToken,
  parseServiceAccount,
  type QueueJob,
  sendJob,
  type ServiceAccount,
  signAssertion,
} from "./fcm.ts";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}
function assertEquals<T>(a: T, b: T, msg = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`${msg} expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`);
  }
}

const job: QueueJob = {
  queue_id: 1,
  notification_id: "n1",
  user_id: "u1",
  type: "private_message",
  title: "FamilySync",
  body: "Mesej baharu daripada Aminah",
  data: { route: "/chat/c1", tag: "chat:c1", channel: "messages" },
  attempts: 1,
  tokens: ["tok-a", "tok-b"],
};

async function testAccount(): Promise<{ sa: ServiceAccount; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let s = "";
  for (const x of pkcs8) s += String.fromCharCode(x);
  const pem = `-----BEGIN PRIVATE KEY-----\n${
    btoa(s).match(/.{1,64}/g)!.join("\n")
  }\n-----END PRIVATE KEY-----\n`;
  return {
    sa: {
      project_id: "familysync-test",
      client_email: "push@familysync-test.iam.gserviceaccount.com",
      private_key: pem,
    },
    publicKey: pair.publicKey,
  };
}

Deno.test("buildMessage: privacy, channel, collapse tag, string data", () => {
  const m = buildMessage(job, "tok-a").message;
  assertEquals(m.token, "tok-a");
  assertEquals(m.notification, { title: "FamilySync", body: "Mesej baharu daripada Aminah" });
  assertEquals(m.android.priority, "HIGH");
  assertEquals(m.android.notification.channel_id, "familysync_messages");
  assertEquals(m.android.notification.visibility, "PRIVATE");
  assertEquals(m.android.notification.tag, "chat:c1");
  assertEquals(m.data.route, "/chat/c1");
  assertEquals(m.data.notification_id, "n1");
  assert(Object.values(m.data).every((v) => typeof v === "string"), "data values must be strings");
  const task = buildMessage(
    { ...job, type: "task_assigned", data: { route: "/todo/l1", channel: "tasks" } },
    "t",
  ).message;
  assertEquals(task.android.priority, "NORMAL");
  assertEquals(task.android.notification.channel_id, "familysync_tasks");
});

Deno.test("parseServiceAccount rejects incomplete JSON", () => {
  assertEquals(parseServiceAccount(undefined), null);
  assertEquals(parseServiceAccount("not json"), null);
  assertEquals(parseServiceAccount('{"project_id":"x"}'), null);
});

Deno.test("signAssertion produces a verifiable RS256 JWT with the FCM scope", async () => {
  const { sa, publicKey } = await testAccount();
  const jwt = await signAssertion(sa, 1_800_000_000);
  const [h, c, s] = jwt.split(".");
  const dec = (x: string) => JSON.parse(atob(x.replace(/-/g, "+").replace(/_/g, "/")));
  assertEquals(dec(h), { alg: "RS256", typ: "JWT" });
  const claims = dec(c);
  assertEquals(claims.scope, "https://www.googleapis.com/auth/firebase.messaging");
  assertEquals(claims.exp - claims.iat, 3600);
  const sigBin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  const sig = Uint8Array.from(sigBin, (ch) => ch.charCodeAt(0));
  const valid = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    publicKey,
    sig,
    new TextEncoder().encode(`${h}.${c}`),
  );
  assert(valid, "signature must verify with the public key");
});

Deno.test("getAccessToken posts a jwt-bearer grant", async () => {
  const { sa } = await testAccount();
  let body = "";
  const fake: Fetch = (_url, init) => {
    body = String(init?.body);
    return Promise.resolve(new Response(JSON.stringify({ access_token: "ya29.test" })));
  };
  assertEquals(await getAccessToken(sa, fake, 1_800_000_000), "ya29.test");
  assert(
    body.includes("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer"),
    "grant type",
  );
  assert(body.includes("assertion="), "assertion");
});

Deno.test("classifyResponse maps FCM errors", async () => {
  assertEquals((await classifyResponse(new Response("{}", { status: 200 }))).outcome, "ok");
  const unreg = new Response(
    JSON.stringify({ error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }),
    { status: 404 },
  );
  assertEquals((await classifyResponse(unreg)).outcome, "invalid_token");
  assertEquals((await classifyResponse(new Response("busy", { status: 503 }))).outcome, "retry");
  assertEquals((await classifyResponse(new Response("{}", { status: 429 }))).outcome, "retry");
});

Deno.test("sendJob: partial success, invalid token cleanup, retry on outage", async () => {
  const { sa } = await testAccount();
  const ok: Fetch = (_u, init) => {
    const token = JSON.parse(String(init?.body)).message.token;
    return Promise.resolve(
      token === "tok-a"
        ? new Response("{}", { status: 200 })
        : new Response(JSON.stringify({ error: { details: [{ errorCode: "UNREGISTERED" }] } }), {
          status: 404,
        }),
    );
  };
  const r1 = await sendJob(job, sa, "at", ok);
  assertEquals(r1.success, true);
  assertEquals(r1.invalidTokens, ["tok-b"]);

  const down: Fetch = () => Promise.resolve(new Response("unavailable", { status: 503 }));
  const r2 = await sendJob(job, sa, "at", down);
  assertEquals(r2.success, false, "outage must be retried");
  assert(r2.error?.includes("503"), "error recorded");

  const r3 = await sendJob({ ...job, tokens: [] }, sa, "at", down);
  assertEquals(r3.success, true, "no devices: nothing to deliver");
});
