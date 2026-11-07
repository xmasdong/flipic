// 统一到 https://flipic.app：http 和 www 都 301，其余交给静态资源。
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const host = (request.headers.get("host") || url.hostname).split(":")[0].toLowerCase();
    const proto = (request.headers.get("x-forwarded-proto") || url.protocol.replace(":", "")).toLowerCase();

    if (proto === "http" || host === "www.flipic.app" || url.hostname === "www.flipic.app") {
      return new Response(null, {
        status: 301,
        headers: { Location: `https://flipic.app${url.pathname}${url.search}` },
      });
    }

    return env.ASSETS.fetch(request);
  },
};
