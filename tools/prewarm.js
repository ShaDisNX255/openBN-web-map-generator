// tools/prewarm.js
const fs = require("fs");
const path = require("path");
const { URL } = require("url");
const generate = require("../generate");

function readSeedsFromHomePage() {
  const htmlPath = path.join(__dirname, "..", "home-page", "index.html");
  const html = fs.readFileSync(htmlPath, "utf8");

  const seeds = [];
  const re = /<a\s+href="([^"]+)">([^<]+)<\/a>/gi;
  let m;
  while ((m = re.exec(html))) {
    const href = m[1].trim();
    const text = (m[2] || "").trim();
    if (href.startsWith("http://") || href.startsWith("https://")) {
      seeds.push({ href, text });
    }
  }
  // de-dupe by href
  return [...new Map(seeds.map(s => [s.href, s])).values()];
}

function normalizeUrl(u) {
  const url = new URL(u);
  url.hash = "";

  // strip common tracking params
  const drop = ["utm_source","utm_medium","utm_campaign","utm_term","utm_content","gclid","fbclid"];
  for (const k of drop) url.searchParams.delete(k);

  // sort params for stability
  const params = [...url.searchParams.entries()].sort(([a],[b]) => a.localeCompare(b));
  url.search = "";
  for (const [k,v] of params) url.searchParams.append(k,v);

  return url.toString();
}

function hostOf(u) {
  try { return new URL(u).hostname; } catch { return null; }
}

async function main() {
  const DEPTH = parseInt(process.env.ONB_CRAWL_DEPTH || "1", 10);            // 1 = seed + direct links
  const MAX_TOTAL = parseInt(process.env.ONB_CRAWL_MAX_TOTAL || "40", 10);   // total maps/day
  const MAX_PER_DOMAIN = parseInt(process.env.ONB_CRAWL_MAX_PER_DOMAIN || "10", 10);
  const MAX_LINKS_PER_PAGE = parseInt(process.env.ONB_CRAWL_MAX_LINKS_PER_PAGE || "10", 10);

  const SAME_HOST_ONLY = (process.env.ONB_CRAWL_SAME_HOST_ONLY || "1") === "1";

  const seeds = readSeedsFromHomePage();
  const allowHosts = new Set(seeds.map(s => hostOf(s.href)).filter(Boolean));

  const perDomain = new Map();
  const visited = new Set();

  let total = 0;

  // BFS queue: { url, depth, rootHost }
  const queue = seeds.map(s => ({
    url: normalizeUrl(s.href),
    depth: 0,
    rootHost: hostOf(s.href),
  }));

  while (queue.length && total < MAX_TOTAL) {
    const item = queue.shift();
    if (!item?.url) continue;

    const u = normalizeUrl(item.url);
    if (visited.has(u)) continue;

    const host = hostOf(u);
    if (!host) continue;

    // allowlist safety: only crawl hosts that are in index.html
    if (!allowHosts.has(host)) continue;

    // depth safety: keep to same host unless you explicitly loosen it
    if (SAME_HOST_ONLY && item.rootHost && host !== item.rootHost) continue;

    const used = perDomain.get(host) || 0;
    if (used >= MAX_PER_DOMAIN) continue;

    visited.add(u);
    perDomain.set(host, used + 1);

    // generate if missing; also collect links when depth allows
    const wantLinks = item.depth < DEPTH;
    const info = await generate(u, false, { collectLinks: wantLinks, force: false });

    total += 1;
    console.log(`[prewarm] ${total}/${MAX_TOTAL} ${u} (fresh=${info.fresh})`);

    if (wantLinks && info.links && info.links.length) {
      // push only a limited number of links forward
      let pushed = 0;
      for (const raw of info.links) {
        if (pushed >= MAX_LINKS_PER_PAGE) break;
        const nu = normalizeUrl(raw);
        const nh = hostOf(nu);
        if (!nh) continue;
        if (!allowHosts.has(nh)) continue;
        if (SAME_HOST_ONLY && nh !== item.rootHost) continue;
        if (!visited.has(nu)) {
          queue.push({ url: nu, depth: item.depth + 1, rootHost: item.rootHost });
          pushed++;
        }
      }
    }
  }

  console.log(`[prewarm] done. generated/checked ${total} urls.`);
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
