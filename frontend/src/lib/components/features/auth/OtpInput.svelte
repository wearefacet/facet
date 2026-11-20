<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	OtpInput — one-time passcode entry, shared by the 2FA challenge and the
	TOTP enrollment screens. `length` mono boxes with auto-advance, arrow
	navigation, backspace-to-previous, and paste handling (digits only; the
	focus moves to the first box after the last pasted digit).
-->
<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	let {
		length = 6,
		code = $bindable(''),
		onEnter
	}: {
		/** Number of digit boxes. */
		length?: number;
		/** The passcode so far — two-way bindable so the host form derives its submit state. */
		code?: string;
		/** Called on Enter when the code is complete (the form-submit equivalent). */
		onEnter?: (code: string) => void;
	} = $props();

	// One $state string drives every box display; per-box writes fold through
	// `code`, so paste and backspace auto-advance stay natural.
	const boxes = $derived(Array.from({ length }, (_, i) => code[i] ?? ''));
	const complete = $derived(code.length === length);
	let inputs: HTMLInputElement[] = $state([]);

	const focusBox = (i: number) => {
		const target = inputs[i];
		target?.focus();
		target?.select();
	};

	const handleInput = (i: number, e: Event) => {
		const input = e.target as HTMLInputElement;
		const value = input.value.replace(/[^0-9]/g, '');
		if (!value) {
			input.value = code[i] ?? '';
			return;
		}
		// Render mirrors `code`, so reset the input's own value to the single digit.
		const next = code.slice(0, i) + value.slice(-1) + code.slice(i + 1);
		code = next.slice(0, length);
		input.value = code[i] ?? '';
		if (i < length - 1) focusBox(i + 1);
	};

	const handleKeydown = (i: number, e: KeyboardEvent) => {
		if (e.key === 'Backspace' && !code[i] && i > 0) {
			e.preventDefault();
			const next = code.slice(0, i - 1) + code.slice(i);
			code = next.slice(0, length);
			focusBox(i - 1);
		} else if (e.key === 'ArrowLeft' && i > 0) {
			e.preventDefault();
			focusBox(i - 1);
		} else if (e.key === 'ArrowRight' && i < length - 1) {
			e.preventDefault();
			focusBox(i + 1);
		} else if (e.key === 'Enter' && complete) {
			e.preventDefault();
			onEnter?.(code);
		}
	};

	const handlePaste = (e: ClipboardEvent) => {
		e.preventDefault();
		const pasted = e.clipboardData?.getData('text') ?? '';
		const digits = pasted.replace(/[^0-9]/g, '').slice(0, length);
		if (!digits) return;
		code = digits.slice(0, length);
		// Focus the box after the last pasted digit (the last box when full).
		focusBox(Math.min(digits.length, length - 1));
	};
</script>

<div class="otp-row" role="group" aria-label={m.auth_otp_aria()}>
	{#each boxes as digit, i (i)}
		<input
			bind:this={inputs[i]}
			class="otp-box"
			class:otp-filled={Boolean(digit)}
			type="text"
			inputmode="numeric"
			autocomplete={i === 0 ? 'one-time-code' : 'off'}
			maxlength={1}
			value={digit}
			aria-label={m.auth_otp_digit_aria({ index: i + 1, length })}
			oninput={(e) => handleInput(i, e)}
			onkeydown={(e) => handleKeydown(i, e)}
			onpaste={handlePaste}
		/>
	{/each}
</div>

<style>
	.otp-row {
		display: flex;
		justify-content: center;
		gap: 8px;
	}

	.otp-box {
		width: 48px;
		height: 56px;
		text-align: center;
		font-family: var(--font-mono);
		font-size: 22px;
		font-weight: 500;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		outline: none;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
		padding: 0;
	}

	.otp-box:focus-visible {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.otp-box.otp-filled {
		border-color: var(--border-strong);
	}
</style>
