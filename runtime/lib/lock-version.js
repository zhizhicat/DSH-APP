// The runtime tests pin against the DSH version the patched tree is built
// from. Read it from the locks directory (the runtime's own source of truth)
// instead of hard-coding a version that breaks on every upgrade.
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const locksDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'locks');

export default function lockVersion() {
  const versions = readdirSync(locksDir).filter((d) => d.startsWith('dsh-')).sort();
  if (versions.length === 0) throw new Error('no dsh lock directories found under runtime/locks');
  // Prefer the exact pinned version the tests are running against when told,
  // otherwise the newest lock (the version the CI chain builds).
  return (process.env.DSH_VERSION ?? versions.at(-1)).replace(/^dsh-/, '');
}
