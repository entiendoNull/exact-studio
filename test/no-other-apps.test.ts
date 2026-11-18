import { test, expect } from 'bun:test';
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';

const banned = new Set<string>(["cf4da9b7e4d06e1b","7d847093e380dc42","85c639b37bc424c6","a95fa97908cd2ad7","cae9d3b20ba8a782","32161e08e0f2abdf","f46e567914d6bfc9","7a62c1187b4217e7","3ddc7207ef1d6794","9eb4e288ba9385b8","070678e702ab4896","9f92e4385343153b","784a2ddf5d4d61b6","3111e5a56bf201e5","750fda7b74e35f21","9e582bb3bb4154a7","71e3b7ab11b52fa3","14b77fa72ce9b8bc","47c104ca9531eb5b","196dfca50cac3028","dfc8dbbcfae4b79f","3db1f560db626918","0d85e5a40a0eec3d","f1206a09e2fa4965","422250f98a6081a5","f6bdac7b4546dc29"]);
const hash = (s: string) => new Bun.CryptoHasher('sha256').update(s).digest('hex').slice(0, 16);

test('the app and the repository never name another app', () => {
  const files = execSync('git ls-files', { cwd: import.meta.dir + '/..', encoding: 'utf8' }).split('\n')
    .filter(f => f && !/\.(png|jpe?g|gif|mov|mp4|wav|m4a|icns|ico|pdf)$/i.test(f));
  const hits: string[] = [];
  for (const f of files) {
    let text: string;
    try { text = readFileSync(import.meta.dir + '/../' + f, 'utf8'); } catch { continue; }
    text.split('\n').forEach((line, i) => {
      const words = line.toLowerCase().match(/[a-z0-9]+/g) ?? [];
      for (let n = 1; n <= 3; n++)
        for (let k = 0; k + n <= words.length; k++)
          if (banned.has(hash(words.slice(k, k + n).join('')))) hits.push(`${f}:${i + 1}`);
    });
  }
  expect(hits).toEqual([]);
});
