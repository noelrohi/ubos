import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'https://ubos.noelrohi.com',
  vite: {
    plugins: [tailwindcss()]
  }
});
