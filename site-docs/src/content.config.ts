import { defineCollection } from 'astro:content';
import { docsLoader } from '@astrojs/starlight/loaders';
import { docsSchema } from '@astrojs/starlight/schema';
import { z } from 'astro:content';

export const collections = {
	docs: defineCollection({
		loader: docsLoader(),
		schema: docsSchema({
			extend: z.object({
				// v2 page type (00-contract.md §4). Optional here because the
				// splash landing page carries no type; scripts/check-coverage.mjs
				// enforces it on every other page.
				type: z.enum(['overview', 'tutorial', 'how-to', 'explanation', 'reference']).optional(),
				audience: z.array(z.string()).default([]),
				features: z.array(z.string()).default([]),
				verified_at: z.string().optional(),
			}),
		}),
	}),
};
