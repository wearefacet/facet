// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it, vi } from 'vitest';

// Simulate a host project without the optional peer dependency installed:
// the dynamic `import('mermaid')` inside MermaidDiagram must fail gracefully
// and the fenced block must render as plain code.
vi.mock('mermaid', () => {
	throw new Error('Cannot find module "mermaid"');
});

import { mount, unmount } from 'svelte';
import Markdown from '../../src/markdown/Markdown.svelte';

describe('MermaidDiagram — optional peer dependency', () => {
	it('renders a mermaid fenced block as plain code when mermaid is absent', async () => {
		const host = document.createElement('div');
		document.body.appendChild(host);
		const app = mount(Markdown, {
			target: host,
			props: { content: 'Before.\n\n```mermaid\ngraph TD\nA --> B\n```\n', streaming: false }
		});

		await vi.waitFor(() => {
			const fallback = host.querySelector('.mmd-code');
			expect(fallback?.textContent).toContain('graph TD');
			expect(fallback?.textContent).toContain('A --> B');
		});
		// No diagram render attempt survives.
		expect(host.querySelector('.mmd-svg')).toBeNull();
		// The surrounding text still renders as markdown.
		expect(host.querySelector('.md')?.textContent).toContain('Before.');

		unmount(app);
		host.remove();
	});
});
