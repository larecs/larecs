import { defineCollection, z } from 'astro:content';
import { i18nLoader } from '@astrojs/starlight/loaders';
import { docsSchema, i18nSchema } from '@astrojs/starlight/schema';
import { larecsLoader } from './pipeline/loader.mjs';
// API pages carry their pinned declaration source for the page sidebar.
const extend = z.object({ source: z.string().url().optional() });
export const collections = { i18n: defineCollection({ loader: i18nLoader(), schema: i18nSchema() }), docs: defineCollection({ loader: larecsLoader(), schema: docsSchema({ extend }) }) };
