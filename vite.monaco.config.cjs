const { defineConfig } = require('vite');

// Served by web_server.rb at /assets/monaco/* (exact allowlist), so worker URLs
// baked into editor.js must use this base and stable, unhashed file names.
module.exports = defineConfig({
  base: '/assets/monaco/',
  build: {
    outDir: 'web/vendor/monaco',
    emptyOutDir: false,
    lib: {
      entry: 'web/editor/main.js',
      name: 'MihomoMonacoEditorBundle',
      formats: ['iife'],
      fileName: () => 'editor.js'
    },
    rollupOptions: {
      output: {
        assetFileNames: info => info.name && info.name.endsWith('.css') ? 'editor.css' : '[name][extname]',
        chunkFileNames: '[name].js'
      }
    },
    cssCodeSplit: false,
    sourcemap: false,
    chunkSizeWarningLimit: 3000
  },
  worker: {
    rollupOptions: {
      output: {
        entryFileNames: 'assets/[name].js'
      }
    }
  }
});
