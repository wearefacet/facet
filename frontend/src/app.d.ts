// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// See https://svelte.dev/docs/kit/types#app.d.ts
// for information about these interfaces
import type { PermissionManifest, ScopeManifest } from '$lib/navModel';

declare global {
	namespace App {
		interface Locals {
			account: { id: string; display_name: string } | null;
			activeRole: string | null;
			availableRoles: string[] | null;
			authenticated: boolean;
			permissions: PermissionManifest | null;
			scopes: ScopeManifest | null;
			/** The active role's `visible_tags` (B-176) — forwarded from
			 * `GET /Api/iam/me`. Null when not hydrated (unauthenticated, an
			 * older payload, or a missing role projection); the field-visibility
			 * filter then applies nothing. */
			visibleTags: string[] | null;
			expiresAt: number | null;
			/**
			 * Whether any held role enables the workspace assistant
			 * (`assistant.access` from `GET /Api/iam/me`, aggregated by
			 * `Assistant::Access`). Gates the dock and its top-bar toggle in
			 * the root layout; the backend re-checks on every assistant route.
			 */
			assistantAccess: boolean;
			/**
			 * Whether the installation has an AI provider configured at all
			 * (`assistant.configured` from `GET /Api/iam/me` — an API key
			 * resolves from the sealed settings slot or the config file).
			 * Independent of `assistantAccess`: `false` keeps the dock visible
			 * but disables conversation creation with an explanatory message.
			 * Fail closed on an older payload without the key.
			 */
			assistantConfigured: boolean;
			/**
			 * The configured assistant display name (`assistant.name` on
			 * `core.SystemSettings`, served by `GET /Api/iam/me`). The root
			 * layout falls back to the localized default when null
			 * (unauthenticated or an older payload without the key).
			 */
			assistantName: string | null;
			/**
			 * The active role's connectivity channels (`connectivity` from
			 * `GET /Api/iam/me` — the per-role programmatic-channel list:
			 * `mcp`, `webhook`, `api`, `assistant`). The frontend hides the
			 * affordances the channels govern (Settings → API keys). Empty or
			 * null (unauthenticated, an older payload, a missing role) reads as
			 * browser-only; the backend gates the channels themselves.
			 */
			connectivity: string[] | null;
			/**
			 * Preview-session mirror read from the `facet.preview-session` cookie.
			 * Present on a full reload of a live URL during preview; null when no
			 * preview is active. Forwarded by `+layout.server.ts` to the universal
			 * `+layout.ts`, which re-injects it into `previewSession.svelte` so SSR
			 * `apiFetch` calls overlay the Bearer token.
			 */
			previewSession: PreviewSessionCookie | null;
		}

		/**
		 * Wire shape of the `facet.preview-session` cookie (and of
		 * `App.Locals.previewSession`). Mirrors `PreviewSession` in
		 * `previewSession.svelte.ts`; defined here separately to avoid importing
		 * a `.svelte.ts` module into `app.d.ts`.
		 */
		interface PreviewSessionCookie {
			draftId: string;
			token: string;
			expiresAt: number;
		}
		// interface Error {}
		// interface PageData {}
		// interface PageState {}
		// interface Platform {}
	}
}

export {};
