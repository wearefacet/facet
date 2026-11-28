// Machine-readable page map for the documentation-v2 restructure (WP 11).
// Source of truth: doc/plans/documentation/documentation-v2/03-page-map.md
// (paths, types, actions) and 02-information-architecture.md §2 (sidebar
// order, derived top-to-bottom within each group). Consumed by
// scripts/apply-page-map.mjs. Do not edit generated pages by hand — their
// `type` comes from scripts/gen_docs (repo root), not from this map.

// [old, new, type, tab, sidebar.order] — paths relative to src/content/docs/.
// A row with new === old is a stay: front-matter is set, nothing moves.
// Split rows move to the FIRST listed target; the other targets are stubs
// created by their owner WP (see stubs below).
export const rows = [
	// §1 start/ → Discover, Build, Reference
	['start/index.md', 'discover/index.md', 'overview', 'discover', 0],
	['start/what-is-facet.md', 'discover/why-facet.md', 'explanation', 'discover', 1],
	['start/architecture.md', 'discover/how-it-works/index.md', 'explanation', 'discover', 0],
	['start/is-facet-right-for-you.md', 'discover/is-it-right-for-you.md', 'explanation', 'discover', 4],
	['start/security-governance.md', 'discover/security.md', 'explanation', 'discover', 5],
	['start/glossary.md', 'reference/glossary.md', 'reference', 'reference', 1],
	['start/install.md', 'build/dev-environment.md', 'how-to', 'build', 2],

	// §2 tutorials/ → build/first-hour/
	['tutorials/index.md', 'build/first-hour/index.md', 'overview', 'build', 0],
	['tutorials/t1-run-facet.md', 'build/first-hour/run-facet.md', 'tutorial', 'build', 1],
	['tutorials/t2-first-domain.md', 'build/first-hour/first-domain.md', 'tutorial', 'build', 2],
	['tutorials/t4-team-access.md', 'build/first-hour/team-access.md', 'tutorial', 'build', 5],

	// §3 concepts/ → Discover (L1), Build/Admin depth (L3)
	['concepts/domains-and-isolation.md', 'discover/how-it-works/domains.md', 'explanation', 'discover', 1],
	['concepts/documents-doctypes-projections.md', 'build/deeper/documents-and-projections.md', 'explanation', 'build', 1],
	['concepts/mutation-log.md', 'admin/under-the-hood/change-log.md', 'explanation', 'admin', 1],
	['concepts/draft-publish.md', 'build/model/in-app/how-drafts-work.md', 'explanation', 'build', 0],
	['concepts/auth-contexts.md', 'admin/under-the-hood/one-role-at-a-time.md', 'explanation', 'admin', 2],
	['concepts/authorization-enforcement.md', 'admin/under-the-hood/how-access-is-enforced.md', 'explanation', 'admin', 3],
	['concepts/roles-levels-authority.md', 'admin/people/who-can-change-roles.md', 'explanation', 'admin', 6],
	['concepts/apps-grants-roles.md', 'build/apps/connect/what-an-app-can-do.md', 'explanation', 'build', 6],
	['concepts/events-delivery.md', 'admin/under-the-hood/events-and-delivery.md', 'explanation', 'admin', 4],
	['concepts/schema-evolution.md', 'build/deeper/schema-evolution.md', 'explanation', 'build', 2],
	['concepts/cross-domain-replication.md', 'build/deeper/cross-domain-replication.md', 'explanation', 'build', 3],
	['concepts/ai-under-callers-rights.md', 'discover/how-it-works/assistant.md', 'explanation', 'discover', 5],

	// §4 workspace/ → use/
	['workspace/index.md', 'use/index.md', 'overview', 'use', 0],
	['workspace/sign-in-mfa.md', 'use/first-day/sign-in.md', 'how-to', 'use', 2],
	['workspace/dashboard.md', 'use/first-day/dashboard.md', 'how-to', 'use', 3],
	['workspace/viewing-editing-document.md', 'use/documents/view-and-edit.md', 'how-to', 'use', 1],
	['workspace/comments-attachments.md', 'use/documents/comments-attachments.md', 'how-to', 'use', 2],
	['workspace/history-undo.md', 'use/documents/history-undo.md', 'how-to', 'use', 3],
	['workspace/import-export.md', 'use/documents/import-export.md', 'how-to', 'use', 4],
	['workspace/lists-filters-views.md', 'use/finding/lists-and-views.md', 'how-to', 'use', 1],
	['workspace/search-command-palette.md', 'use/finding/search.md', 'how-to', 'use', 2],
	['workspace/keyboard-shortcuts.md', 'use/finding/keyboard-shortcuts.md', 'reference', 'use', 3],
	['workspace/notifications.md', 'use/notifications.md', 'how-to', 'use', 4],
	['workspace/assistant.md', 'use/assistant.md', 'how-to', 'use', 5],
	['workspace/settings-sessions-api-keys.md', 'use/account.md', 'how-to', 'use', 6],

	// §5 build/ → build/model/ and build/deeper/
	['build/index.md', 'build/index.md', 'overview', 'build', 0],
	['build/domains-drafts-editors.md', 'build/model/in-app/drafts-and-publishing.md', 'how-to', 'build', 1],
	['build/domain-builder-assistant.md', 'build/model/in-app/build-with-assistant.md', 'how-to', 'build', 2],
	['build/checking-before-publish.md', 'build/model/in-app/check-before-publish.md', 'how-to', 'build', 3],
	['build/dev-domain-watcher.md', 'build/model/in-files/domain-watcher.md', 'how-to', 'build', 0],
	['build/bundles.md', 'build/model/bundles.md', 'how-to', 'build', 4],
	['build/evolving-schema.md', 'build/model/change-a-live-domain.md', 'how-to', 'build', 5],
	['build/designing-doctypes.md', 'build/model/data/design-doctypes.md', 'how-to', 'build', 0],
	['build/field-types.md', 'build/model/data/field-types.md', 'how-to', 'build', 1],
	['build/identifiers-unique-constraints.md', 'build/model/data/identifiers-uniqueness.md', 'how-to', 'build', 2],
	['build/computed-fields.md', 'build/model/data/computed-fields.md', 'how-to', 'build', 3],
	['build/secret-write-only-fields.md', 'build/model/data/secret-fields.md', 'how-to', 'build', 4],
	['build/files-artifacts.md', 'build/model/data/files.md', 'how-to', 'build', 5],
	['build/references-links-backlinks.md', 'build/model/relations/references-links.md', 'how-to', 'build', 0],
	['build/parent-child-composition.md', 'build/model/relations/parent-child.md', 'how-to', 'build', 1],
	['build/sharing-across-domains.md', 'build/model/relations/across-domains.md', 'how-to', 'build', 2],
	['build/sidecars.md', 'build/model/relations/comments-attachments.md', 'how-to', 'build', 3],
	['build/display-names-search-text.md', 'build/model/views/names-and-search.md', 'how-to', 'build', 0],
	['build/view-templates.md', 'build/model/views/document-pages.md', 'how-to', 'build', 1],
	['build/collection-views.md', 'build/model/views/lists-boards-calendars.md', 'how-to', 'build', 2],
	['build/schematic-view.md', 'build/model/views/schematic.md', 'how-to', 'build', 3],
	['build/named-actions.md', 'build/model/behaviour/named-actions.md', 'how-to', 'build', 0],
	['build/lifecycle-scripts-guards.md', 'build/model/behaviour/scripts-and-guards.md', 'how-to', 'build', 1],
	['build/event-hooks.md', 'build/model/automation/event-hooks.md', 'how-to', 'build', 0],
	['build/webhooks.md', 'build/model/automation/webhooks.md', 'how-to', 'build', 1],
	['build/notifications-mentions.md', 'build/model/automation/notifications.md', 'how-to', 'build', 2],
	['build/named-scopes.md', 'build/model/access/named-scopes.md', 'how-to', 'build', 0],

	// §6 apps/ → build/apps/
	['apps/index.md', 'build/apps/index.md', 'overview', 'build', 0],
	['apps/how-apps-work.md', 'build/apps/how-apps-work.md', 'explanation', 'build', 1],
	['apps/quickstart-dev-cli.md', 'build/apps/quickstart.md', 'how-to', 'build', 2],
	['apps/registering-app.md', 'build/apps/connect/register.md', 'how-to', 'build', 0],
	['apps/oauth-login.md', 'build/apps/connect/user-login.md', 'how-to', 'build', 1],
	['apps/dpop.md', 'build/apps/connect/dpop.md', 'how-to', 'build', 2],
	['apps/cors-origins.md', 'build/apps/connect/cors.md', 'how-to', 'build', 3],
	['apps/service-accounts.md', 'build/apps/connect/backend-apps.md', 'how-to', 'build', 4],
	['apps/permission-manifest.md', 'build/apps/connect/permission-manifest.md', 'how-to', 'build', 5],
	['apps/rest-api.md', 'build/apps/data/rest-api.md', 'how-to', 'build', 0],
	['apps/typescript-sdk.md', 'build/apps/data/sdk.md', 'how-to', 'build', 1],
	['apps/search.md', 'build/apps/data/search.md', 'how-to', 'build', 2],
	['apps/websockets.md', 'build/apps/data/realtime.md', 'how-to', 'build', 3],
	['apps/files.md', 'build/apps/data/files.md', 'how-to', 'build', 4],
	['apps/bulk-import-export.md', 'build/apps/data/bulk-import-export.md', 'how-to', 'build', 5],
	['apps/hosting-deploy.md', 'build/apps/host/deploy.md', 'how-to', 'build', 0],
	['apps/chat-embed.md', 'build/apps/host/embed-assistant.md', 'how-to', 'build', 1],
	['apps/ai-coding-agents.md', 'build/apps/agents/coding-agents.md', 'how-to', 'build', 0],
	['apps/mcp-agents.md', 'build/apps/agents/mcp.md', 'how-to', 'build', 1],
	['apps/agent-tools.md', 'build/apps/agents/agent-tools.md', 'how-to', 'build', 2],

	// §7 govern/ and operate/ → admin/
	['govern/index.md', 'admin/index.md', 'overview', 'admin', 0],
	['govern/accounts-lifecycle.md', 'admin/people/accounts.md', 'how-to', 'admin', 1],
	['govern/roles-permission-lines.md', 'admin/people/roles-and-permissions.md', 'how-to', 'admin', 2],
	['govern/assigning-roles-election.md', 'admin/people/assign-roles.md', 'how-to', 'admin', 3],
	['govern/row-scopes.md', 'admin/people/row-scopes.md', 'how-to', 'admin', 4],
	['govern/field-visibility-tags.md', 'admin/people/hidden-fields.md', 'how-to', 'admin', 5],
	['govern/enforcing-mfa.md', 'admin/people/mfa.md', 'how-to', 'admin', 7],
	['govern/sso-oidc.md', 'admin/people/sso.md', 'how-to', 'admin', 8],
	['govern/sessions-tokens-lockouts.md', 'admin/people/sessions-lockouts.md', 'how-to', 'admin', 9],
	['govern/app-grants.md', 'admin/apps-access/app-grants.md', 'how-to', 'admin', 0],
	['govern/api-keys.md', 'admin/apps-access/api-keys.md', 'how-to', 'admin', 1],
	['govern/auditing-activity.md', 'admin/history/audit.md', 'how-to', 'admin', 0],
	['govern/rolling-back.md', 'admin/history/roll-back.md', 'how-to', 'admin', 1],
	['govern/retention.md', 'admin/history/retention.md', 'how-to', 'admin', 2],
	['govern/governing-assistant.md', 'admin/assistant/govern.md', 'how-to', 'admin', 1],
	['operate/assistant-config.md', 'admin/assistant/connect-a-model.md', 'how-to', 'admin', 0],
	['operate/system-requirements.md', 'admin/install/requirements.md', 'reference', 'admin', 0],
	['operate/containers-tls.md', 'admin/install/containers.md', 'how-to', 'admin', 1],
	['operate/production.md', 'admin/install/production.md', 'how-to', 'admin', 2],
	['operate/bootstrap-cli.md', 'admin/install/bootstrap.md', 'how-to', 'admin', 3],
	['operate/configuration-files.md', 'admin/configure/configuration-files.md', 'how-to', 'admin', 1],
	['operate/system-settings.md', 'admin/configure/system-settings.md', 'how-to', 'admin', 2],
	['operate/email.md', 'admin/configure/email.md', 'how-to', 'admin', 3],
	['operate/file-storage.md', 'admin/configure/file-storage.md', 'how-to', 'admin', 4],
	['operate/currencies.md', 'admin/configure/currencies.md', 'how-to', 'admin', 5],
	['operate/localization.md', 'admin/configure/languages.md', 'how-to', 'admin', 6],
	['operate/health-metrics-logs.md', 'admin/keep-running/monitoring.md', 'how-to', 'admin', 1],
	['operate/jobs-cron.md', 'admin/keep-running/jobs-cron.md', 'how-to', 'admin', 2],
	['operate/migrations.md', 'admin/keep-running/migrations.md', 'how-to', 'admin', 3],
	['operate/upgrades-shutdown.md', 'admin/keep-running/upgrades.md', 'how-to', 'admin', 4],
	['operate/indexes.md', 'admin/keep-running/indexes.md', 'how-to', 'admin', 5],

	// §8 compare/, changelog/, reference/ (reference stays in place)
	['compare/index.md', 'discover/compare/index.md', 'overview', 'discover', 0],
	['compare/vs-ai-built-apps.md', 'discover/compare/vs-ai-built-apps.md', 'explanation', 'discover', 1],
	['compare/vs-airtable-notion.md', 'discover/compare/vs-airtable-notion.md', 'explanation', 'discover', 2],
	['compare/vs-odoo-erp.md', 'discover/compare/vs-odoo-erp.md', 'explanation', 'discover', 3],
	['compare/vs-retool-lowcode.md', 'discover/compare/vs-retool-lowcode.md', 'explanation', 'discover', 4],
	['compare/vs-supabase-firebase.md', 'discover/compare/vs-supabase-firebase.md', 'explanation', 'discover', 5],
	['changelog/index.md', 'reference/changelog.md', 'reference', 'reference', 20],
	['reference/index.md', 'reference/index.md', 'overview', 'reference', 0],
	['reference/rest-api.mdx', 'reference/rest-api.mdx', 'reference', 'reference', 3],
	['reference/error-responses.md', 'reference/error-responses.md', 'reference', 'reference', 18],
	['reference/jinja2-context.md', 'reference/jinja2-context.md', 'reference', 'reference', 13],
	['reference/permission-syntax.md', 'reference/permission-syntax.md', 'reference', 'reference', 15],
];

// Retired pages: the file is deleted (its original is saved in
// ledgers/originals/ first) and the URL redirects to the named replacement.
export const retires = [
	{ old: 'concepts/index.md', tab: 'discover', redirect: '/discover/how-it-works/' },
	{ old: 'operate/index.md', tab: 'admin', redirect: '/admin/' },
	{ old: 'operate/retention-tuning.md', tab: 'admin', redirect: '/admin/history/retention/' },
];

// New pages (page map §9) that are not blocked on a decision. WP 11 creates
// the stub; the owner WP writes the page. [path, title, type, tab, order, owner]
export const stubs = [
	['discover/how-it-works/documents.md', 'Documents: records with a memory', 'explanation', 'discover', 2, 13],
	['discover/how-it-works/roles.md', 'Roles: who sees and does what', 'explanation', 'discover', 3, 13],
	['discover/how-it-works/apps.md', 'Apps: built fast, replaced freely', 'explanation', 'discover', 4, 13],
	['discover/a-day-at-brightwater.md', 'A day at Brightwater', 'explanation', 'discover', 3, 13],
	['discover/licensing-and-services.md', 'Licensing and services', 'explanation', 'discover', 7, 13],
	['use/first-day/index.md', 'A tour of the workspace', 'tutorial', 'use', 1, 15],
	['use/documents/index.md', 'Work with documents', 'overview', 'use', 0, 15],
	['build/first-hour/first-domain-in-files.md', 'The same domain in files', 'tutorial', 'build', 3, 14],
	['build/first-hour/first-app.md', 'Ship your first app', 'tutorial', 'build', 4, 14],
	['build/first-hour/connect-an-agent.md', 'Connect an AI agent', 'tutorial', 'build', 6, 14],
	['build/model/index.md', 'Choose how you build', 'overview', 'build', 0, 16],
	['build/model/in-files/domain-files.md', 'The domain file layout', 'reference', 'build', 1, 16],
	['build/model/in-files/with-a-coding-agent.md', 'Build domains with a coding agent', 'how-to', 'build', 2, 16],
	['build/model/dev-to-production.md', 'From dev to production', 'how-to', 'build', 3, 16],
	['build/deeper/index.md', 'How it works (deeper)', 'overview', 'build', 0, 16],
	['build/deeper/domain-isolation.md', 'How domains stay isolated', 'explanation', 'build', 4, 16],
	['admin/configure/index.md', 'Configure Facet', 'overview', 'admin', 0, 18],
	['admin/people/index.md', 'People and access', 'overview', 'admin', 0, 18],
	['admin/keep-running/index.md', 'Keep it running', 'overview', 'admin', 0, 18],
	['admin/keep-running/backup-restore.md', 'Back up and restore', 'how-to', 'admin', 6, 18],
	['admin/under-the-hood/index.md', 'Under the hood', 'overview', 'admin', 0, 18],
	['admin/under-the-hood/ai-and-permissions.md', 'AI and permissions, in detail', 'explanation', 'admin', 5, 18],
	['reference/limits.md', 'Limits', 'reference', 'reference', 21, 19],
];

// Generated reference pages (repo-root scripts/gen_docs). WP 11 never writes
// them; their `type` front-matter comes from the generators (WP 11 step 7).
export const generated = [
	'reference/account-settings-keys.md',
	'reference/agent-tools.md',
	'reference/cli-facet.md',
	'reference/cli-npm.md',
	'reference/config-keys.md',
	'reference/doctype-schema.md',
	'reference/dvt-schema.md',
	'reference/feature-index.md',
	'reference/field-types.md',
	'reference/filter-operators.md',
	'reference/health-metrics-names.md',
	'reference/lua-api.md',
	'reference/system-settings-keys.md',
];

// Old sitemap URLs that never had a page in git: the old sitemap emitted
// hreflang alternates for untranslated pages, so /fr/tutorials/* appears in
// the sitemap without a fr twin. They redirect to the English target
// (decision D8 fallback — when no fr twin exists, land on the English page).
export const extraRedirects = [
	['fr/tutorials/t1-run-facet', 'build/first-hour/run-facet'],
	['fr/tutorials/t2-first-domain', 'build/first-hour/first-domain'],
	['fr/tutorials/t4-team-access', 'build/first-hour/team-access'],
];

export const tabs = ['discover', 'use', 'build', 'admin', 'reference'];

// Old URL path → new URL path (no leading/trailing slash, no extension).
// Includes retired pages (redirect target) so link rewriting covers them.
export function urlMap() {
	const map = new Map();
	const strip = (p) => {
		let u = p.replace(/\.mdx?$/, '');
		if (u.endsWith('/index')) u = u.slice(0, -'/index'.length);
		return u;
	};
	for (const [oldPath, newPath] of rows) {
		if (oldPath === newPath) continue;
		map.set(strip(oldPath), strip(newPath));
	}
	for (const r of retires) {
		map.set(strip(r.old), r.redirect.replace(/^\//, '').replace(/\/$/, ''));
	}
	// Longest old path first, so '/apps/files-artifacts' is rewritten before
	// '/apps/files' and '/compare/vs-x' before '/compare'.
	return [...map.entries()].sort((a, b) => b[0].length - a[0].length);
}
