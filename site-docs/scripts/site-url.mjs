// The canonical origin of the docs site — the single source both
// astro.config.mjs (site, og:image) and scripts/emit-robots.mjs (the
// Sitemap line) read. The default is a placeholder; the Docker build
// (docker/docs.Dockerfile) injects the production origin via SITE_URL, so a
// domain change never touches a source file.
export const SITE_URL = process.env.SITE_URL ?? 'https://docs.facet.example';
