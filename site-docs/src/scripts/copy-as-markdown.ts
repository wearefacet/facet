// Wires the "Copy as markdown" button rendered by the PageTitle component
// override (src/components/PageTitle.astro).
//
// The button copies the page's raw markdown: the .md twin that
// scripts/emit-md.mjs copies into dist/ next to every built page. The button
// hides itself when the twin is missing — in `astro dev` (twins exist only
// after a build), on French routes that fall back to English content with no
// French source page, and on the 404 page. When the fetch or the clipboard
// fails, the button copies the page URL instead.

const BUTTON_ID = 'copy-as-markdown';
const LABEL = 'Copy as markdown';

// Maps the page URL to its raw markdown twin, following the emit-step rules:
//   /build/designing-doctypes/   -> /build/designing-doctypes.md
//   /start/            -> /start.md
//   /fr/start/install/ -> /fr/start/install.md
//   /                  -> /index.md
function markdownUrl(): string {
	const path = window.location.pathname;
	if (path === '' || path === '/') return '/index.md';
	return path.replace(/\/+$/, '') + '.md';
}

// The button is server-rendered and visible (no layout shift when the twin
// exists); this probe removes it when the twin is unreachable.
function probe(): void {
	const button = document.getElementById(BUTTON_ID);
	if (!button) return;
	window
		.fetch(markdownUrl(), { method: 'HEAD' })
		.then((response) => {
			button.hidden = !response.ok;
		})
		.catch(() => {
			button.hidden = true;
		});
}

async function writeToClipboard(text: string): Promise<boolean> {
	try {
		await navigator.clipboard.writeText(text);
		return true;
	} catch {
		// navigator.clipboard needs a secure context; fall back to the
		// deprecated API for plain-http hosts.
		const area = document.createElement('textarea');
		area.value = text;
		area.style.position = 'fixed';
		area.style.opacity = '0';
		document.body.append(area);
		area.select();
		try {
			return document.execCommand('copy');
		} finally {
			area.remove();
		}
	}
}

let flashTimer: ReturnType<typeof setTimeout> | undefined;

function flash(button: HTMLElement, label: string): void {
	button.textContent = label;
	clearTimeout(flashTimer);
	flashTimer = window.setTimeout(() => {
		button.textContent = LABEL;
	}, 1500);
}

async function copyPage(): Promise<void> {
	const button = document.getElementById(BUTTON_ID);
	if (!button) return;
	const url = markdownUrl();
	let copied: boolean;
	try {
		const response = await window.fetch(url);
		if (!response.ok) throw new Error(`${url} responded ${response.status}`);
		copied = await writeToClipboard(await response.text());
	} catch {
		// The .md twin is unreachable — hand over the page URL instead.
		copied = await writeToClipboard(new URL(url, window.location.href).href);
	}
	flash(button, copied ? 'Copied' : 'Copy failed');
}

// Clicks are delegated on document: view transitions swap the DOM (a fresh
// button element per navigation), but this module runs once per session.
document.addEventListener('click', (event) => {
	const target = event.target;
	if (!(target instanceof Element)) return;
	if (!target.closest(`#${BUTTON_ID}`)) return;
	void copyPage();
});

// astro:page-load fires on first load and after every view-transition swap.
document.addEventListener('astro:page-load', () => probe());
if (document.readyState !== 'loading') probe();
else document.addEventListener('DOMContentLoaded', () => probe());
