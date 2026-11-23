import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { larecsDocumentation } from './src/pipeline/integration.mjs';
const deployment = new URL(process.env.DOCS_BASE_URL || 'https://larecs.github.io/larecs/dev/');
// The sidebar renders a marked first entry as its group's linked label.
const overview = (slug) => ({ slug, attrs: { 'data-group-overview': '' } });
export default defineConfig({
  site: deployment.origin,
  base: deployment.pathname,
  trailingSlash: 'always',
  outDir: './public',
  publicDir: './static',
  markdown: { shikiConfig: { langs: [], defaultColor: 'light' } },
  integrations: [starlight({
    title: 'Larecs🌲',
    disable404Route: true,
    description: 'An Entity Component System for Mojo',
    social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/larecs/larecs' }],
    components: { SiteTitle: './src/components/SiteTitle.astro', PageSidebar: './src/components/PageSidebar.astro', Sidebar: './src/components/Sidebar.astro' },
    customCss: ['./src/styles/api.css'],
    sidebar: [
      { label: 'Start', items: [overview('start'), { autogenerate: { directory: 'start' } }] },
      { label: 'Guides', items: [
        overview('guide'), 'guide/data_model', 'guide/systems_kernels',
        'guide/single_entity', 'guide/structural_changes', 'guide/shared_resources',
        'guide/execution_backends', 'guide/spatial_locality', 'guide/development_workflow',
      ] },
      { label: 'API', items: [overview('larecs'), { autogenerate: { directory: 'larecs', collapsed: true } }] },
    ],
  }), larecsDocumentation()],
});
