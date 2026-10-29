// Minimal sidecar for thalesmachado.net's /api/homelab-containers endpoint.
// Plain nginx cannot aggregate/reshape JSON from two calls, so this is its
// own container instead of logic inside nginx.
//
// Queries the Komodo API directly (same network/host, cloudflare-net on
// zangetsu, komodo-core:9120), one call per server, and sums both.
// Payload format tested manually (see commit): ListDockerContainers requires
// params.server (server name, not id); the response is an array of
// containers (length = count).
//
// KOMODO_API_KEY/SECRET are the same pair Homepage/site-typewriter use
// (env_file, never hardcoded, never in the site repo).

const KEY = Deno.env.get("KOMODO_API_KEY");
const SECRET = Deno.env.get("KOMODO_API_SECRET");
if (!KEY || !SECRET) {
  throw new Error("KOMODO_API_KEY/KOMODO_API_SECRET not set");
}

const KOMODO_URL = "http://komodo-core:9120/read";
const HOSTS = ["zangetsu", "urahara"];

async function countFor(server: string): Promise<number> {
  const res = await fetch(KOMODO_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Api-Key": KEY!,
      "X-Api-Secret": SECRET!,
    },
    body: JSON.stringify({ type: "ListDockerContainers", params: { server } }),
  });
  if (!res.ok) throw new Error(`komodo ${server}: HTTP ${res.status}`);
  const containers = await res.json();
  return Array.isArray(containers) ? containers.length : 0;
}

Deno.serve({ port: 3001 }, async () => {
  try {
    const counts = await Promise.all(HOSTS.map(countFor));
    const hosts = Object.fromEntries(HOSTS.map((h, i) => [h, counts[i]]));
    const total = counts.reduce((a, b) => a + b, 0);
    return Response.json({ total, hosts });
  } catch (e) {
    // 502 on purpose: upstream (Komodo) error, not the sidecar's own
    return Response.json({ error: String(e) }, { status: 502 });
  }
});
