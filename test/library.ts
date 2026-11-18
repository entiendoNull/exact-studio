import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

export const root = join(import.meta.dir, '..');
export const fixtures = join(root, 'test/fixtures');
export const cli = join(root, 'exact-studio');

export function video(): string {
  const out = join(root, '.exact/test/capture.mov');
  const tool = join(root, 'test/model.sh');
  if (!existsSync(out) || statSync(out).mtimeMs < statSync(join(root, 'test/model/main.swift')).mtimeMs) {
    mkdirSync(join(root, '.exact/test'), { recursive: true });
    const r = spawnSync(tool, ['video', out], { stdio: 'inherit' });
    if (r.status !== 0) throw new Error('could not make the fixture video');
  }
  return out;
}

export function library(kind: 'valid' | 'invalid', withVideo = false): string {
  mkdirSync(join(root, '.exact/test'), { recursive: true });
  const dir = mkdtempSync(join(root, `.exact/test/${kind}-`));
  const mov = withVideo ? video() : '';
  for (const id of readdirSync(join(fixtures, kind))) {
    const to = join(dir, id);
    cpSync(join(fixtures, kind, id), to, { recursive: true });
    mkdirSync(join(to, 'images'), { recursive: true });
    mkdirSync(join(to, 'sounds'), { recursive: true });
    cpSync(join(fixtures, 'media/logo.png'), join(to, 'images/logo.png'));
    cpSync(join(fixtures, 'media/beep.wav'), join(to, 'sounds/beep.wav'));
    if (mov) cpSync(mov, join(to, 'capture.mov'));
  }
  return dir;
}

export function drop(dir: string) {
  rmSync(dir, { recursive: true, force: true });
}

export function run(lib: string, ...args: string[]) {
  const r = spawnSync(cli, [...args, '--library', lib], { cwd: root, encoding: 'utf8' });
  return { code: r.status ?? -1, out: r.stdout.split(lib).join('<library>'), err: r.stderr.split(lib).join('<library>') };
}
