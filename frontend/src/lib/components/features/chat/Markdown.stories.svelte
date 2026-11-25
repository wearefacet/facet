<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import Markdown from './Markdown.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/Markdown',
		component: Markdown,
		tags: ['autodocs'],
		args: {
			streaming: false
		}
	});
</script>

<Story
	name="Paragraphs"
	args={{
		content:
			'This is a **bold** word and an *italic* one. It supports `inline code` and [links](https://example.com).\n\nSecond paragraph after a blank line.'
	}}
/>

<Story
	name="Headings"
	args={{
		content:
			'# Heading 1\n## Heading 2\n### Heading 3\n#### Heading 4\n\nBody text under the headings.'
	}}
/>

<Story
	name="Lists"
	args={{
		content:
			'- Unordered item one\n- Unordered item two\n  - Nested item\n    - Deeper nested item\n      - Deepest nested item\n- Unordered item three\n\n1. Ordered item one\n2. Ordered item two\n3. Ordered item three\n\n1. Outer ordered\n   1. Inner ordered (lower-alpha)\n   2. Another inner item'
	}}
/>

<Story
	name="TaskList"
	args={{
		content:
			'- [x] Completed task\n- [ ] Incomplete task\n- [x] Another completed one\n- [ ] And one more\n\nRegular list item afterward:\n\n- Not a task'
	}}
/>

<Story
	name="Definitions"
	args={{
		content:
			'Electron\n: A subatomic particle with negative charge.\n: Also the name of a JavaScript framework.\n\nPhoton\n: An elementary particle, the quantum of light.\n\nParagraph after the list.'
	}}
/>

<Story
	name="HighlightSubSup"
	args={{
		content:
			'Highlights: ==this is highlighted text== and ==**bold highlighted**==.\n\nFormulas: H~2~O is water, X^2^ is x-squared, and e~mc~^2^ is Einstein.\n\nNot strikethrough: ~~del~~ vs subscript: H~2~O.'
	}}
/>

<Story
	name="InlineHTML"
	args={{
		content:
			'Press <kbd>Ctrl</kbd>+<kbd>C</kbd> to copy.\n\n<kbd>Shift</kbd>+<kbd>Tab</kbd> to unindent.\n\n<mark>marked text</mark> <sub>sub</sub> <sup>sup</sup> <strong>bold</strong> <em>ital</em>.\n\nUnknown tag: <script>alert(1)</script> stays text.'
	}}
/>

<Story
	name="Emoji"
	args={{
		content:
			'Common emojis: :smile: :rocket: :+1: :heart: :tada: :fire: :100: :warning: :white_check_mark: :bug: :coffee: :bulb: :zap: :star: :eyes: :thumbsup: :thumbsdown: :wave: :tada:\n\nUnknown: :not_a_real_emoji: stays as text.'
	}}
/>

<Story
	name="Blockquote"
	args={{
		content: '> This is a quoted passage.\n> It can span multiple lines.\n\nNormal paragraph after.'
	}}
/>

<Story
	name="Image"
	args={{
		content:
			'Here is a diagram:\n\n![Facet logo](https://placehold.co/320x120?text=example+image)\n\nCaption text after.'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// An https image renders a real <img> with its remote source.
		const img = canvas.getByRole('img', { name: 'Facet logo' });
		await expect(img).toHaveAttribute('src', 'https://placehold.co/320x120?text=example+image');
	}}
/>

<Story
	name="LinkSchemesAllowed"
	args={{
		content:
			'Read the [https link](https://example.com/page) or send an [email](mailto:team@example.com).'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// https and mailto stay anchors with their scheme intact.
		await expect(canvas.getByRole('link', { name: 'https link' })).toHaveAttribute(
			'href',
			'https://example.com/page'
		);
		await expect(canvas.getByRole('link', { name: 'email' })).toHaveAttribute(
			'href',
			'mailto:team@example.com'
		);
	}}
/>

<Story
	name="JavascriptLinkNeutralized"
	args={{
		content: 'Do not click [this](javascript:alert(1)) or [that](JAVASCRIPT:alert(2)).'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// No anchor is emitted for a javascript: scheme; the text stays.
		await expect(canvas.queryAllByRole('link')).toHaveLength(0);
		await expect(canvas.getByText('Do not click this or that.')).toBeVisible();
		// The raw scheme never reaches the DOM as an href.
		await expect(canvasElement.querySelector('a')).toBeNull();
	}}
/>

<Story
	name="RemoteImageNeutralized"
	args={{
		content:
			'Blocked: ![tracker](javascript:alert(1)) and ![data](data:image/png;base64,iVBORw0KGgo=) and ![relative](/logo.png).'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// No <img> is emitted for a javascript:, data: or relative source,
		// so the browser never fetches it. The alt text stays readable.
		await expect(canvas.queryAllByRole('img')).toHaveLength(0);
		await expect(canvasElement.querySelector('img')).toBeNull();
		await expect(canvas.getByText('Blocked: tracker and data and relative.')).toBeVisible();
	}}
/>

<Story
	name="Table"
	args={{
		content:
			'| Field | Type | Required | Notes |\n|---|---|:---:|---|\n| `reference_no` | string | yes | Booking reference |\n| `status` | enum | no | booked · in_transit · delivered |\n| `weight_kg` | number | no | Gross weight |\n\nRight-aligned numbers:\n\n| Item | Qty | Price |\n|---|---:|---:|\n| A | 2 | 12.50 |\n| B | 10 | 3.00 |\n| **Total** | 12 | **15.50** |'
	}}
/>

<Story
	name="CodeHighlighted"
	args={{
		content:
			'Inline `code` here.\n\n```ts\ninterface Shipment {\n  reference_no: string;\n  status: "booked" | "in_transit" | "delivered";\n  weight_kg?: number;\n}\n\nfunction book(s: Shipment): string {\n  return s.reference_no;\n}\n```\n\nA SQL example:\n\n```sql\nSELECT id, status, weight_kg\nFROM logistics.shipments\nWHERE status = \'in_transit\'\nORDER BY created_at DESC;\n```'
	}}
/>

<Story
	name="CodeUnknownLang"
	args={{
		content: '```text\nThis is plain text in an unknown fence.\nNo highlighting applied.\n```'
	}}
/>

<Story
	name="Mermaid"
	args={{
		content:
			'A simple flowchart:\n\n```mermaid\nflowchart LR\n  A[Shipment booked] --> B{In transit?}\n  B -- yes --> C[Scan packages]\n  C --> D[Delivered]\n  B -- no --> E[Hold]\n```\n\nText after the diagram.'
	}}
/>

<Story
	name="MermaidSequence"
	args={{
		content:
			'```mermaid\nsequenceDiagram\n  participant U as User\n  participant A as Agent\n  participant DB as Database\n  U->>A: "Create shipment"\n  A->>DB: insert doctype\n  DB-->>A: ulid\n  A-->>U: "Done — id is ulid"\n```'
	}}
/>

<Story
	name="Streaming"
	args={{
		content: 'Receiving response…',
		streaming: true
	}}
/>
