// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import starlight from '@astrojs/starlight';
import svelte from '@astrojs/svelte';
import tailwindcss from '@tailwindcss/vite';
import starlightLlmsTxt from 'starlight-llms-txt';
import starlightSidebarTopics from 'starlight-sidebar-topics';
import starlightLinksValidator from 'starlight-links-validator';
import redirects from './redirects.mjs';
import { SITE_URL } from './scripts/site-url.mjs';

// The Google tag (GTM container GTM-T2PQ3L7L) loads on every page of the
// production build only — dev servers never send pageviews. The config call
// activates measurement; the container id in the loader URL routes it
// through GTM.
const analyticsHead = process.env.NODE_ENV === 'production'
	? [
		{
			tag: 'script',
			attrs: { src: 'https://www.googletagmanager.com/gtm.js?id=GTM-T2PQ3L7L', async: true },
		},
		{
			tag: 'script',
			content: [
				'window.dataLayer = window.dataLayer || [];',
				'function gtag(){dataLayer.push(arguments);}',
				"gtag('js', new Date());",
				"gtag('config', 'GTM-T2PQ3L7L');",
			].join('\n'),
		},
	]
	: [];

// Injects the client script that runs on every page: the copy-as-markdown
// button wiring (src/scripts/copy-as-markdown.ts). Diagrams are rendered at
// build time (scripts/build-diagrams.mjs) and need no client script. See
// doc/site-docs.md.
const pageClientScripts = {
	name: 'facet-page-client-scripts',
	hooks: {
		'astro:config:setup': ({ injectScript }) => {
			// Astro 7 treats injected script config as literal module content, so
			// the entrypoint is imported root-relative from the virtual page script.
			injectScript('page', 'import "/src/scripts/copy-as-markdown.ts";');
		},
	},
};

// The five documentation-v2 tabs (02-information-architecture.md §2). Each
// topic carries its own sidebar, listed above the shared sidebar rail; every
// group is collapsed until the reader opens it or lands inside it. Group
// labels follow §2.1–2.5; fr labels ride on the topic level (group labels
// localize with the content WPs, decision D8).
const collapsed = (label, items) => ({ label, collapsed: true, items });

const discoverSidebar = [
	'discover',
	'discover/why-facet',
	collapsed('How Facet works', [
		'discover/how-it-works',
		'discover/how-it-works/domains',
		'discover/how-it-works/documents',
		'discover/how-it-works/roles',
		'discover/how-it-works/apps',
		'discover/how-it-works/assistant',
	]),
	'discover/a-day-at-brightwater',
	'discover/is-it-right-for-you',
	'discover/security',
	collapsed('Compare', [
		'discover/compare',
		'discover/compare/vs-ai-built-apps',
		'discover/compare/vs-airtable-notion',
		'discover/compare/vs-odoo-erp',
		'discover/compare/vs-retool-lowcode',
		'discover/compare/vs-supabase-firebase',
	]),
	'discover/licensing-and-services',
];

const useSidebar = [
	'use',
	collapsed('Your first day', ['use/first-day', 'use/first-day/sign-in', 'use/first-day/dashboard']),
	collapsed('Work with documents', [
		'use/documents',
		'use/documents/view-and-edit',
		'use/documents/comments-attachments',
		'use/documents/history-undo',
		'use/documents/import-export',
	]),
	collapsed('Find things', [
		'use/finding/lists-and-views',
		'use/finding/search',
		'use/finding/keyboard-shortcuts',
	]),
	'use/notifications',
	'use/assistant',
	'use/account',
];

const buildSidebar = [
	'build',
	collapsed('Your first hour', [
		'build/first-hour',
		'build/first-hour/run-facet',
		'build/first-hour/first-domain',
		'build/first-hour/first-domain-in-files',
		'build/first-hour/first-app',
		'build/first-hour/team-access',
		'build/first-hour/connect-an-agent',
	]),
	'build/dev-environment',
	collapsed('Model your data', [
		'build/model',
		collapsed('In the app: draft and publish', [
			'build/model/in-app/how-drafts-work',
			'build/model/in-app/drafts-and-publishing',
			'build/model/in-app/build-with-assistant',
			'build/model/in-app/check-before-publish',
		]),
		collapsed('In files: dev mode', [
			'build/model/in-files/domain-watcher',
			'build/model/in-files/domain-files',
			'build/model/in-files/with-a-coding-agent',
		]),
		'build/model/dev-to-production',
		'build/model/bundles',
		'build/model/change-a-live-domain',
		collapsed('Data: doctypes and fields', [
			'build/model/data/design-doctypes',
			'build/model/data/field-types',
			'build/model/data/identifiers-uniqueness',
			'build/model/data/computed-fields',
			'build/model/data/secret-fields',
			'build/model/data/files',
		]),
		collapsed('Relations', [
			'build/model/relations/references-links',
			'build/model/relations/parent-child',
			'build/model/relations/across-domains',
			'build/model/relations/comments-attachments',
		]),
		collapsed('Views', [
			'build/model/views/names-and-search',
			'build/model/views/document-pages',
			'build/model/views/lists-boards-calendars',
			'build/model/views/schematic',
		]),
		collapsed('Behaviour', [
			'build/model/behaviour/named-actions',
			'build/model/behaviour/scripts-and-guards',
		]),
		collapsed('Automation', [
			'build/model/automation/event-hooks',
			'build/model/automation/webhooks',
			'build/model/automation/notifications',
		]),
		collapsed('Access rules', ['build/model/access/named-scopes']),
	]),
	collapsed('Build apps', [
		'build/apps',
		'build/apps/how-apps-work',
		'build/apps/quickstart',
		collapsed('Connect', [
			'build/apps/connect/register',
			'build/apps/connect/user-login',
			'build/apps/connect/dpop',
			'build/apps/connect/cors',
			'build/apps/connect/backend-apps',
			'build/apps/connect/permission-manifest',
			'build/apps/connect/what-an-app-can-do',
		]),
		collapsed('Read and write data', [
			'build/apps/data/rest-api',
			'build/apps/data/sdk',
			'build/apps/data/search',
			'build/apps/data/realtime',
			'build/apps/data/files',
			'build/apps/data/bulk-import-export',
		]),
		collapsed('Host and embed', ['build/apps/host/deploy', 'build/apps/host/embed-assistant']),
		collapsed('AI agents', [
			'build/apps/agents/coding-agents',
			'build/apps/agents/mcp',
			'build/apps/agents/agent-tools',
		]),
	]),
	collapsed('How it works (deeper)', [
		'build/deeper',
		'build/deeper/documents-and-projections',
		'build/deeper/schema-evolution',
		'build/deeper/cross-domain-replication',
		'build/deeper/domain-isolation',
	]),
];

const adminSidebar = [
	'admin',
	collapsed('Install', [
		'admin/install/requirements',
		'admin/install/containers',
		'admin/install/production',
		'admin/install/bootstrap',
	]),
	collapsed('Configure', [
		'admin/configure',
		'admin/configure/configuration-files',
		'admin/configure/system-settings',
		'admin/configure/email',
		'admin/configure/file-storage',
		'admin/configure/currencies',
		'admin/configure/languages',
	]),
	collapsed('People and access', [
		'admin/people',
		'admin/people/accounts',
		'admin/people/roles-and-permissions',
		'admin/people/assign-roles',
		'admin/people/row-scopes',
		'admin/people/hidden-fields',
		'admin/people/who-can-change-roles',
		'admin/people/mfa',
		'admin/people/sso',
		'admin/people/sessions-lockouts',
	]),
	collapsed('Apps and machine access', ['admin/apps-access/app-grants', 'admin/apps-access/api-keys']),
	collapsed('History and audit', [
		'admin/history/audit',
		'admin/history/roll-back',
		'admin/history/retention',
	]),
	collapsed('The assistant', ['admin/assistant/connect-a-model', 'admin/assistant/govern']),
	collapsed('Keep it running', [
		'admin/keep-running',
		'admin/keep-running/monitoring',
		'admin/keep-running/jobs-cron',
		'admin/keep-running/migrations',
		'admin/keep-running/upgrades',
		'admin/keep-running/indexes',
		'admin/keep-running/backup-restore',
	]),
	collapsed('Under the hood', [
		'admin/under-the-hood',
		'admin/under-the-hood/change-log',
		'admin/under-the-hood/one-role-at-a-time',
		'admin/under-the-hood/how-access-is-enforced',
		'admin/under-the-hood/events-and-delivery',
		'admin/under-the-hood/ai-and-permissions',
	]),
];

const referenceSidebar = [
	'reference',
	'reference/glossary',
	'reference/feature-index',
	'reference/rest-api',
	'reference/cli-facet',
	'reference/cli-npm',
	'reference/config-keys',
	'reference/system-settings-keys',
	'reference/account-settings-keys',
	'reference/doctype-schema',
	'reference/dvt-schema',
	'reference/field-types',
	'reference/filter-operators',
	'reference/jinja2-context',
	'reference/lua-api',
	'reference/permission-syntax',
	'reference/agent-tools',
	'reference/webhook-payloads',
	'reference/error-responses',
	'reference/health-metrics-names',
	'reference/changelog',
	'reference/limits',
];

// https://astro.build/config
export default defineConfig({
	site: SITE_URL, // required by starlight-llms-txt and @astrojs/sitemap
	// Every pre-v2 URL (English and French) keeps working; see redirects.mjs
	// (generated from the page map by scripts/apply-page-map.mjs).
	redirects,
	integrations: [
		svelte(),
		// Emits /sitemap-index.xml (+ sitemap-0.xml) into dist/. Starlight
		// already links it from every page head (rel="sitemap") once `site`
		// is set; hreflang alternates come from the page heads themselves.
		sitemap(),
		pageClientScripts,
		starlight({
			title: 'Facet',
			description:
				'Documentation for Facet, the governed application platform for small and mid-sized organizations.',
			locales: {
				root: { label: 'English', lang: 'en' },
				fr: { label: 'Français', lang: 'fr' },
			},
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/wearefacet/facet' }],
			// Header logo: the app's gem + wordmark lockup, one variant per theme.
			// Starlight renders both <img>s and hides one via [data-theme] classes
			// — the same pattern as the app's Logo.svelte. The lockup already
			// carries the wordmark, so replacesTitle keeps the text title for
			// screen readers only; alt stays empty so the link is named once.
			logo: {
				light: './src/assets/facet-lockup-light.svg',
				dark: './src/assets/facet-lockup-dark.svg',
				alt: '',
				replacesTitle: true,
			},
			// Brand fonts from the app design guideline: Space Grotesk for headings
			// and the site title, JetBrains Mono for code. global.css wires them
			// into --sl-font* and the heading rule.
			head: [
				// Default social-card image. Starlight emits no og:image of its
				// own; crawlers require an absolute URL, so the site origin rides
				// along here. public/og.png is generated by scripts/build-og-image.mjs.
				{ tag: 'meta', attrs: { property: 'og:image', content: `${SITE_URL}/og.png` } },
				{ tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
				{ tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
				{ tag: 'meta', attrs: { property: 'og:image:alt', content: 'The Facet logo — an amber gem next to the facet wordmark.' } },
				...analyticsHead,
				{ tag: 'link', attrs: { rel: 'preconnect', href: 'https://fonts.googleapis.com' } },
				{
					tag: 'link',
					attrs: { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: 'anonymous' },
				},
				{
					tag: 'link',
					attrs: {
						rel: 'stylesheet',
						href: 'https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap',
					},
				},
			],
			customCss: ['./src/styles/global.css'],
			// Code blocks: Starlight's Expressive Code preprocessor already derives
			// the code font from --sl-font-mono and the block chrome (backgrounds,
			// borders, tabs) from --sl-color-* — see doc/site-docs.md → Theming.
			components: {
				// Renders the title plus the "Copy as markdown" button; the button
				// behaviour lives in src/scripts/copy-as-markdown.ts.
				PageTitle: './src/components/PageTitle.astro',
				// Splash-page hero with the animated gem (src/components/landing/).
				Hero: './src/components/Hero.astro',
			},
			plugins: [
				starlightLlmsTxt(),
				// Decision D1: the five tabs render as a topic list above the
				// sidebar; each topic has its own sidebar (02-information-architecture.md §2).
				starlightSidebarTopics([
					{
						label: { en: 'Discover', fr: 'Découvrir' },
						link: '/discover/',
						items: discoverSidebar,
					},
					{
						label: { en: 'Use', fr: 'Utiliser' },
						link: '/use/',
						items: useSidebar,
					},
					{
						label: { en: 'Build', fr: 'Construire' },
						link: '/build/',
						items: buildSidebar,
					},
					{
						label: { en: 'Administer', fr: 'Administrer' },
						link: '/admin/',
						items: adminSidebar,
					},
					{
						label: { en: 'Reference', fr: 'Référence' },
						link: '/reference/',
						items: referenceSidebar,
					},
				]),
				// WP 11: dead internal links fail the build (00-contract.md §8).
				starlightLinksValidator(),
			],
		}),
	],
	vite: {
		plugins: [tailwindcss()],
	},
});
