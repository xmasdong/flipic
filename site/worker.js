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

// 一次下载只数一次：浏览器续传、分段下载会发好几个 Range 请求，只认不带 Range 或从 0 开始的那个
function isDownloadStart(request, response) {
  if (request.method !== "GET") return false;
  const range = request.headers.get("range");
  if (range && !/^bytes=0-/.test(range.trim())) return false;
  return response.status === 200 || response.status === 206;
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

    // 只判断中文首页，其他路径一律原样交给静态资源
    if (url.pathname !== "/") {
      const response = await env.ASSETS.fetch(request);
      const kind = url.pathname === "/download/Flipic.dmg" ? "download" : url.pathname === "/version.json" ? "version" : "";
      if (kind === "download" ? isDownloadStart(request, response) : kind && request.method === "GET" && response.status === 200) {
        ctx.waitUntil(countHit(env, kind, request).catch(() => {}));
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
