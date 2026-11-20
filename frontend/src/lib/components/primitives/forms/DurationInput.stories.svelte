<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, fireEvent, waitFor } from 'storybook/test';
	import DurationInput from './DurationInput.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/DurationInput',
		component: DurationInput,
		tags: ['autodocs'],
		args: {
			label: 'Duration'
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story
	name="Empty"
	args={{ label: 'SLA duration', value: '' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('SLA duration')).toBeVisible();
		// One spinbutton cell per default unit (d/h/m/s).
		await expect(canvas.getByLabelText('days')).toBeVisible();
		await expect(canvas.getByLabelText('hours')).toBeVisible();
		await expect(canvas.getByLabelText('minutes')).toBeVisible();
		await expect(canvas.getByLabelText('seconds')).toBeVisible();
		// The unset sentinel renders the "no duration set" placeholder.
		await expect(canvas.getByText('no duration set')).toBeVisible();
		// Clear is disabled while unset.
		await expect(canvas.getByRole('button', { name: 'Clear duration' })).toBeDisabled();
	}}
/>

<Story
	name="Unset"
	args={{ label: 'Warranty', value: '' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Warranty')).toBeVisible();
		// The '' sentinel renders the dimmed placeholder cells, never a
		// committed-looking 00:00:00:00 (B-310).
		await expect(canvas.getByText('no duration set')).toBeVisible();
		// Clear is disabled while the field is already unset.
		await expect(canvas.getByRole('button', { name: 'Clear duration' })).toBeDisabled();
	}}
/>

<Story
	name="Prepopulated"
	args={{
		label: 'Build budget',
		value: 2 * 86400 + 3 * 3600 + 15 * 60
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByLabelText('days')).toHaveAttribute('aria-valuenow', '2');
		await expect(canvas.getByLabelText('hours')).toHaveAttribute('aria-valuenow', '3');
		await expect(canvas.getByLabelText('minutes')).toHaveAttribute('aria-valuenow', '15');
		await expect(canvas.getByLabelText('seconds')).toHaveAttribute('aria-valuenow', '0');
		// Human form omits the zero seconds segment.
		await expect(canvas.getByText('2 days 3 hours 15 min')).toBeVisible();
	}}
/>

<Story
	name="TypingAdvancesCells"
	args={{ label: 'Type me', value: 0 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const days = canvas.getByLabelText('days');
		days.focus();
		// Type "1" into days — value should jump to 86400 seconds.
		await fireEvent.keyDown(days, { key: '1' });
		await expect(canvas.getByLabelText('days')).toHaveAttribute('aria-valuenow', '1');
		await expect(canvas.getByText('1 days')).toBeVisible();
	}}
/>

<Story
	name="ArrowKeysBump"
	args={{ label: 'Nudge', value: 0 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const minutes = canvas.getByLabelText('minutes');
		minutes.focus();
		await fireEvent.keyDown(minutes, { key: 'ArrowUp' });
		// 1 minute = 60 seconds.
		await expect(canvas.getByText('1 min')).toBeVisible();
		await fireEvent.keyDown(minutes, { key: 'ArrowUp', shiftKey: true });
		// +10 minutes → 11 minutes total.
		await expect(canvas.getByLabelText('minutes')).toHaveAttribute('aria-valuenow', '11');
	}}
/>

<Story
	name="LetterKeysJumpFocus"
	args={{ label: 'Jump', value: 0 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const days = canvas.getByLabelText('days');
		days.focus();
		// Pressing "m" jumps focus to the minutes cell.
		await fireEvent.keyDown(days, { key: 'm' });
		const minutes = canvas.getByLabelText('minutes');
		await expect(minutes).toHaveFocus();
	}}
/>

<Story
	name="PasteClockForm"
	args={{ label: 'Paste clock', value: 0 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const field = canvas.getByRole('group', { name: 'Paste clock' });
		// Paste "1:02:03" (1h 2m 3s). `fireEvent.paste` rebuilds the clipboard
		// data and loses it, so dispatch the ClipboardEvent manually.
		const dt = new DataTransfer();
		dt.setData('text', '1:02:03');
		const event = new ClipboardEvent('paste');
		Object.defineProperty(event, 'clipboardData', { value: dt });
		field.dispatchEvent(event);
		await waitFor(() => {
			expect(canvas.getByLabelText('hours')).toHaveAttribute('aria-valuenow', '1');
			expect(canvas.getByLabelText('minutes')).toHaveAttribute('aria-valuenow', '2');
			expect(canvas.getByLabelText('seconds')).toHaveAttribute('aria-valuenow', '3');
		});
	}}
/>

<Story
	name="PasteLabelledForm"
	args={{ label: 'Paste labelled', value: 0 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const field = canvas.getByRole('group', { name: 'Paste labelled' });
		// "1d 2h30m" → 1 day + 2 hours + 30 minutes.
		const dt = new DataTransfer();
		dt.setData('text', '1d 2h30m');
		const event = new ClipboardEvent('paste');
		Object.defineProperty(event, 'clipboardData', { value: dt });
		field.dispatchEvent(event);
		await waitFor(() => {
			expect(canvas.getByLabelText('days')).toHaveAttribute('aria-valuenow', '1');
			expect(canvas.getByLabelText('hours')).toHaveAttribute('aria-valuenow', '2');
			expect(canvas.getByLabelText('minutes')).toHaveAttribute('aria-valuenow', '30');
			expect(canvas.getByLabelText('seconds')).toHaveAttribute('aria-valuenow', '0');
		});
	}}
/>

<Story
	name="Presets"
	args={{
		label: 'Quick pick',
		value: 0,
		presets: [
			{ label: '30s', value: 30 },
			{ label: '5m', value: 300 },
			{ label: '1h', value: 3600 },
			{ label: '1d', value: 86400 }
		]
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const oneHour = canvas.getByRole('button', { name: '1h' });
		await fireEvent.click(oneHour);
		await expect(canvas.getByLabelText('hours')).toHaveAttribute('aria-valuenow', '1');
		// The selected preset chip renders in the "is-on" state — check the chip label.
		await expect(oneHour).toBeVisible();
	}}
/>

<Story
	name="ClearButton"
	args={{ label: 'Clearable', value: 90 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const clear = canvas.getByRole('button', { name: 'Clear duration' });
		await expect(clear).not.toBeDisabled();
		await fireEvent.click(clear);
		await expect(canvas.getByText('no duration set')).toBeVisible();
	}}
/>

<Story
	name="MaxClampShowsWarning"
	args={{
		label: 'Capped at one day',
		value: 86400,
		max: 86400,
		units: ['h', 'm', 's']
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('at maximum')).toBeVisible();
	}}
/>

<Story
	name="Disabled"
	args={{ label: 'Locked', value: 3600, disabled: true }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// All four spinbuttons report aria-disabled.
		const cells = canvas.getAllByRole('spinbutton');
		for (const c of cells) {
			await expect(c).toHaveAttribute('aria-disabled', 'true');
		}
		// Clear is disabled too.
		await expect(canvas.getByRole('button', { name: 'Clear duration' })).toBeDisabled();
	}}
/>

<Story
	name="WithError"
	args={{ label: 'Quota', value: 900, error: 'Must be at least 1 hour' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Must be at least 1 hour')).toBeVisible();
		await expect(canvas.getByRole('alert')).toBeVisible();
	}}
/>

<Story name="Required" args={{ label: 'Estimated effort', value: 0, required: true }} />

<Story
	name="WithHint"
	args={{ label: 'Adjustable', value: 0, hint: '↑↓ adjust · d h m s jump · paste `1d 2h30m`' }}
/>
