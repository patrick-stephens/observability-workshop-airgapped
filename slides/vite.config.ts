import { defineConfig } from 'vite'
import { viteSingleFile } from 'vite-plugin-singlefile'

export default defineConfig({
  base: './',
  plugins: [
    viteSingleFile(),
    {
      name: 'remove-remote-slidev-favicon',
      transformIndexHtml(html) {
        return html.replace(/<link rel="icon" href="https:\/\/cdn\.jsdelivr\.net\/gh\/slidevjs\/slidev\/assets\/favicon\.png">/g, '')
      },
    },
    {
      name: 'disable-slidev-chunk-splitting',
      enforce: 'post',
      configResolved(config) {
        const output = config.build.rollupOptions.output
        if (output && !Array.isArray(output))
          delete output.manualChunks
      },
    },
  ],
  build: {
    assetsInlineLimit: 10_000_000,
    cssCodeSplit: false,
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
      },
    },
  },
})
