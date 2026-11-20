<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, waitFor, fn } from 'storybook/test';
	import DvtInputSecret from './DvtInputSecret.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputSecretNode, SecretStagePayload } from '$lib/template-types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputSecret',
		component: DvtInputSecret,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' },
			values: { control: 'object' }
		}
	});

	function doc(data: Record<string, unknown>): DocumentResponse {
		return {
			data,
			meta: {
				id: 'test.1',
				mid: 'test.1',
				domain: 'test',
				doc_type: 'Account',
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}

	// The marker the backend persists in document content for a `secret`
	// field. The plaintext never appears in content — only this object does.
	const MARKER = { mode: 'hash', version: 1, set_at: '2025-01-01T00:00:00Z' } as const;

	// Synthetic stager — mimics `POST /Api/secrets/stage` returning a handle.
	// The handle is a fixed opaque string; stories assert it lands in the
	// values bag in place of any plaintext.
	const HANDLE = 'stage-handle-1';

	function syntheticStage(
		_payload: SecretStagePayload
	): Promise<{ handle: string; token?: string }> {
		return Promise.resolve({ handle: HANDLE });
	}

	const hashDef: DoctypeDef = {
		domain: 'test',
		doctype: 'Account',
		schema_version: 1,
		fields: [{ key: 'password', type: 'secret' }],
		children: [],
		actions: []
	};

	const tokenDef: DoctypeDef = {
		domain: 'test',
		doctype: 'Account',
		schema_version: 1,
		fields: [{ key: 'api_key', type: 'secret', mode: 'token' }],
		children: [],
		actions: []
	};

	// The component owns its field in the values bag: the init strip deletes the
	// persisted marker and the stage / clear writes land in place. Args stay
	// read-only — the session-local clone comes from `./session-bag.svelte.js` (see
	// audit 44 for the shared-page render-race class this avoids).
</script>

<Story
	name="CreateStagesHandle"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Reveal the gated input, type a plaintext, and blur so the change
		// event fires and the stage round-trip runs.
		await userEvent.click(canvas.getByRole('button', { name: 'Set value' }));
		const input = canvas.getByLabelText('Password') as HTMLInputElement;
		await userEvent.type(input, 'hunter2');
		await userEvent.tab();
		// The stager received the plaintext exactly once, bound to the right
		// field; the staged state renders the badge and the input is cleared.
		// Explicit budget — the default waitFor timeout (1s) is too tight for
		// a userEvent sequence + async effect on a loaded page.
		await waitFor(
			() => {
				expect(canvas.getByText('set · hash')).toBeVisible();
			},
			{ timeout: 4000 }
		);
		await expect(input).toHaveValue('');
		// No plaintext is ever rendered into the DOM.
		expect(canvas.queryByText('hunter2')).toBeNull();
		await expect(args.stageSecret).toHaveBeenCalledTimes(1);
		await expect(args.stageSecret).toHaveBeenCalledWith(
			expect.objectContaining({ field_path: 'password', value: 'hunter2', domain: 'test' })
		);
	}}
	args={{
		template: {
			type: 'input-secret',
			field: 'password',
			label: 'Password'
		} satisfies InputSecretNode,
		document: doc({}),
		values: { password: '' },
		def: hashDef,
		stageSecret: fn(syntheticStage)
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputSecret
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
				stageSecret={args.stageSecret}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ChangeStagesNewHandle"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The stored marker renders as a badge — never an input, never JSON.
		await expect(canvas.getByText('set · hash')).toBeVisible();
		expect(canvas.queryByRole('textbox')).toBeNull();
		// Reveal via "Change", type a replacement, and blur to re-stage.
		await userEvent.click(canvas.getByRole('button', { name: 'Change' }));
		const input = canvas.getByLabelText('Password') as HTMLInputElement;
		await userEvent.type(input, 'n3w-pass');
		await userEvent.tab();
		// The stager received the new plaintext exactly once; the badge stays.
		await waitFor(
			() => {
				expect(args.stageSecret).toHaveBeenCalledTimes(1);
			},
			{ timeout: 4000 }
		);
		await expect(args.stageSecret).toHaveBeenCalledWith(
			expect.objectContaining({ field_path: 'password', value: 'n3w-pass' })
		);
		expect(canvas.queryByText('n3w-pass')).toBeNull();
	}}
	args={{
		template: {
			type: 'input-secret',
			field: 'password',
			label: 'Password'
		} satisfies InputSecretNode,
		document: doc({ password: { ...MARKER } }),
		values: { password: { ...MARKER } },
		def: hashDef,
		stageSecret: fn(syntheticStage)
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputSecret
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
				stageSecret={args.stageSecret}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ClearSetsNull"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The stored value renders as a badge; Clear drops it and the field
		// offers the create-path "Set value" again.
		await expect(canvas.getByText('set · hash')).toBeVisible();
		await userEvent.click(canvas.getByRole('button', { name: 'Clear' }));
		await expect(canvas.getByRole('button', { name: 'Set value' })).toBeVisible();
		expect(canvas.queryByText('set · hash')).toBeNull();
	}}
	args={{
		template: {
			type: 'input-secret',
			field: 'password',
			label: 'Password'
		} satisfies InputSecretNode,
		document: doc({ password: { ...MARKER } }),
		values: { password: { ...MARKER } },
		def: hashDef,
		stageSecret: fn(syntheticStage)
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputSecret
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
				stageSecret={args.stageSecret}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReadOnlySet"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Read-only renders the marker as a badge — never the marker JSON and
		// never an input surface.
		await expect(canvas.getByText('set · hash')).toBeVisible();
		await expect(canvas.queryByRole('textbox')).toBeNull();
	}}
	args={{
		template: {
			type: 'input-secret',
			field: 'password',
			label: 'Password'
		} satisfies InputSecretNode,
		document: doc({ password: { ...MARKER } }),
		def: hashDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputSecret template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="ReadOnlyUnset"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('—')).toBeVisible();
		await expect(canvas.queryByRole('textbox')).toBeNull();
	}}
	args={{
		template: {
			type: 'input-secret',
			field: 'password',
			label: 'Password'
		} satisfies InputSecretNode,
		document: doc({}),
		def: hashDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputSecret template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="TokenModeOneTimeDisplay"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Headless Chromium may reject clipboard writes; stub the API so the
		// click deterministically reaches the "Copied" state.
		Object.defineProperty(navigator, 'clipboard', {
			value: { writeText: async () => {} },
			configurable: true
		});
		// Token mode stages without a value — the server generates the token.
		await userEvent.click(canvas.getByRole('button', { name: 'Generate token' }));
		await waitFor(
			() => {
				expect(canvas.getByText('tok-one-time-9f2c')).toBeVisible();
			},
			{ timeout: 4000 }
		);
		// The one-time token is never rendered into the values bag (only the
		// handle is) — assert the stager got no `value` member in token mode.
		await expect(args.stageSecret).toHaveBeenCalledTimes(1);
		await expect(args.stageSecret).toHaveBeenCalledWith(
			expect.objectContaining({ field_path: 'api_key', domain: 'test', doctype: 'Account' })
		);
		await expect(args.stageSecret).toHaveBeenCalledWith(
			expect.not.objectContaining({ value: expect.anything() })
		);
		// One-time copy affordance. The shared CopyButton's accessible name is
		// its visible label, which flips to "Copied" on a successful copy.
		await userEvent.click(canvas.getByRole('button', { name: 'Copy' }));
		await expect(canvas.getByText('Copied')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-secret',
			field: 'api_key',
			label: 'API Key'
		} satisfies InputSecretNode,
		document: doc({}),
		values: { api_key: '' },
		def: tokenDef,
		stageSecret: fn((_payload: SecretStagePayload) =>
			Promise.resolve({ handle: HANDLE, token: 'tok-one-time-9f2c' })
		)
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputSecret
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
				stageSecret={args.stageSecret}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ExpiredHandleError"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A save that hits an expired handle returns a 422 whose field error
		// flows in through `fieldErrors` and renders inline as a re-entry
		// prompt — the stale handle is never resubmitted silently.
		await expect(canvas.getByText('Secret handle expired — re-enter the value')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-secret',
			field: 'password',
			label: 'Password'
		} satisfies InputSecretNode,
		document: doc({ password: { ...MARKER } }),
		values: { password: { ...MARKER } },
		def: hashDef,
		fieldErrors: { password: [{ message: 'Secret handle expired — re-enter the value' }] },
		stageSecret: fn(syntheticStage)
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputSecret
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
				fieldErrors={args.fieldErrors}
				stageSecret={args.stageSecret}
			/>
		</div>
	{/snippet}
</Story>

<!-- B-124 residual: the presented definition can drop the secret field's
	`mode` (the round-trip loss). When the definition carries no mode but the
	stored marker does, the badge and the Change/Generate behaviour read the
	marker's mode — a sealed value must not show the generic "set · hash". -->
<Story
	name="MarkerModeWinsWhenDefinitionLostIt"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The badge shows the marker's mode, not the 'hash' default.
		await expect(canvas.getByText('set · sealed')).toBeVisible();
		// Sealed mode stages a plaintext: the Change affordance shows.
		await expect(canvas.getByRole('button', { name: 'Change' })).toBeVisible();
		expect(canvas.queryByRole('button', { name: 'Generate new' })).toBeNull();
	}}
	args={{
		template: {
			type: 'input-secret',
			field: 'salary',
			label: 'Salary'
		} satisfies InputSecretNode,
		document: doc({
			salary: { mode: 'sealed', version: 2, set_at: '2025-01-01T00:00:00Z' }
		}),
		values: { salary: { mode: 'sealed', version: 2, set_at: '2025-01-01T00:00:00Z' } },
		// The definition lost `mode` (B-124): a bare secret field.
		def: hashDef,
		stageSecret: fn(syntheticStage)
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputSecret
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
				stageSecret={args.stageSecret}
			/>
		</div>
	{/snippet}
</Story>

<!-- B-191: the widget registers each stage attempt with the form — the
	in-flight promise lands on the registrar keyed by the field path, and a
	clear registers a resolved stage so it supersedes a failed attempt. The
	registrar in this story consumes rejections at the source, the same way
	the real form's registrar does. -->
<Story
	name="RegistersStageWithForm"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const registrar = args.registerFieldStage as unknown as {
			mock: { calls: unknown[][] };
		};
		// Reveal via "Change", type a replacement, and blur — the stage
		// attempt registers with the form before its round-trip resolves.
		await userEvent.click(canvas.getByRole('button', { name: 'Change' }));
		const input = canvas.getByLabelText('Password') as HTMLInputElement;
		await userEvent.type(input, 'hunter2');
		await userEvent.tab();
		await waitFor(
			() => {
				expect(registrar.mock.calls.length).toBe(1);
			},
			{ timeout: 4000 }
		);
		const [stagedField, stagedPromise] = registrar.mock.calls[0] as [string, Promise<void>];
		expect(stagedField).toBe('password');
		await expect(stagedPromise).rejects.toThrow('stage exploded');
		// The failure renders inline as before.
		await expect(canvas.getByRole('alert')).toBeVisible();

		// Clear is the field's latest stage state: it registers a resolved
		// stage that supersedes the failed attempt, so the save proceeds with
		// the cleared value.
		await userEvent.click(canvas.getByRole('button', { name: 'Clear' }));
		await waitFor(() => {
			expect(registrar.mock.calls.length).toBe(2);
		});
		const [clearedField, clearedPromise] = registrar.mock.calls[1] as [string, Promise<void>];
		expect(clearedField).toBe('password');
		await expect(clearedPromise).resolves.toBeUndefined();
	}}
	args={{
		template: {
			type: 'input-secret',
			field: 'password',
			label: 'Password'
		} satisfies InputSecretNode,
		document: doc({ password: { ...MARKER } }),
		values: { password: { ...MARKER } },
		def: hashDef,
		stageSecret: fn((_payload: SecretStagePayload) => Promise.reject(new Error('stage exploded'))),
		registerFieldStage: fn((field: string, stage: Promise<void>) => {
			void stage.catch(() => {});
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputSecret
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
				stageSecret={args.stageSecret}
				registerFieldStage={args.registerFieldStage}
			/>
		</div>
	{/snippet}
</Story>

<style>
	.dvt-story-frame {
		display: block;
		width: 100%;
		max-width: 720px;
		margin: 0 auto;
		padding: 24px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		min-height: 80px;
	}
</style>
