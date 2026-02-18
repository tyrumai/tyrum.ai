const TARGET_ORIGIN = "https://tyrum.ai";

export default {
  async fetch(request) {
    const incoming = new URL(request.url);
    const target = new URL(TARGET_ORIGIN);

    target.pathname = incoming.pathname;
    target.search = incoming.search;

    return Response.redirect(target.toString(), 308);
  }
};
