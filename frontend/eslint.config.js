// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { includeIgnoreFile } from '@eslint/compat';
import js from '@eslint/js';
import prettier from 'eslint-config-prettier';
import globals from 'globals';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import svelte from 'eslint-plugin-svelte';
import tseslint from 'typescript-eslint';

const rootDir = path.dirname(fileURLToPath(import.meta.url));
const gitignorePath = path.join(rootDir, '.gitignore');

export default tseslint.config(
	// Honour .gitignore (node_modules, .svelte-kit, build, paraglide runtime).
	includeIgnoreFile(gitignorePath),
	// Committed directories with no lintable code.
	{ ignores: ['example/**', 'tmp/**'] },
	js.configs.recommended,
	...tseslint.configs.recommended,
	...svelte.configs.recommended,
	// TS types inside <script lang="ts"> (e.g. RequestInit) are not runtime
	// globals; no-undef must stay off there, like typescript-eslint does for
	// *.ts files.
	{
		files: ['**/*.svelte'],
		rules: { 'no-undef': 'off' }
	},
	// Prettier owns formatting; keep both config layers last so they can
	// turn off the rules that would fight it.
	...svelte.configs.prettier,
	prettier,
	{
		languageOptions: {
			globals: {
				...globals.browser,
				...globals.node
			}
		}
	},
	{
		// Parse TS inside <script lang="ts">, and lint runes modules
		// (*.svelte.ts) with the TS parser too.
		files: ['**/*.svelte', '**/*.svelte.ts', '**/*.svelte.js'],
		languageOptions: {
			parserOptions: {
				parser: tseslint.parser,
				extraFileExtensions: ['.svelte']
			}
		}
	},
	{
		rules: {
			// svelte-check owns compiler warnings (a11y_*, state_referenced_locally)
			// and ESLint cannot see which svelte-ignore comments suppress them, so
			// this rule only produces false positives in this setup.
			'svelte/no-unused-svelte-ignore': 'off',
			// The rule over-approximates: it flags every construction whose
			// variable might be mutated anywhere in the file, which forces
			// reactive wrappers on scratch collections and momentary timestamps
			// (see the untrack discipline in the workflow doc). Kept off until
			// the rule gains an escape hatch for local, non-state usage.
			'svelte/prefer-svelte-reactivity': 'off',
			'@typescript-eslint/no-unused-vars': [
				'error',
				{
					argsIgnorePattern: '^_',
					varsIgnorePattern: '^_',
					caughtErrorsIgnorePattern: '^_'
				}
			]
		}
	}
);
