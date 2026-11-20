<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, waitFor, fn } from 'storybook/test';
	import Markdown from './Markdown.svelte';
	import type { PickerSources } from '$lib/referenceSearch.js';

	/** The args type erases the Mock; every play casts through this shape. */
	type AnyMock = { mock: { calls: unknown[][] } };
	const cbMock = (args: Record<string, unknown>, key: string): AnyMock =>
		args[key] as unknown as AnyMock;

	const SYNTHETIC_ID = '01HZZZZZZZZZZZZZZZZZZZZZZZ';
	const SYNTHETIC_URN = `urn:facet:artifact:${SYNTHETIC_ID}`;
	const SYNTHETIC_DOWNLOAD = `/Api/core/artifacts/${SYNTHETIC_ID}/download`;

	function syntheticUpload(file: File): Promise<{ id: string; filename: string }> {
		return Promise.resolve({ id: SYNTHETIC_ID, filename: file.name });
	}

	const { Story } = defineMeta({
		title: 'Components/Primitives/Content/Markdown',
		component: Markdown,
		tags: ['autodocs'],
		parameters: {
			// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
			// on this surface (contrast / ARIA structure). Fix, then remove.
			a11y: { test: 'todo' },
			docs: {
				description: {
					component:
						'Renders markdown through the Milkdown WYSIWYG engine — readonly preview or editable write — plus a raw markdown source editor (CodeMirror), with a fullscreen expand overlay.'
				}
			}
		}
	});

	const runbook = `# Invoice reconciliation

How extracted invoices flow from Echo into a reconciled state, and when a human is pulled in.

When a vendor invoice lands in the inbox, Echo extracts it against the invoice schema and writes a draft **Invoice** with a per-field confidence score. Anything below the domain threshold is flagged for review rather than auto-posted.

## The happy path

A high-confidence extraction is matched to its purchase order and moves straight to \`reconciled\`. For example, \`INV-2026-0487\` from \`DHL\` cleared at 96% and needed no human touch.

> Reconciliation never edits the source document. Corrections are appended as events, so the original extraction stays auditable.

## When review is required

- Confidence on a monetary field falls below \`0.80\`
- No matching purchase order is found within the domain
- The linked shipment — e.g. \`SHP-3369\` — is still in customs

---

Each reference above is a live capsule: one shape, coloured by doctype, resolving to the record on click.`;

	const sample = `# Hello world

This is **bold** and *italic* and \`code\`.

- One
- Two
- Three

> A quote.

## Sub-heading

A link here.`;

	const artifacts = `# Attachments

The runbook references a stored artifact by its URN:

![diagram](urn:facet:artifact:01HZZZZZZZZZZZZZZZZZZZZZZA)

The signed contract is attached: [contract.pdf](urn:facet:artifact:01HZZZZZZZZZZZZZZZZZZZZZZB), and a bare mention: urn:facet:artifact:01HZZZZZZZZZZZZZZZZZZZZZZC.`;

	const chromeSample = `# Chrome

A [link](https://facet.dev) in prose text.`;

	const mermaidSample = `# Flow

A fenced mermaid block renders as a diagram:

\`\`\`mermaid
graph TD
  A[Start] --> B[End]
\`\`\`

Text after the diagram.`;

	const mermaidInvalid = `\`\`\`mermaid
not a valid diagram
\`\`\``;

	/* Resolve a design token to the computed `rgb()` form, so color
	 * assertions stay theme-agnostic. */
	function tokenRgb(el: Element, name: string): string {
		const v = getComputedStyle(el).getPropertyValue(name).trim().replace('#', '');
		const n = parseInt(v, 16);
		return `rgb(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255})`;
	}

	/** A synthetic click that carries real coordinates. `userEvent.click`
	 *  dispatches untrusted events at (0,0), and ProseMirror's caret and
	 *  node-selection placement are coordinate-driven (`posAtCoords` bails
	 *  on (0,0)) — so write-mode chip clicks that must land a NodeSelection
	 *  dispatch mousedown/mouseup with the chip's centre directly. */
	function pmClick(chip: HTMLElement): void {
		const rect = chip.getBoundingClientRect();
		const opts = {
			bubbles: true,
			cancelable: true,
			view: window,
			clientX: rect.left + rect.width / 2,
			clientY: rect.top + rect.height / 2,
			button: 0
		};
		chip.dispatchEvent(new MouseEvent('mousedown', opts));
		chip.dispatchEvent(new MouseEvent('mouseup', opts));
		chip.dispatchEvent(new MouseEvent('click', opts));
	}

	// ── Mentions and references — synthetic sources ────────────────────
	// Every reference story injects this bundle, so no story touches the
	// network. `resolveLabel` pins the live-label, deleted and forbidden
	// chip states by id.
	const ADA_ID = '01HZZZZZZZZZZZZZZZZZZZZZAA';
	const COMPANY_ID = '01HZZZZZZZZZZZZZZZZZZZZZAC';
	const EMPLOYEE_ID = '01HZZZZZZZZZZZZZZZZZZZZZAE';
	const ADA_URN = `urn:facet:iam:Account:${ADA_ID}`;
	const COMPANY_URN = `urn:facet:crm:Company:${COMPANY_ID}`;
	const COMPANY_URL = `/crm/Company/${COMPANY_ID}`;
	const DELETED_ID = '01HZZZZZZZZZZZZZZZZZZZZZDE';
	const FORBIDDEN_ID = '01HZZZZZZZZZZZZZZZZZZZZZFO';

	const mockSources: PickerSources = {
		searchAccounts: async (q) =>
			[
				{ id: ADA_ID, name: 'Ada Lovelace' },
				{ id: '01HZZZZZZZZZZZZZZZZZZZZZAB', name: 'Bob Yeager' }
			].filter((a) => a.name.toLowerCase().includes(q.trim().toLowerCase())),
		listDoctypes: async () => [
			{
				target: 'crm.Company',
				domain: 'crm',
				name: 'Company',
				pluralLabel: 'companies',
				color: '#2266ff'
			},
			{
				target: 'hr.Employee',
				domain: 'hr',
				name: 'Employee',
				pluralLabel: 'employees',
				color: '#22aa66'
			}
		],
		searchDoctype: async (qualified) =>
			qualified === 'crm.Company'
				? [{ id: COMPANY_ID, label: 'Acme Corp', domain: 'crm', doctype: 'Company' }]
				: [],
		searchDomain: async () => [
			{
				key: 'crm.Company',
				domain: 'crm',
				doctype: 'Company',
				atCap: false,
				entries: [
					{
						key: `crm.Company.${COMPANY_ID}`,
						domain: 'crm',
						doctype: 'Company',
						id: COMPANY_ID,
						label: 'Acme Corp',
						subtitle: null
					}
				]
			}
		],
		searchAllDomains: async () => [
			{
				key: 'hr.Employee',
				domain: 'hr',
				doctype: 'Employee',
				atCap: false,
				entries: [
					{
						key: `hr.Employee.${EMPLOYEE_ID}`,
						domain: 'hr',
						doctype: 'Employee',
						id: EMPLOYEE_ID,
						label: 'Grace Hopper',
						subtitle: null
					}
				]
			},
			{
				key: 'crm.Company',
				domain: 'crm',
				doctype: 'Company',
				atCap: false,
				entries: [
					{
						key: `crm.Company.${COMPANY_ID}`,
						domain: 'crm',
						doctype: 'Company',
						id: COMPANY_ID,
						label: 'Acme Corp',
						subtitle: null
					}
				]
			}
		],
		recentDocuments: () => [{ id: COMPANY_ID, domain: 'crm', doctype: 'Company', ts: 1 }],
		resolveLabel: async (domain, _doctype, id) => {
			if (domain === 'iam' && id === ADA_ID) return { status: 'ok', label: 'Ada Lovelace' };
			if (domain === 'crm' && id === COMPANY_ID) return { status: 'ok', label: 'Acme Corp' };
			if (id === DELETED_ID) return { status: 'deleted' };
			if (id === FORBIDDEN_ID) return { status: 'forbidden' };
			return { status: 'unknown' };
		}
	};
</script>

<!-- ── Visual catalogue ─────────────────────────────────────────────────── -->

<Story name="Preview — runbook">
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={runbook} />
		</div>
	{/snippet}
</Story>

<Story name="Write — WYSIWYG">
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={sample} mode="write" />
		</div>
	{/snippet}
</Story>

<Story name="Markdown — source">
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={sample} mode="markdown" />
		</div>
	{/snippet}
</Story>

<Story name="Preview — empty">
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value="" />
		</div>
	{/snippet}
</Story>

<Story name="Readonly">
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={sample} readonly />
		</div>
	{/snippet}
</Story>

<Story name="Preview — artifact references">
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={artifacts} />
		</div>
	{/snippet}
</Story>

<Story name="Expanded — write">
	{#snippet template()}
		<div style="position:relative;width:100%;height:80vh;min-height:500px;overflow:hidden">
			<Markdown value={sample} mode="write" expanded={true} />
		</div>
	{/snippet}
</Story>

<Story name="Expanded — preview">
	{#snippet template()}
		<div style="position:relative;width:100%;height:80vh;min-height:500px;overflow:hidden">
			<Markdown value={sample} expanded={true} />
		</div>
	{/snippet}
</Story>

<!-- ── Behavioural tests ──────────────────────────────────────────────── -->

<Story
	name="Toggle to write"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args: _args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		// The Milkdown editor mounts and creates asynchronously.
		await waitFor(() => {
			expect(canvas.getByRole('textbox')).toBeInTheDocument();
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={sample} onchange={(v) => args.onchange?.(v)} />
		</div>
	{/snippet}
</Story>

<Story
	name="Write emits onchange"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		await userEvent.type(editor, ' edited');
		// The WYSIWYG editor emits the serialized markdown per transaction.
		await waitFor(() => expect(args.onchange).toHaveBeenCalled());
		// Switch back to preview — same engine, but readonly.
		await userEvent.click(canvas.getByRole('button', { name: 'Preview' }));
		const preview = canvas.getByRole('textbox');
		await waitFor(() => {
			expect(preview.getAttribute('contenteditable')).toBe('false');
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown defaultValue={sample} onchange={(v) => args.onchange?.(v)} />
		</div>
	{/snippet}
</Story>

<Story
	name="Undo realigns the bag to the stored value"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		// Type a genuine edit — the debounced serialization fires.
		await userEvent.type(editor, ' edited');
		await waitFor(() => expect(args.onchange).toHaveBeenCalled());
		const callsAfterEdit = cbMock(args, 'onchange').mock.calls.length;
		// Undo the edit. The document returns to the seeded one, and its
		// re-serialization differs only at marker level (a stored `- a`
		// serializes as `* a`). The undo emits once more, but it must emit the
		// exact seeded string, so the save diff folds to a no-op instead of
		// storing the restyled marker. Wait past the 200 ms debounce.
		await userEvent.keyboard('{Control>}z');
		await new Promise((resolve) => setTimeout(resolve, 500));
		const calls = cbMock(args, 'onchange').mock.calls.map((c) => JSON.stringify(c[0]));
		expect(calls.length, `emissions after undo: ${calls.join(' | ')}`).toBe(callsAfterEdit + 1);
		expect(calls[calls.length - 1], `last emission: ${calls.join(' | ')}`).toBe(
			JSON.stringify('- a')
		);
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown defaultValue="- a" onchange={(v) => args.onchange?.(v)} />
		</div>
	{/snippet}
</Story>

<Story
	name="Blank line stores clean markdown"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		// Type a paragraph, then a blank line (Enter twice), then a second
		// paragraph — the WYSIWYG shape that Milkdown serializes with a
		// literal `<br />` line for the empty paragraph.
		await userEvent.type(editor, 'First line.');
		await userEvent.keyboard('{Enter}{Enter}');
		await userEvent.type(editor, 'Second line.');
		// The emitted markdown must stay pure markdown: the empty-paragraph
		// `<br />` convention collapses to a plain paragraph break.
		await waitFor(() => {
			expect(args.onchange).toHaveBeenCalledWith(
				expect.stringContaining('First line.\n\nSecond line.')
			);
		});
		const latest = cbMock(args, 'onchange').mock.calls.at(-1)?.[0] as string | undefined;
		expect(latest).toBeDefined();
		expect(latest).not.toContain('<br');
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown defaultValue={sample} onchange={(v) => args.onchange?.(v)} />
		</div>
	{/snippet}
</Story>

<Story
	name="Switch to markdown source"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Markdown' }));
		const content = await waitFor(() => canvas.getByRole('textbox'));
		// The source editor holds the raw markdown, not rendered HTML.
		await expect(content.textContent).toContain('# Hello world');
		await expect(canvas.queryByRole('heading')).toBeNull();
	}}
>
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={sample} />
		</div>
	{/snippet}
</Story>

<Story
	name="Expand opens overlay"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const expandBtn = canvas.getByRole('button', { name: 'Expand' });
		await userEvent.click(expandBtn);
		// Dialog role appears when expanded
		await expect(canvas.getByRole('dialog')).toBeInTheDocument();
	}}
>
	{#snippet template()}
		<div style="position:relative;width:100%;height:80vh;min-height:500px;overflow:hidden">
			<Markdown value={sample} />
		</div>
	{/snippet}
</Story>

<Story
	name="Escape closes overlay"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Expand' }));
		await expect(canvas.getByRole('dialog')).toBeInTheDocument();
		await userEvent.keyboard('{Escape}');
		await expect(canvas.queryByRole('dialog')).toBeNull();
	}}
>
	{#snippet template()}
		<div style="position:relative;width:100%;height:80vh;min-height:500px;overflow:hidden">
			<Markdown value={sample} />
		</div>
	{/snippet}
</Story>

<Story
	name="Controlled value"
	args={{ value: '# Initial', onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Preview renders through Milkdown — the heading mounts asynchronously.
		await waitFor(() => {
			expect(canvas.getByRole('heading', { name: 'Initial' })).toBeInTheDocument();
		});
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		await userEvent.type(editor, ' edited');
		await waitFor(() => expect(args.onchange).toHaveBeenCalled());
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={args.value} onchange={(v) => args.onchange?.(v)} />
		</div>
	{/snippet}
</Story>

<!-- ── Editor chrome (caret / placeholder / icon ink) ───────────────────── -->

<Story
	name="Write — placeholder and caret ink"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		// The placeholder follows the app convention (--text-3), not the
		// theme's 40%-opacity text formula. Assert it before focusing —
		// the caret assertions below need focus.
		const placeholder = canvasElement.querySelector<HTMLElement>('.crepe-placeholder');
		expect(placeholder).not.toBeNull();
		expect(getComputedStyle(placeholder as Element, '::before').color).toBe(
			tokenRgb(document.body, '--text-3')
		);
		// The virtual caret replaces the native caret and must carry a
		// readable ink — never the border colour.
		await userEvent.click(editor);
		const caret = getComputedStyle(editor).getPropertyValue('--prosemirror-virtual-cursor-color');
		expect(caret.trim().toLowerCase()).toBe(
			getComputedStyle(document.body).getPropertyValue('--text-2').trim().toLowerCase()
		);
	}}
>
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value="" mode="write" />
		</div>
	{/snippet}
</Story>

<Story
	name="Write — link ink"
	play={async ({ canvasElement }) => {
		// Gold fill ≠ gold text: editor links paint with the AA ink token,
		// not the fill accent the frame theme uses by default.
		await waitFor(() => {
			const link = canvasElement.querySelector('.ProseMirror a');
			expect(link).not.toBeNull();
			expect(getComputedStyle(link as Element).color).toBe(tokenRgb(document.body, '--accent-ink'));
		});
	}}
>
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={chromeSample} mode="write" />
		</div>
	{/snippet}
</Story>

<!-- ── Artifact upload & rendering ─────────────────────────────────────── -->

<Story
	name="Preview renders artifact capsules"
	play={async ({ canvasElement }) => {
		// Preview renders through the same Milkdown engine as Write mode, so
		// the assertions target the editor DOM: an image-position URN loads
		// through the download gateway (Crepe's `proxyDomURL`), a link-position
		// URN is tagged as a capsule by the wrapper's decoration.
		await waitFor(() => {
			const img = canvasElement.querySelector('img');
			expect(img?.getAttribute('src')).toBe(
				'/Api/core/artifacts/01HZZZZZZZZZZZZZZZZZZZZZZA/download'
			);
		});
		const capsule = await waitFor(() => {
			const el = canvasElement.querySelector<HTMLElement>('.md-artifact-capsule-link');
			expect(el).not.toBeNull();
			return el as HTMLElement;
		});
		expect(capsule.getAttribute('data-artifact-id')).toBe('01HZZZZZZZZZZZZZZZZZZZZZZB');
		expect(capsule.textContent).toContain('contract.pdf');
	}}
>
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={artifacts} />
		</div>
	{/snippet}
</Story>

<Story
	name="Drop image uploads artifact"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		// Drop an image file onto the editor — the synthetic uploader stands
		// in for `POST /Api/core/artifacts`.
		const file = new File(['hello'], 'pixel.png', { type: 'image/png' });
		const transfer = new DataTransfer();
		transfer.items.add(file);
		const rect = editor.getBoundingClientRect();
		editor.dispatchEvent(
			new DragEvent('drop', {
				dataTransfer: transfer,
				bubbles: true,
				clientX: rect.left + rect.width / 2,
				clientY: rect.top + rect.height / 2
			})
		);
		// The editor DOM loads the artifact through the download gateway; the
		// serialized markdown keeps the URN.
		await waitFor(() => {
			const img = canvasElement.querySelector('img');
			expect(img?.getAttribute('src')).toBe(SYNTHETIC_DOWNLOAD);
		});
		await waitFor(() => {
			expect(args.onchange).toHaveBeenCalledWith(expect.stringContaining(SYNTHETIC_URN));
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				defaultValue={sample}
				uploadFile={syntheticUpload}
				onchange={(v) => args.onchange?.(v)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Drop non-image inserts capsule link"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		// Drop a PDF — Crepe's uploader only handles images, so the wrapper
		// takes over and inserts a capsule link labelled by the filename.
		const file = new File(['pdf-bytes'], 'contract.pdf', { type: 'application/pdf' });
		const transfer = new DataTransfer();
		transfer.items.add(file);
		editor.dispatchEvent(new DragEvent('drop', { dataTransfer: transfer, bubbles: true }));

		// The editor DOM renders the capsule link as a decorated span inside
		// the (href-sanitized) anchor; the serialized markdown keeps the URN.
		await waitFor(() => {
			const link = canvasElement.querySelector('.md-artifact-capsule-link');
			expect(link?.textContent).toBe('contract.pdf');
		});
		await waitFor(() => {
			expect(args.onchange).toHaveBeenCalledWith(
				expect.stringContaining(`[contract.pdf](${SYNTHETIC_URN})`)
			);
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				defaultValue={sample}
				uploadFile={syntheticUpload}
				onchange={(v) => args.onchange?.(v)}
			/>
		</div>
	{/snippet}
</Story>

<!-- ── Mentions and references (@ picker, chips, paste) ─────────────────── -->

<Story
	name="Mention picker inserts a mention"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		await userEvent.type(editor, 'Thanks @Ad');
		// The query moves the picker into domain mode, where the pinned People
		// group lists the account candidates from the sources bundle (the
		// empty state shows only recents + Filter by type).
		const row = await waitFor(() => canvas.getByRole('button', { name: /Ada Lovelace/ }));
		await userEvent.click(row);
		// The pick replaces the trigger and inserts the mention markdown link.
		await waitFor(() => {
			expect(args.onchange).toHaveBeenCalledWith(
				expect.stringContaining(`Thanks [@Ada Lovelace](${ADA_URN})`)
			);
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				defaultValue={sample}
				mode="write"
				domain="crm"
				sources={mockSources}
				onchange={(v) => args.onchange?.(v)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Dismissal keeps the literal text"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		await userEvent.type(editor, 'ping @');
		await waitFor(() => canvas.getByText('Filter by type'));
		await userEvent.keyboard('{Escape}');
		// Esc closes the picker and never deletes user input — the typed
		// trigger stays literal text. The emission lands on the editor's
		// debounced serialization — poll for it.
		await waitFor(() => {
			expect(canvas.queryByText('Filter by type')).toBeNull();
		});
		await waitFor(() => {
			const latest = cbMock(args, 'onchange').mock.calls.at(-1)?.[0] as string | undefined;
			expect(latest).toContain('ping @');
			expect(latest).not.toContain('urn:facet:iam:Account');
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				defaultValue={sample}
				mode="write"
				domain="crm"
				sources={mockSources}
				onchange={(v) => args.onchange?.(v)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Domain search groups and pick"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		await userEvent.type(editor, 'See @ac');
		// Domain mode fans out over the search endpoint (mocked here); the
		// People group leads, the document group follows.
		const docRow = await waitFor(() => canvas.getByRole('button', { name: /Acme Corp/ }));
		await userEvent.click(docRow);
		await waitFor(() => {
			expect(args.onchange).toHaveBeenCalledWith(
				expect.stringContaining(`See [Acme Corp](${COMPANY_URN})`)
			);
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				defaultValue={sample}
				mode="write"
				domain="crm"
				sources={mockSources}
				onchange={(v) => args.onchange?.(v)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Escalate to all domains"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args: _args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		await userEvent.type(editor, 'Find @ac');
		const escalate = await waitFor(() =>
			canvas.getByRole('button', { name: /Search all domains/ })
		);
		await userEvent.click(escalate);
		// All-domains mode streams the other domains in — the hr group
		// (mocked) appears beside the current domain's crm group.
		await waitFor(() => {
			expect(canvas.getByText('All domains')).toBeInTheDocument();
		});
		await waitFor(() => {
			expect(canvas.getByRole('button', { name: /Grace Hopper/ })).toBeInTheDocument();
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				defaultValue={sample}
				mode="write"
				domain="crm"
				sources={mockSources}
				onchange={(v) => args.onchange?.(v)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Scoped mode via Filter by type and Backspace out"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args: _args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		await userEvent.type(editor, 'Ref @');
		// Empty state: recents of the current domain + Filter by type.
		await waitFor(() => canvas.getByText('Recent'));
		await waitFor(() => canvas.getByText('Filter by type'));
		await userEvent.click(canvas.getByRole('button', { name: /companies/ }));
		// Scoped mode: the scope chip names the doctype, records browse.
		await waitFor(() => {
			expect(canvas.getByText('crm.Company')).toBeInTheDocument();
		});
		await waitFor(() => {
			expect(canvas.getByRole('button', { name: /Acme Corp/ })).toBeInTheDocument();
		});
		await userEvent.keyboard('{Backspace}');
		// Backspace on an empty query backs out to the empty state without
		// deleting the trigger.
		await waitFor(() => {
			expect(canvas.getByText('Filter by type')).toBeInTheDocument();
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				defaultValue={sample}
				mode="write"
				domain="crm"
				sources={mockSources}
				onchange={(v) => args.onchange?.(v)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Chips render live labels"
	play={async ({ canvasElement }) => {
		// The chip resolver resolves the current label through `show()` —
		// the stored link text is only the fallback. The labels land
		// asynchronously: poll for the resolved text on both chips.
		const mention = await waitFor(() => {
			const el = canvasElement.querySelector<HTMLElement>('.md-mention-chip');
			expect(el?.querySelector('.md-chip-label')?.textContent).toBe('@Ada Lovelace');
			return el as HTMLElement;
		});
		expect(mention.getAttribute('data-account-id')).toBe(ADA_ID);
		await waitFor(() => {
			const el = canvasElement.querySelector<HTMLElement>('.md-docref-chip');
			expect(el?.querySelector('.md-chip-label')?.textContent).toBe('Acme Corp');
		});
	}}
>
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				value={`Mentioned [@Ada](${ADA_URN}) about [Acme](${COMPANY_URN}).`}
				sources={mockSources}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Forbidden chip hides the stored title"
	play={async ({ canvasElement }) => {
		// 403 — the stored title may leak information to a viewer who lost
		// access, so the chip renders the stand-in instead.
		const chip = await waitFor(() => {
			const el = canvasElement.querySelector<HTMLElement>('.md-chip-forbidden');
			expect(el).not.toBeNull();
			return el as HTMLElement;
		});
		expect(chip.querySelector('.md-chip-label')?.textContent).toBe('Restricted document');
		const hidden = canvasElement.querySelector('.md-chip-source');
		if (hidden) expect(hidden).not.toBeVisible();
	}}
>
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				value={`Context: [Secret Doc](urn:facet:crm:Company:${FORBIDDEN_ID}).`}
				sources={mockSources}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Deleted chip strikes the stored label"
	play={async ({ canvasElement }) => {
		// 410 — the tombstone carries no readable title, so the stored text
		// stays as the label, struck through.
		const chip = await waitFor(() => {
			const el = canvasElement.querySelector<HTMLElement>('.md-chip-deleted');
			expect(el).not.toBeNull();
			return el as HTMLElement;
		});
		expect(chip.querySelector('.md-chip-label')?.textContent).toBe('Gone Doc');
	}}
>
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				value={`See [Gone Doc](urn:facet:crm:Company:${DELETED_ID}).`}
				sources={mockSources}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Paste converts a document URL into a chip"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		const transfer = new DataTransfer();
		transfer.setData('text/plain', COMPANY_URL);
		editor.dispatchEvent(new ClipboardEvent('paste', { clipboardData: transfer, bubbles: true }));
		// The URL resolves through `show()` and inserts as a reference link.
		await waitFor(() => {
			expect(args.onchange).toHaveBeenCalledWith(
				expect.stringContaining(`[Acme Corp](${COMPANY_URN})`)
			);
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				defaultValue={sample}
				mode="write"
				domain="crm"
				sources={mockSources}
				onchange={(v) => args.onchange?.(v)}
			/>
		</div>
	{/snippet}
</Story>

<!-- ── Reference chips — the ref_chip atom node ────────────────── -->

<Story
	name="Typing after a mention chip lands after the link"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		// The original misplacement bug: with the chip as a widget over hidden
		// link text, a space typed after a mention landed BEFORE it. The atom
		// node has one position boundary — the typed text follows the chip.
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		await userEvent.type(editor, 'Thanks @Ad');
		const row = await waitFor(() => canvas.getByRole('button', { name: /Ada Lovelace/ }));
		await userEvent.click(row);
		await waitFor(() => {
			expect(args.onchange).toHaveBeenCalledWith(
				expect.stringContaining(`Thanks [@Ada Lovelace](${ADA_URN})`)
			);
		});
		// The picker row took the DOM focus. Refocus the editor — ProseMirror
		// restores the caret the pick parked after the chip (synced on a
		// short timer), and `skipClick` keeps user-event's center-click from
		// landing the caret at an arbitrary spot in the document.
		editor.focus();
		await new Promise((resolve) => setTimeout(resolve, 80));
		await userEvent.type(editor, ' and Bob', { skipClick: true });
		await waitFor(() => {
			const latest = cbMock(args, 'onchange').mock.calls.at(-1)?.[0] as string | undefined;
			expect(latest).toMatch(new RegExp(`Thanks \\[@Ada Lovelace\\]\\(${ADA_URN}\\) and Bob`));
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				defaultValue={sample}
				mode="write"
				domain="crm"
				sources={mockSources}
				onchange={(v) => args.onchange?.(v)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Preview chip click emits the reference"
	args={{ onReferenceClick: fn() }}
	play={async ({ canvasElement, args }) => {
		const chip = await waitFor(() => {
			const el = canvasElement.querySelector<HTMLElement>('.md-mention-chip');
			expect(el).not.toBeNull();
			return el as HTMLElement;
		});
		await userEvent.click(chip);
		// The handler carries the parsed URN — the drawer renders its
		// tombstone/error cards for deleted/forbidden targets, so the emit
		// is unconditional on resolution state.
		await waitFor(() => {
			expect(args.onReferenceClick).toHaveBeenCalledTimes(1);
			expect(args.onReferenceClick).toHaveBeenCalledWith({
				domain: 'iam',
				doctype: 'Account',
				id: ADA_ID
			});
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				value={`Mentioned [@Ada](${ADA_URN}) about [Acme](${COMPANY_URN}).`}
				sources={mockSources}
				onReferenceClick={(e) => args.onReferenceClick?.(e)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Deleted and forbidden chips still emit"
	args={{ onReferenceClick: fn() }}
	play={async ({ canvasElement, args }) => {
		const chips = await waitFor(() => {
			const els = canvasElement.querySelectorAll<HTMLElement>(
				'.md-chip-deleted, .md-chip-forbidden'
			);
			expect(els.length).toBe(2);
			return Array.from(els);
		});
		for (const chip of chips) {
			await userEvent.click(chip);
		}
		// Deleted (410) and forbidden (403) targets still emit — the drawer
		// renders its tombstone (with restore) and error cards.
		await waitFor(() => {
			expect(args.onReferenceClick).toHaveBeenCalledTimes(2);
			expect(args.onReferenceClick).toHaveBeenCalledWith({
				domain: 'crm',
				doctype: 'Company',
				id: DELETED_ID
			});
			expect(args.onReferenceClick).toHaveBeenCalledWith({
				domain: 'crm',
				doctype: 'Company',
				id: FORBIDDEN_ID
			});
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				value={`See [Gone Doc](urn:facet:crm:Company:${DELETED_ID}) and [Secret Doc](urn:facet:crm:Company:${FORBIDDEN_ID}).`}
				sources={mockSources}
				onReferenceClick={(e) => args.onReferenceClick?.(e)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Write chip click selects, never emits"
	args={{ onReferenceClick: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const chip = await waitFor(() => {
			const el = canvasElement.querySelector<HTMLElement>('.md-mention-chip');
			expect(el).not.toBeNull();
			return el as HTMLElement;
		});
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		// A click that lands the NodeSelection must carry coordinates (see
		// `pmClick`) — ProseMirror's selection placement is coordinate-driven.
		pmClick(chip);
		// Edit mode: ProseMirror's node selection lands (the view's dom gets
		// the selectednode class) — the QuickView handler stays silent.
		await waitFor(() => {
			expect(chip).toHaveClass('ProseMirror-selectednode');
		});
		expect(args.onReferenceClick).not.toHaveBeenCalled();
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				defaultValue={`Mentioned [@Ada](${ADA_URN}) here.`}
				mode="write"
				sources={mockSources}
				onReferenceClick={(e) => args.onReferenceClick?.(e)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Preview chip click without a handler stays static"
	play={async ({ canvasElement }) => {
		const chip = await waitFor(() => {
			const el = canvasElement.querySelector<HTMLElement>('.md-mention-chip');
			expect(el).not.toBeNull();
			return el as HTMLElement;
		});
		await userEvent.click(chip);
		// No handler wired — the chip is static: no navigation fallback, no
		// crash, the chip itself survives the click.
		expect(canvasElement.querySelector('.md-mention-chip')).not.toBeNull();
	}}
>
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={`Mentioned [@Ada](${ADA_URN}) here.`} sources={mockSources} />
		</div>
	{/snippet}
</Story>

<Story
	name="Chip copy and paste round-trips the markdown"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		const chip = await waitFor(() => {
			const el = canvasElement.querySelector<HTMLElement>('.md-mention-chip');
			expect(el).not.toBeNull();
			return el as HTMLElement;
		});
		// Selecting the chip (NodeSelection) and copying serializes the atom
		// through its toDOM onto the HTML clipboard half. The NodeSelection
		// needs coordinates (see `pmClick`).
		pmClick(chip);
		const copyTransfer = new DataTransfer();
		editor.dispatchEvent(
			new ClipboardEvent('copy', { clipboardData: copyTransfer, bubbles: true })
		);
		const copied = copyTransfer.getData('text/html');
		expect(copied).toContain(`data-urn="${ADA_URN}"`);
		// Paste the copy after the chip — the parser rebuilds the node from
		// the same markup, so the emitted markdown is lossless. The editor is
		// focused from the chip click; skip user-event's center-click.
		await userEvent.type(editor, '{ArrowRight}', { skipClick: true });
		const pasteTransfer = new DataTransfer();
		pasteTransfer.setData('text/html', copied);
		editor.dispatchEvent(
			new ClipboardEvent('paste', { clipboardData: pasteTransfer, bubbles: true })
		);
		await waitFor(() => {
			expect(canvasElement.querySelectorAll('.md-mention-chip').length).toBe(2);
		});
		await waitFor(() => {
			const latest = cbMock(args, 'onchange').mock.calls.at(-1)?.[0] as string | undefined;
			expect(latest).toContain(`Mentioned [@Ada](${ADA_URN})[@Ada](${ADA_URN}) here.`);
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				defaultValue={`Mentioned [@Ada](${ADA_URN}) here.`}
				mode="write"
				sources={mockSources}
				onchange={(v) => args.onchange?.(v)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Preview — mermaid fence renders a diagram"
	play={async ({ canvasElement }) => {
		// Readonly preview: the `code_block` node view replaces the source
		// with the rendered diagram. Mermaid is lazy-loaded, so wait for the
		// SVG it injects.
		await waitFor(
			() => {
				const svg = canvasElement.querySelector('.md-mermaid svg');
				expect(svg).not.toBeNull();
			},
			{ timeout: 5000 }
		);
		// The fence's own source never shows in the readonly view.
		expect(canvasElement.querySelector('.md-mermaid-source')).toBeNull();
	}}
>
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={mermaidSample} />
		</div>
	{/snippet}
</Story>

<Story
	name="Preview — invalid mermaid shows the error card"
	play={async ({ canvasElement }) => {
		await waitFor(
			() => {
				expect(canvasElement.querySelector('.md-mermaid .mmd-error')).not.toBeNull();
			},
			{ timeout: 5000 }
		);
	}}
>
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={mermaidInvalid} />
		</div>
	{/snippet}
</Story>

<Story
	name="Write — mermaid fence splits source and diagram"
	args={{ onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		// The editor boots from `value` in preview mode; an external `value`
		// push fires no `markdownUpdated` (the listener skips an equal doc), so
		// edit the fence's own source to observe what the serializer writes
		// back — and to prove the source stays editable under the diagram.
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		// Edit mode keeps the source editable on top and the diagram below.
		const source = await waitFor(
			() => {
				const el = canvasElement.querySelector<HTMLElement>('.md-mermaid-source');
				expect(el).not.toBeNull();
				expect(canvasElement.querySelector('.md-mermaid svg')).not.toBeNull();
				return el as HTMLElement;
			},
			{ timeout: 5000 }
		);
		// Typing lands inside the fence. The fence survives the round-trip
		// byte-stable around the edit — same delimiter, same language tag.
		source.click();
		await userEvent.type(source, 'X');
		await waitFor(() => {
			const latest = cbMock(args, 'onchange').mock.calls.at(-1)?.[0];
			expect(typeof latest).toBe('string');
			expect(latest as string).toContain('```mermaid\ngraph TD\n  A[Start] --> B[End]X\n```');
		});
	}}
>
	{#snippet template(args)}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown value={mermaidSample} mode="write" onchange={(v) => args.onchange?.(v)} />
		</div>
	{/snippet}
</Story>

<Story
	name="Write — a non-mermaid fence keeps the code block"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		// The mermaid factory returns null for other languages — the default
		// code-block rendering stays (`<pre data-language="js">`), never the
		// diagram view. Crepe's own CodeMirror view mounts on scroll, so the
		// plain `pre` is the stable signal in a headless run.
		await waitFor(() => {
			expect(canvasElement.querySelector('.ProseMirror pre[data-language="js"]')).not.toBeNull();
		});
		expect(canvasElement.querySelector('.md-mermaid')).toBeNull();
	}}
>
	{#snippet template()}
		<div style="max-width:760px;min-height:200px;padding:24px">
			<Markdown
				value="```js
const x = 1;
```"
				mode="write"
			/>
		</div>
	{/snippet}
</Story>
