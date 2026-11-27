// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import {
	instanceUrl,
	renderCaddyfile,
	renderCompose,
	renderDevConfig,
	renderEnv,
	renderFacetConfig,
	renderGitignore,
	type DevStackInput
} from '../src/devcompose.js';

const base: DevStackInput = {
	hostname: 'facet.localhost',
	port: 3443,
	version: 'latest',
	postgresPassword: 'pg-secret',
	jwtSigningKey: '-----BEGIN EC PRIVATE KEY-----\nMHc\n-----END EC PRIVATE KEY-----'
};

describe('devcompose', () => {
	it('builds the instance URL', () => {
		expect(instanceUrl({ hostname: 'facet.localhost', port: 3443 })).toBe(
			'https://facet.localhost:3443'
		);
	});

	describe('compose', () => {
		it('uses the GHCR images and dev mode, never a build', () => {
			const compose = renderCompose(base);
			expect(compose).toContain('image: ghcr.io/wearefacet/facet:${FACET_VERSION:-latest}');
			expect(compose).toContain(
				'image: ghcr.io/wearefacet/facet-frontend:${FACET_VERSION:-latest}'
			);
			expect(compose).toContain('APP_ENV: dev');
			expect(compose).toContain('FACET_CONFIG_FILE: /app/config.dev.yml');
			expect(compose).not.toContain('build:');
		});

		it('mounts the dev config and no watch folder by default', () => {
			const compose = renderCompose(base);
			expect(compose).toContain('./config.dev.yml:/app/config.dev.yml:ro');
			expect(compose).not.toContain('./domains:/watch');
		});

		it('mounts the watch folder when watching', () => {
			const compose = renderCompose({ ...base, watchPath: '/watch' });
			expect(compose).toContain('./domains:/watch:ro');
		});
	});

	describe('env', () => {
		it('carries the generated secrets and settings', () => {
			const env = renderEnv(base);
			expect(env).toContain('POSTGRES_PASSWORD=pg-secret');
			expect(env).toContain('FACET_HOSTNAME=facet.localhost');
			expect(env).toContain('HTTPS_PORT=3443');
			expect(env).toContain('JWT_SIGNING_KEY="-----BEGIN EC PRIVATE KEY-----\\nMHc');
		});
	});

	describe('dev config', () => {
		it('carries every loader-required section', () => {
			const config = renderDevConfig(base);
			for (const key of [
				'host:',
				'base_url:',
				'artifact_base_url:',
				'artifact_grant_secret:',
				'artifact:',
				'storage:',
				'event:',
				'secrets:',
				'master_key:'
			]) {
				expect(config).toContain(key);
			}
		});

		it('points at the container services, not localhost', () => {
			const config = renderDevConfig(base);
			expect(config).toContain('url: "redis://redis:6379/0"');
			expect(config).not.toContain('localhost:6379');
			expect(config).toContain('directory: /data/store');
		});

		it('uses dev-only values: stdout mail and non-secure cookies', () => {
			const config = renderDevConfig(base);
			expect(config).toContain('adapter: dev');
			expect(config).toContain('secure_cookies: false');
		});

		it('omits the watcher section by default', () => {
			expect(renderDevConfig(base)).not.toContain('domain_watch');
		});

		it('writes the watcher at the container path when watching', () => {
			const config = renderDevConfig({ ...base, watchPath: '/watch' });
			expect(config).toContain('domain_watch:');
			expect(config).toContain('path: /watch');
		});
	});

	it('renders a caddyfile with the backend and frontend routes', () => {
		const caddy = renderCaddyfile();
		expect(caddy).toContain('/Api/*');
		expect(caddy).toContain('reverse_proxy');
	});

	it('writes a facet config with targets only — no deploy app', () => {
		const parsed = JSON.parse(renderFacetConfig(base)) as Record<string, unknown>;
		expect(parsed).toEqual({
			targets: { dev: { url: 'https://facet.localhost:3443' } },
			defaultTarget: 'dev'
		});
		expect(parsed['app']).toBeUndefined();
	});

	it('gitignores the env and local key files', () => {
		const ignore = renderGitignore();
		expect(ignore).toContain('.env');
		expect(ignore).toContain('.facet.local.json');
		expect(ignore).toContain('domains/');
	});
});
