import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { drop, fixtures, library, root, run } from './library';
import { check } from './schema';

const update = process.env.UPDATE === '1';
const golden = join(root, 'test/golden');

function matches(name: string, actual: string) {
  const file = join(golden, name);
  if (update || !existsSync(file)) {
    mkdirSync(join(file, '..'), { recursive: true });
    writeFileSync(file, actual);
    console.warn(`wrote ${file}: check it, then commit it`);
  }
  expect(actual).toBe(readFileSync(file, 'utf8'));
}

const valid = readdirSync(join(fixtures, 'valid'));
const invalid = readdirSync(join(fixtures, 'invalid'));
const editsSchema = JSON.parse(readFileSync(join(root, 'schema/edits.schema.json'), 'utf8'));
const lookSchema = JSON.parse(readFileSync(join(root, 'schema/look.schema.json'), 'utf8'));
const json = (kind: string, id: string, file: string) => {
  const p = join(fixtures, kind, id, file);
  return existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : null;
};

let good = '', bad = '';
beforeAll(() => {
  good = library('valid', true);
  bad = library('invalid');
  run(good, 'list');
}, 300_000);
afterAll(() => {
  drop(good);
  drop(bad);
});

describe('valid recordings', () => {
  test('list names them, newest first', () => {
    const r = run(good, 'list');
    expect(r.code).toBe(0);
    matches('list.txt', r.out);
  });

  for (const id of valid) {
    test(`${id}: validate says ok`, () => {
      const r = run(good, 'validate', id);
      expect(r.out + r.err).toBe('ok\n');
      expect(r.code).toBe(0);
    });
    test(`${id}: show matches test/golden/show/${id}.txt`, () => {
      const r = run(good, 'show', id);
      expect(r.code).toBe(0);
      matches(`show/${id}.txt`, r.out);
    });
    test(`${id}: show --json matches test/golden/show/${id}.json`, () => {
      const r = run(good, 'show', id, '--json');
      expect(r.code).toBe(0);
      matches(`show/${id}.json`, r.out);
    });
    test(`${id}: its files follow the JSON Schemas`, () => {
      const edits = json('valid', id, 'edits.json'), look = json('valid', id, 'look.json');
      if (edits && edits.textLanes !== undefined) expect(check(editsSchema, edits)).toEqual([]);
      if (look) expect(check(lookSchema, look)).toEqual([]);
    });
  }

  test('frame renders one frame with the app renderer', () => {
    const out = join(good, 'frame.png');
    const r = run(good, 'frame', 'full', '2', '--out', out);
    expect(r.err).toBe('');
    expect(r.out).toBe('<library>/frame.png  1080×1920  video 0:02.00 = recording 0:02.00\n');
    expect(readFileSync(out).subarray(1, 4).toString()).toBe('PNG');
    const raw = run(good, 'frame', 'full', '2', '--raw', '--out', out);
    expect(raw.out.split('\n')[0]).toBe('<library>/frame.png  320×180  the full recorded frame at 0:02.00 (video 0:02.00), before the crop, no edits');
  });
});

describe('invalid recordings fail validate with the expected lines', () => {
  for (const id of invalid) {
    test(id, () => {
      const r = run(bad, 'validate', id);
      expect(r.code).toBe(1);
      matches(`validate/${id}.txt`, r.out);
    });
  }

  test('the files the decoder refuses break the schema too', () => {
    expect(check(editsSchema, json('invalid', 'wrong-type', 'edits.json'))).toEqual(['/lanes: "two" is not integer']);
    expect(check(lookSchema, json('invalid', 'bad-look', 'look.json'))).toEqual(['/padding: "lots" is not number']);
  });

  test('the schema refuses an unknown kind, a mask without its rect and a bad colour', () => {
    expect(check(editsSchema, json('invalid', 'unknown-kind', 'edits.json')).join('\n')).toContain('/segments/0/kind: "sparkle" is not one of');
    const masks = check(editsSchema, json('invalid', 'mask-problems', 'edits.json')).join('\n');
    expect(masks).toContain('/segments/0: missing rect');
    expect(masks).toContain('/segments/1/radius: 0.8 is above 0.5');
    expect(masks).toContain('/segments/1/color: matches none of its forms');
  });

  test.failing('KNOWN BUG: a segment without lane, or a move without style or duration, is refused though the schema allows it', () => {
    const edits = {
      textLanes: 0,
      segments: [{ id: 'z', kind: 'zoom', start: 1, end: 2, level: 2 }],
      moves: [{ id: 'm', t: 1, to: { x: 0.5, y: 0.5, scale: 1 } }],
    };
    expect(check(editsSchema, edits)).toEqual([]);
    const dir = library('valid');
    try {
      writeFileSync(join(dir, 'empty/edits.json'), JSON.stringify(edits));
      expect(run(dir, 'validate', 'empty').out).toBe('ok\n');
    } finally {
      drop(dir);
    }
  });
});

describe('verbs that change a recording leave it valid', () => {
  let lib = '';
  beforeAll(() => {
    lib = library('valid');
  });
  afterAll(() => drop(lib));

  test('template: each one replaces the edit and validates', () => {
    for (const name of ['launch', 'hero', 'tour', 'teaser']) {
      const r = run(lib, 'template', 'full', name);
      expect(r.code).toBe(0);
      expect(r.out).toMatch(new RegExp(`^${name} applied to full: \\d+ segments, \\d+ moves \\(edits.json\\)\\n$`));
      expect(run(lib, 'validate', 'full').out).toBe('ok\n');
      const edits = JSON.parse(readFileSync(join(lib, 'full/edits.json'), 'utf8'));
      expect(edits.segments.filter((s: any) => s.kind === 'image').map((s: any) => s.id)).toEqual(['img']);
      expect(edits.segments.filter((s: any) => s.kind === 'mask').map((s: any) => s.id).sort()).toEqual(['mask1', 'mask2']);
      expect(edits.splits).toEqual([3, 4.5, 7]);
    }
    expect(run(lib, 'template', 'full', 'nope').err).toBe('no template nope; one of launch, hero, tour, teaser\n');
  });

  test('image, sound and mask add a segment on a free lane and validate', () => {
    const image = run(lib, 'image', 'empty', join(fixtures, 'media/logo.png'), '--at', '2', '--for', '3');
    expect(image.code).toBe(0);
    expect(image.out).toStartWith('added to empty (edits.json), picture copied to images/logo');
    const again = run(lib, 'image', 'empty', join(fixtures, 'media/logo.png'), '--at', '3');
    expect(JSON.parse(again.out.slice(again.out.indexOf('{'))).lane).toBe(1);
    const sound = run(lib, 'sound', 'empty', join(fixtures, 'media/beep.wav'), '--at', '1');
    expect(sound.code).toBe(0);
    expect(JSON.parse(sound.out.slice(sound.out.indexOf('{'))).length).toBe(2);
    const mask = run(lib, 'mask', 'empty', '--rect', '0.1,0.2,0.3,0.05', '--at', '2', '--style', 'solid');
    expect(mask.code).toBe(0);
    expect(JSON.parse(mask.out.slice(mask.out.indexOf('{')))).toMatchObject({ kind: 'mask', style: 'solid', color: '#000000', lane: 0 });
    expect(run(lib, 'validate', 'empty').out).toBe('ok\n');
  });

  test('bad arguments are refused with exit 2 and a reason', () => {
    const outside = run(lib, 'mask', 'empty', '--rect', '0.9,0.2,0.3,0.05');
    expect(outside.code).toBe(2);
    expect(outside.err).toContain('its rect must lie inside the frame');
    expect(run(lib, 'mask', 'empty').err).toStartWith('--rect x,y,w,h is needed');
    expect(run(lib, 'image', 'empty', join(fixtures, 'media/logo.png'), '--at', '20').err).toStartWith('--at must be inside the recording');
    const missing = run(lib, 'show', 'nothing');
    expect(missing.code).toBe(2);
    expect(missing.err).toBe('no recording nothing in <library>\n');
    expect(run(lib, 'show', 'latest').out).toStartWith('Empty window  (window, empty)');
  });
});
