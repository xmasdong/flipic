// 统一到 https://flipic.app：http 和 www 都 301，其余交给静态资源。
const BOT_RE = /bot|crawler|spider|slurp/i;
const HOME_VARY = "Accept-Language, Cookie";

// 合并 Vary，别把静态资源本来带的 Vary 覆盖掉
function addVary(headers, values) {
  const current = (headers.get("Vary") || "")
    .split(",")
    .map(value => value.trim())
    .filter(Boolean);
  for (const value of values) {
    if (!current.some(item => item.toLowerCase() === value.toLowerCase())) current.push(value);
  }
  headers.set("Vary", current.join(", "));
}

function redirectEnglish(url) {
  return new Response(null, {
    status: 302,
    headers: {
      Location: `/en/${url.search}`,
      Vary: HOME_VARY,
      "Cache-Control": "private, no-store",
    },
  });
}

// 容忍空格、大小写、缺 q、q=0 和无效项；按 q 从高到低排
function parseAcceptLanguage(header) {
  if (!header) return [];
  return header
    .split(",")
    .map(part => {
      const [rawTag, ...params] = part.split(";");
      const tag = rawTag.trim().toLowerCase().replace(/_/g, "-");
      if (!tag || tag === "*") return null;
      let q = 1;
      for (const param of params) {
        const eq = param.indexOf("=");
        if (eq === -1) continue;
        if (param.slice(0, eq).trim().toLowerCase() !== "q") continue;
        const parsed = Number.parseFloat(param.slice(eq + 1).trim());
        if (Number.isFinite(parsed)) q = parsed;
      }
      return q > 0 ? { tag, q } : null;
    })
    .filter(Boolean)
    .sort((a, b) => b.q - a.q);
}

function cookieValue(header, name) {
  if (!header) return "";
  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq === -1) continue;
    if (part.slice(0, eq).trim() !== name) continue;
    const value = part.slice(eq + 1).trim();
    try {
      return decodeURIComponent(value);
    } catch {
      return value;
    }
  }
  return "";
}

// 首页 200 也要带 Vary，复制响应以免丢掉 ASSETS 原有的头
function withHomeVary(response) {
  const headers = new Headers(response.headers);
  addVary(headers, ["Accept-Language", "Cookie"]);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

// 下载和检查更新只累加次数（按北京时间的日期、国家、来源），不存 IP，没有任何标识。
// App 检查更新时的 User-Agent 是 "Flipic/版本号"，据此按版本分开数
function clientOf(userAgent) {
  const app = /^Flipic\/([0-9][0-9.]{0,11})/.exec(userAgent);
  if (app) return `app ${app[1]}`;
  if (!userAgent || BOT_RE.test(userAgent)) return "bot";
  return /^Mozilla\//.test(userAgent) ? "browser" : "other";
}

async function countHit(env, kind, request) {
  if (!env.STATS) return;
  const day = new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
  const country = String(request.cf?.country || "").slice(0, 2);
  await env.STATS.prepare(
    "INSERT INTO hits (day, kind, country, client, n) VALUES (?, ?, ?, ?, 1) " +
    "ON CONFLICT (day, kind, country, client) DO UPDATE SET n = n + 1",
  ).bind(day, kind, country, clientOf(request.headers.get("user-agent") || "")).run();
}

// App 每天自动检查更新一次，请求带 a（安装时长区间）和 p（是否已激活 Pro）。
// 只认白名单里的值、只数 App 的自动检查（手动检查带 m=1）；其余一概不记，也不存原始查询串
const AGE_BUCKETS = new Set(["0-6", "7-29", "30+"]);

async function countActive(env, request, url) {
  if (!env.STATS) return;
  const params = url.searchParams;
  if (params.has("m")) return;
  const age = params.get("a");
  const pro = params.get("p");
  if (!AGE_BUCKETS.has(age) || (pro !== "0" && pro !== "1")) return;
  const client = clientOf(request.headers.get("user-agent") || "");
  if (!client.startsWith("app ")) return;
  const day = new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
  const country = String(request.cf?.country || "").slice(0, 2);
  await env.STATS.prepare(
    "INSERT INTO active (day, age, pro, client, country, n) VALUES (?, ?, ?, ?, ?, 1) " +
    "ON CONFLICT (day, age, pro, client, country) DO UPDATE SET n = n + 1",
  ).bind(day, age, Number(pro), client, country).run();
}

// 一次下载只数一次：浏览器续传、分段下载会发好几个 Range 请求，只认不带 Range 或从 0 开始的那个
function isDownloadStart(request, response) {
  if (request.method !== "GET") return false;
  const range = request.headers.get("range");
  if (range && !/^bytes=0-/.test(range.trim())) return false;
  return response.status === 200 || response.status === 206;
}

// Windows 版候补名单：只存邮箱、页面语言、国家（粗粒度）、日期；不存 IP、UA、来源页。
// 防刷靠同源检查、蜜罐、2 KB 体积上限和每天新增上限，不记录访客任何标识
const WAITLIST_MAX_BODY = 2048;
const WAITLIST_DAILY_CAP = 500;
const WAITLIST_ORIGINS = new Set(["https://flipic.app", "https://www.flipic.app"]);
const EMAIL_RE = /^[a-z0-9](?:[a-z0-9._%+-]{0,62}[a-z0-9])?@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24}$/;

function jsonReply(status, body, extra = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...extra },
  });
}

function sameSite(request) {
  const origin = request.headers.get("origin");
  if (origin) return WAITLIST_ORIGINS.has(origin);
  const referer = request.headers.get("referer");
  if (!referer) return false;
  try {
    return WAITLIST_ORIGINS.has(new URL(referer).origin);
  } catch {
    return false;
  }
}

export function normalizeEmail(value) {
  if (typeof value !== "string") return null;
  const email = value.trim().toLowerCase();
  if (!email || email.length > 254 || /[\u0000-\u001f\u007f]/.test(email)) return null;
  if (email.includes("..") || !EMAIL_RE.test(email)) return null;
  return email;
}

async function handleWaitlist(request, env) {
  if (request.method !== "POST") return jsonReply(405, { ok: false, error: "invalid" }, { Allow: "POST" });
  if (!env.STATS) return jsonReply(503, { ok: false, error: "server" });
  if (!sameSite(request)) return jsonReply(403, { ok: false, error: "invalid" });
  if (!/^application\/json\b/i.test(request.headers.get("content-type") || "")) return jsonReply(415, { ok: false, error: "invalid" });
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > WAITLIST_MAX_BODY) return jsonReply(413, { ok: false, error: "invalid" });
  let text;
  try {
    text = await request.text();
  } catch {
    return jsonReply(400, { ok: false, error: "invalid" });
  }
  if (text.length > WAITLIST_MAX_BODY) return jsonReply(413, { ok: false, error: "invalid" });
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    return jsonReply(400, { ok: false, error: "invalid" });
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) return jsonReply(400, { ok: false, error: "invalid" });
  // 蜜罐：真人看不到这个字段；填了的当成功处理，不存，不让脚本知道被拦了
  if (data.website !== undefined && data.website !== "") return jsonReply(200, { ok: true });
  const email = normalizeEmail(data.email);
  if (!email || (data.lang !== "zh" && data.lang !== "en")) return jsonReply(400, { ok: false, error: "invalid" });
  const country = /^[A-Za-z]{2}$/.test(request.cf?.country || "") ? request.cf.country.toUpperCase() : null;
  const now = new Date();
  try {
    const today = await env.STATS.prepare("SELECT COUNT(*) AS n FROM waitlist_windows WHERE created_at >= ?")
      .bind(now.toISOString().slice(0, 10)).first();
    if ((today?.n ?? 0) >= WAITLIST_DAILY_CAP) return jsonReply(429, { ok: false, error: "busy" }, { "Retry-After": "86400" });
    await env.STATS.prepare("INSERT OR IGNORE INTO waitlist_windows (email, lang, country, created_at) VALUES (?, ?, ?, ?)")
      .bind(email, data.lang, country, now.toISOString()).run();
  } catch {
    return jsonReply(500, { ok: false, error: "server" });
  }
  return jsonReply(200, { ok: true });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const host = (request.headers.get("host") || url.hostname).split(":")[0].toLowerCase();
    const proto = (request.headers.get("x-forwarded-proto") || url.protocol.replace(":", "")).toLowerCase();

    // 先统一域名和协议，这一步和语言无关
    if (proto === "http" || host === "www.flipic.app" || url.hostname === "www.flipic.app") {
      return new Response(null, {
        status: 301,
        headers: { Location: `https://flipic.app${url.pathname}${url.search}` },
      });
    }

    if (url.pathname === "/api/waitlist") return handleWaitlist(request, env);

    // 只判断中文首页，其他路径一律原样交给静态资源
    if (url.pathname !== "/") {
      const response = await env.ASSETS.fetch(request);
      // 静态资源补斜杠、去 index.html 时给的是 307，改成永久的 301，搜索引擎才会把旧地址并到新地址上
      if (response.status === 307 || response.status === 308) {
        const location = response.headers.get("location");
        if (location) return new Response(null, { status: 301, headers: { Location: location } });
      }
      const kind = url.pathname === "/download/Flipic.dmg" ? "download" : url.pathname === "/version.json" ? "version" : "";
      if (kind === "download" ? isDownloadStart(request, response) : kind && request.method === "GET" && response.status === 200) {
        ctx.waitUntil(countHit(env, kind, request).catch(() => {}));
        if (kind === "version") ctx.waitUntil(countActive(env, request, url).catch(() => {}));
      }
      return response;
    }

    const serveHome = async () => withHomeVary(await env.ASSETS.fetch(request));
    const preference = cookieValue(request.headers.get("cookie"), "flipic_lang").toLowerCase();
    if (preference === "en") return redirectEnglish(url);
    if (preference === "zh") return serveHome();

    const acceptLanguage = request.headers.get("accept-language");
    if (!acceptLanguage || !acceptLanguage.trim()) return serveHome();

    // 爬虫不跳，免得 Google 只看到 /en/
    const userAgent = request.headers.get("user-agent") || "";
    if (BOT_RE.test(userAgent)) return serveHome();

    const languages = parseAcceptLanguage(acceptLanguage);
    const primary = languages[0]?.tag.split("-")[0];
    if (primary && primary !== "zh") return redirectEnglish(url);

    return serveHome();
  },
};
