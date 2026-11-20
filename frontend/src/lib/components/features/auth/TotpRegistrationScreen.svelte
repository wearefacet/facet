<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	TotpRegistrationScreen — full-screen TOTP enrollment surface.

	Two-step flow driven by the `status` prop:
	  - 'setup'    → QR + manual secret + 6-digit verification code
	  - 'verifying'→ same as setup, with the verify button in loading state
	  - 'verified' → success header + backup codes grid + confirmation button

	The QR code SVG is generated with `uqr` (renderSVG) from an
	`otpauth://totp/...` URI built from `issuer`, `account`, and `secret`.
	Scanners require high module contrast, so the QR always renders
	`#000` on `#fff` regardless of theme (intentional exception, like the
	toggle-thumb carve-out in design-guideline.html).
-->
<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { renderSVG } from 'uqr';
	import { ShieldCheck, ArrowLeft, ArrowRight, CircleCheckBig, Lock, QrCode } from '@lucide/svelte';
	import Button from '../../primitives/actions/Button.svelte';
	import CopyButton from '$lib/components/primitives/data/CopyButton.svelte';
	import AuthShell from './AuthShell.svelte';
	import OtpInput from './OtpInput.svelte';

	let {
		product = 'Facet',
		issuer = 'Facet',
		account = 'user@example.com',
		secret,
		backupCodes = [],
		status = 'setup',
		error,
		length = 6,
		/** Server-built `otpauth://` URI (enroll-at-login). Overrides the URI
		 * built locally from `issuer`/`account` for the QR code; the account
		 * label is read back from it for the manual-entry metadata row. */
		otpauthUri,
		/** Overrides the cancel-link text (e.g. "Skip for now" on the dismissible
		 * enrollment prompt). The link only renders when `onCancel` is set. */
		cancelLabel = m.auth_back_signin(),
		/** Side of the cancel-link arrow. `left` reads as "go back" (default,
		 * e.g. "Back to sign in"); `right` reads as "move past this" (e.g. the
		 * dismissible enrollment prompt). */
		cancelArrow = 'left',
		onverify,
		onCancel,
		onDone
	}: {
		product?: string;
		issuer?: string;
		account?: string;
		secret: string;
		backupCodes?: string[];
		status?: 'setup' | 'verifying' | 'verified';
		error?: string;
		length?: number;
		otpauthUri?: string;
		cancelLabel?: string;
		cancelArrow?: 'left' | 'right';
		onverify?: (code: string) => void;
		onCancel?: () => void;
		onDone?: () => void;
	} = $props();

	// ── otpauth URI (RFC 6238) ────────────────────────────────────────────
	const label = $derived(encodeURIComponent(`${issuer}:${account}`));
	const localOtpauthUri = $derived(
		`otpauth://totp/${label}?secret=${encodeURIComponent(secret)}&issuer=${encodeURIComponent(
			issuer
		)}&algorithm=SHA1&digits=${length}&period=30`
	);
	const effectiveUri = $derived(otpauthUri ?? localOtpauthUri);

	// The server-built URI carries the real issuer:account label; read the
	// account back out of its `otpauth://totp/<issuer>:<account>` path so the
	// metadata row matches what the user scans. Falls back to the prop.
	const displayAccount = $derived.by(() => {
		if (!otpauthUri) return account;
		try {
			const parsed = new URL(otpauthUri);
			const uriLabel = decodeURIComponent(parsed.pathname.replace(/^\/+/, ''));
			const sep = uriLabel.indexOf(':');
			return sep >= 0 ? uriLabel.slice(sep + 1) : uriLabel;
		} catch {
			return account;
		}
	});

	// ── QR SVG (high-contrast, theme-independent) ─────────────────────────
	const qrSvg = $derived(renderSVG(effectiveUri, { pixelSize: 6, border: 2, boostEcc: true }));

	// ── Secret formatting (groups of 4 for readability) ──────────────────
	const formattedSecret = $derived(
		(
			secret
				.toUpperCase()
				.replace(/\s/g, '')
				.match(/.{1,4}/g) ?? []
		).join(' ')
	);

	// ── OTP entry ─────────────────────────────────────────────────────────
	let code = $state('');
	const complete = $derived(code.length === length);

	const verifying = $derived(status === 'verifying');
	const isVerified = $derived(status === 'verified');

	function handleVerify(e: SubmitEvent) {
		e.preventDefault();
		if (!complete) return;
		onverify?.(code);
	}
</script>

<AuthShell maxWidth={460} gap={18} subMaxWidth={340} {error}>
	{#snippet icon()}
		{#if isVerified}
			<CircleCheckBig size={22} />
		{:else}
			<ShieldCheck size={22} />
		{/if}
	{/snippet}

	{#snippet title()}
		{#if isVerified}
			{m.auth_totp_enabled_title()}
		{:else}
			{m.auth_totp_setup_title()}
		{/if}
	{/snippet}

	{#snippet sub()}
		{#if isVerified}
			{m.auth_totp_backup_sub()}
		{:else}
			{m.auth_totp_scan_sub({ product })}
		{/if}
	{/snippet}

	{#snippet footer()}
		{#if onCancel}
			<button class="link-btn" type="button" onclick={onCancel} data-testid="totp-cancel">
				{#if cancelArrow === 'right'}
					{cancelLabel}
					<ArrowRight size={13} />
				{:else}
					<ArrowLeft size={13} />
					{cancelLabel}
				{/if}
			</button>
		{/if}
	{/snippet}

	{#if isVerified}
		<!-- ── Step 2: backup codes ────────────────────────────────────────── -->
		<div class="backup-wrap">
			{#if backupCodes.length > 0}
				<div class="backup-grid" role="list" aria-label={m.auth_totp_backup_aria()}>
					{#each backupCodes as backupCode (backupCode)}
						<code class="backup-code" role="listitem">{backupCode}</code>
					{/each}
				</div>
			{:else}
				<p class="backup-empty">{m.auth_totp_backup_empty()}</p>
			{/if}

			<p class="backup-warning">
				<Lock size={12} aria-hidden="true" />
				{m.auth_totp_backup_warning()}
			</p>
		</div>

		<div class="totp-actions">
			<Button variant="primary" size="lg" onclick={onDone}>{m.auth_totp_done_button()}</Button>
		</div>
	{:else}
		<!-- ── Step 1: QR + secret + verify ─────────────────────────────── -->
		<div class="qr-wrap" aria-label={m.auth_totp_qr_aria()}>
			<div class="qr-frame">
				<!-- eslint-disable-next-line svelte/no-at-html-tags -- uqr output is a sanitized SVG string -->
				{@html qrSvg}
			</div>
		</div>

		<dl class="secret-block">
			<dt class="secret-label">{m.auth_totp_secret_label()}</dt>
			<dd class="secret-value">
				<code class="secret-str">{formattedSecret}</code>
				<CopyButton value={secret} size="sm" title={m.auth_totp_copy_label()} />
			</dd>
			<dd class="secret-meta">
				<span><QrCode size={11} aria-hidden="true" /> {issuer}</span>
				<span>{displayAccount}</span>
				<span>{m.auth_totp_digits({ length })}</span>
			</dd>
		</dl>

		<form class="verify-form" onsubmit={handleVerify}>
			<p class="verify-label">{m.auth_totp_enter_code({ length })}</p>
			<OtpInput bind:code {length} onEnter={(c) => onverify?.(c)} />

			<Button type="submit" variant="primary" size="lg" disabled={!complete} loading={verifying}>
				{m.auth_totp_verify_button()}
			</Button>
		</form>
	{/if}
</AuthShell>

<style>
	/* ── QR code ──────────────────────────────────────────────────────────── */
	.qr-wrap {
		display: flex;
		justify-content: center;
	}

	.qr-frame {
		padding: 12px;
		background: #fff;
		border: 1px solid var(--border);
		border-radius: var(--r);
		box-shadow: var(--sh-1);
		line-height: 0;
	}

	.qr-frame :global(svg) {
		display: block;
		width: 180px;
		height: 180px;
	}

	/* ── Secret block ─────────────────────────────────────────────────────── */
	.secret-block {
		margin: 0;
		padding: 12px 14px;
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: var(--r);
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.secret-label {
		font-size: 11px;
		font-weight: 500;
		text-transform: uppercase;
		letter-spacing: 0.06em;
		color: var(--text-3);
	}

	.secret-value {
		margin: 0;
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 10px;
	}

	.secret-str {
		font-family: var(--font-mono);
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text);
		word-break: break-all;
	}

	.secret-meta {
		margin: 0;
		display: flex;
		flex-wrap: wrap;
		gap: 6px 12px;
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
	}

	.secret-meta span {
		display: inline-flex;
		align-items: center;
		gap: 4px;
	}

	/* ── OTP verification ─────────────────────────────────────────────────── */
	.verify-form {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.verify-label {
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
		text-align: center;
	}

	.verify-form :global(.btn) {
		width: 100%;
	}

	/* ── Backup codes (verified state) ────────────────────────────────────── */
	.backup-wrap {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.backup-grid {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 6px;
		padding: 12px;
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: var(--r);
	}

	.backup-code {
		font-family: var(--font-mono);
		font-size: 13px;
		color: var(--text);
		padding: 6px 8px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		text-align: center;
	}

	.backup-empty {
		margin: 0;
		padding: 12px;
		font-size: 12.5px;
		color: var(--text-3);
		text-align: center;
	}

	.backup-warning {
		margin: 0;
		display: flex;
		align-items: center;
		gap: 6px;
		font-size: 11.5px;
		color: var(--warn);
	}

	.totp-actions :global(.btn) {
		width: 100%;
	}
</style>
