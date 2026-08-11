import { build } from 'esbuild';
import { mkdirSync } from 'node:fs';

mkdirSync('../backend/app/widget', { recursive: true });
await build({
  entryPoints: ['src/index.ts'],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['es2019'],
  outfile: '../backend/app/widget/polarbear-widget.js',
  logLevel: 'info',
});
