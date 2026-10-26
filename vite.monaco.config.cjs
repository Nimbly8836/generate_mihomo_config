const { defineConfig } = require('vite');

module.exports = defineConfig({
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
  }
});
