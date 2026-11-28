// Serves the committed screenshots at their /screens/ URL in `astro dev`.
//
// Pages embed a shot with an absolute URL: /screens/<path>. The PNGs live in
// src/assets/screens/ — the single committed copy the capture pipeline
// writes. Vite serves public/ from a snapshot taken at startup, so a copy
// step into public/screens/ works once but breaks as soon as the folder is
// removed or recreated under a running dev server (the snapshot still says
// the file is there, the middleware finds nothing, and every page answers
// 404 until the server restarts). This middleware reads the file from
// src/assets/screens/ on each request instead: no copy, no stale snapshot,
// and a recaptured shot shows on the next reload.
//
// `astro build` needs no counterpart: the production container copies the
// shots to public/screens/ before the build (docker/docs.Dockerfile), and
// public/ is served verbatim by nginx.

import { createReadStream, statSync } from 'node:fs';
import { extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCREENS_URL = '/screens/';
const SCREENS_DIR = fileURLToPath(new URL('../assets/screens/', import.meta.url));

const TYPES = {
	'.png': 'image/png',
	'.jpg': 'image/jpeg',
	'.jpeg': 'image/jpeg',
	'.webp': 'image/webp',
	'.gif': 'image/gif',
	'.avif': 'image/avif',
	'.svg': 'image/svg+xml',
};

export default function screensImages() {
	return {
		name: 'facet-screens-images',
		configureServer(server) {
			server.middlewares.use(function screensDevMiddleware(req, res, next) {
				const pathname = req.url?.split('?')[0];
				if (!pathname?.startsWith(SCREENS_URL)) return next();
				const file = SCREENS_DIR + decodeURIComponent(pathname.slice(SCREENS_URL.length));
				let stats;
				try {
					stats = statSync(file);
				} catch {
					return next();
				}
				if (!stats.isFile()) return next();
				res.setHeader('Content-Type', TYPES[extname(file).toLowerCase()] ?? 'application/octet-stream');
				res.setHeader('Content-Length', stats.size);
				res.setHeader('Cache-Control', 'no-cache');
				if (req.method === 'HEAD') return res.end();
				createReadStream(file).pipe(res);
			});
		},
	};
}
