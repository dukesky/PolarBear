import { build } from 'esbuild';

await build({
  entryPoints: ['src/api.ts'],
  bundle: true,
  format: 'esm',
  outfile: 'test/.api.build.mjs',
});
