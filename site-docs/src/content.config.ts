import { defineCollection } from 'astro:content';
import { docsLoader } from '@astrojs/starlight/loaders';
import { docsSchema } from '@astrojs/starlight/schema';
import { z } from 'astro:content';

export const collections = {
	docs: defineCollection({
		loader: docsLoader(),
		schema: docsSchema({
			extend: z.object({
				audience: z.array(z.string()).default([]),
				features: z.array(z.string()).default([]),
				verified_at: z.string().optional(),
			}),
		}),
	}),
};
