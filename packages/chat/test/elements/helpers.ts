// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { flushSync } from 'svelte';
import { clearAssistantStorage } from '../../src/chat/assistantWindowState.js';

/**
 * Shared DOM-test plumbing for the custom elements.
 *
 * The tests run against the real element classes registered by the package
 * entry (`import '../../src/index.js'`), with the scripted mock driver
 * standing in for the backend.
 */

/** The package entry — importing it registers both custom elements. */
export async function importElements(): Promise<void> {
	await import('../../src/index.js');
}

/** Creates an inline `<facet-assistant>` with the given config, not yet attached. */
export function createInlineElement(config: {
	appId: string;
	driver: object;
	name?: string;
}): HTMLElement {
	const el = document.createElement('facet-assistant') as HTMLElement & {
		appId: string;
		driver: object;
		name?: string;
	};
	el.appId = config.appId;
	el.driver = config.driver;
	if (config.name) el.name = config.name;
	return el;
}

/** Creates a floating `<facet-assistant-window>` with the given config, not yet attached. */
export function createWindowElement(config: {
	appId: string;
	driver: object;
	name?: string;
}): HTMLElement & { close(): void; open(): void; toggle(): void; isOpen: boolean } {
	const el = document.createElement('facet-assistant-window') as HTMLElement & {
		appId: string;
		driver: object;
		name?: string;
		close(): void;
		open(): void;
		toggle(): void;
		isOpen: boolean;
	};
	el.appId = config.appId;
	el.driver = config.driver;
	if (config.name) el.name = config.name;
	return el;
}

/** Types a message into the panel's composer and flushes the DOM updates. */
export function typeMessage(shadowRoot: ShadowRoot, text: string): void {
	const textarea = shadowRoot.querySelector<HTMLTextAreaElement>('textarea');
	if (!textarea) throw new Error('composer textarea not found');
	textarea.value = text;
	textarea.dispatchEvent(new Event('input', { bubbles: true }));
	flushSync();
}

/** Clicks the send / stop button and flushes the DOM updates. */
export function clickSend(shadowRoot: ShadowRoot): void {
	const button = shadowRoot.querySelector<HTMLButtonElement>('.send');
	if (!button) throw new Error('send button not found');
	button.click();
	flushSync();
}

/** Detaches every element the suite mounted and clears persisted state. */
export function cleanupDom(): void {
	document.body.innerHTML = '';
	clearAssistantStorage();
}
