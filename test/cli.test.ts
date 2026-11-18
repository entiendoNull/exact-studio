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

  test('strip renders frames side by side in one PNG', () => {
    const out = join(good, 'strip.png');
    const r = run(good, 'strip', 'full', '1', '3', '--frames', '3', '--width', '300', '--out', out);
    expect(r.err).toBe('');
    expect(r.out).toBe('<library>/strip.png  300×171  3 frames, left to right, at video 0:01.00, 0:02.00, 0:03.00\n');
    expect(readFileSync(out).subarray(1, 4).toString()).toBe('PNG');
    expect(run(good, 'strip', 'full', '3', '1').code).not.toBe(0);
    expect(run(good, 'strip', 'full', '1', '3', '--frames', '20').err).toContain('--frames is 2–12');
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
    expect(masks).toContain('/segments/1/style: "glow" is not one of blur, pixels, solid');
    expect(readFileSync(join(golden, 'validate/mask-problems.txt'), 'utf8')).toContain('no mask style glow; one of blur, pixels, solid');
    expect(check(editsSchema, { segments: [{ id: 't', kind: 'text', start: 0, end: 1, text: 'Hi', style: 'pill' }] })).toEqual([]);
  });

  test('every key the format calls optional may be left out: validate, show and the verbs keep the edit', () => {
    const edits = {
      textLanes: 0,
      imageLanes: 1,
      base: { x: 0.4 },
      segments: [
        { id: 'z', kind: 'zoom', start: 1, end: 2, level: 2 },
        { id: 'k', kind: 'mask', start: 3, end: 4, rect: { x: 0.1, y: 0.1, w: 0.2, h: 0.2 } },
        {
          id: 'i', kind: 'image', start: 5, end: 9, file: 'images/logo.png',
          moves: [{ id: 'im', t: 7, to: { scale: 0.5 } }],
          effects: [{ id: 'fx', kind: 'pulse', start: 6, end: 7 }],
        },
      ],
      moves: [{ id: 'm', t: 1, to: { x: 0.5, y: 0.5, scale: 1 } }, { id: 'n', t: 3, to: { y: 0.6 }, angles: { turn: 20 } }],
      sounds: [{ id: 's', file: 'sounds/beep.wav', start: 0, length: 1 }],
    };
    expect(check(editsSchema, edits)).toEqual([]);
    const dir = library('valid');
    try {
      writeFileSync(join(dir, 'empty/edits.json'), JSON.stringify(edits));
      expect(run(dir, 'validate', 'empty').out).toBe('ok\n');
      const shown = run(dir, 'show', 'empty');
      expect(shown.code).toBe(0);
      expect(shown.out).toContain('e0: 0:01.00–0:02.00  zoom 2.0×  [z]');
      expect(shown.out).toContain('mask blur rect x 0.1 y 0.1 w 0.2 h 0.2 (full frame)');
      expect(shown.out).toContain('move lands 0:07.00 after 0.8s smooth: x 0.5 y 0.5 scale 0.5  [im]');
      expect(shown.out).toContain('effect pulse 0:06.00–0:07.00  [fx]');
      expect(shown.out).toContain('lands 0:01.00 after 0.8s smooth: x 0.5 y 0.5 scale 1.0  [m]');
      expect(shown.out).toContain('lands 0:03.00 after 0.8s smooth: x 0.5 y 0.6 scale 1.0  3D tilt 0.0 turn 20.0 roll 0.0  [n]');
      expect(shown.out).toContain('s0: from 0:00.00 for 1.0s');
      expect(run(dir, 'mask', 'empty', '--rect', '0.5,0.5,0.1,0.1', '--at', '6').code).toBe(0);
      const saved = JSON.parse(readFileSync(join(dir, 'empty/edits.json'), 'utf8'));
      expect(saved.segments.map((s: any) => s.id).slice(0, 3)).toEqual(['z', 'k', 'i']);
      expect(saved.moves.map((m: any) => [m.id, m.style, m.duration])).toEqual([['m', 'smooth', 0.8], ['n', 'smooth', 0.8]]);
      expect(saved.base).toEqual({ x: 0.4, y: 0.5, scale: 1 });
      expect(check(editsSchema, saved)).toEqual([]);
    } finally {
      drop(dir);
    }
  });
});

describe('where an effect applies', () => {
  test('every reach and a text\'s own effects validate, follow the schema and show what they cover', () => {
    const reaches = ['background', 'scene', 'frame', 'all'];
    const edits = {
      textLanes: 1,
      frameLanes: 1,
      segments: [
        { id: 'v', kind: 'blur', start: 1, end: 2 },
        ...reaches.map((scope, i) => ({ id: scope, kind: 'mono', start: 3 + i * 1.5, end: 4 + i * 1.5, lane: 0, scope })),
        { id: 't', kind: 'text', start: 1, end: 6, text: 'Hi', effects: [{ id: 'tb', kind: 'blur', start: 2, end: 3 }, { id: 'tf', kind: 'fade', start: 4, end: 5, level: 0.5 }] },
      ],
    };
    expect(check(editsSchema, edits)).toEqual([]);
    const dir = library('valid');
    try {
      writeFileSync(join(dir, 'empty/edits.json'), JSON.stringify(edits));
      expect(run(dir, 'validate', 'empty').out).toBe('ok\n');
      const shown = run(dir, 'show', 'empty').out;
      expect(shown).toContain('e0: 0:01.00–0:02.00  blur  [v]');
      expect(shown).toContain('f0: 0:03.00–0:04.00  mono (the background only)  [background]');
      expect(shown).toContain('f0: 0:04.50–0:05.50  mono (the video and the background)  [scene]');
      expect(shown).toContain('f0: 0:06.00–0:07.00  mono (whole frame)  [frame]');
      expect(shown).toContain('f0: 0:07.50–0:08.50  mono (whole frame, texts too)  [all]');
      expect(shown).toContain('effect blur 0:02.00–0:03.00  [tb]');
      expect(shown).toContain('effect fade to 0.5 0:04.00–0:05.00  [tf]');
    } finally {
      drop(dir);
    }
  });

  test('the schema refuses an unknown reach; validate names the reaches and a text\'s own effects', () => {
    expect(check(editsSchema, json('invalid', 'reach-problems', 'edits.json')).join('\n')).toContain('/segments/0/scope: "behind" is not one of video, background, scene, frame, all');
    const out = readFileSync(join(golden, 'validate/reach-problems.txt'), 'utf8');
    expect(out).toContain('no scope behind; one of video, background, scene, frame, all');
    expect(out).toContain('only a blur or a black and white (mono) has a scope');
    expect(out).toContain('A text has no pulse effect.');
  });
});

describe('depth: a text or an image behind the video', () => {
  test('layer and order validate, follow the schema and show where each item sits', () => {
    const edits = {
      textLanes: 1,
      imageLanes: 2,
      segments: [
        { id: 'logo', kind: 'image', start: 1, end: 6, lane: 0, file: 'images/logo.png', layer: 'behind' },
        { id: 'badge', kind: 'image', start: 1, end: 6, lane: 1, file: 'images/logo.png', order: 2 },
        { id: 'title', kind: 'text', start: 2, end: 5, text: 'Hello', layer: 'behind', order: 1 },
        { id: 'note', kind: 'text', start: 6, end: 8, text: 'Front', layer: 'front' },
      ],
    };
    expect(check(editsSchema, edits)).toEqual([]);
    const dir = library('valid');
    try {
      writeFileSync(join(dir, 'empty/edits.json'), JSON.stringify(edits));
      expect(run(dir, 'validate', 'empty').out).toBe('ok\n');
      const shown = run(dir, 'show', 'empty').out;
      expect(shown).toContain('in:fade out:fade  behind the video  [logo]');
      expect(shown).toContain('in:fade out:fade  order 2  [badge]');
      expect(shown).toContain('“Hello” plain in: out:  behind the video  order 1  [title]');
      expect(shown).toMatch(/“Front” plain in: out:  \[note\]/);
    } finally {
      drop(dir);
    }
  });

  test('the schema refuses an unknown layer; validate names the layers and keeps depth to texts and images', () => {
    expect(check(editsSchema, json('invalid', 'depth-problems', 'edits.json')).join('\n')).toContain('/segments/0/layer: "under" is not one of front, behind');
    const out = readFileSync(join(golden, 'validate/depth-problems.txt'), 'utf8');
    expect(out).toContain('no layer under; one of front, behind');
    expect(out).toContain('only a text or an image has a layer');
    expect(out).toContain('only a text or an image has an order');
  });
});

describe('a file that can\'t be read is never written over', () => {
  let dir = '';
  const broken = '{ "segments": [ { "id": "z", "kind": "zoom", "start": 1, "end": 2, "level": 2 }, ] ';
  beforeAll(() => {
    dir = library('valid');
    writeFileSync(join(dir, 'empty/edits.json'), broken);
    writeFileSync(join(dir, 'full/look.json'), '{ "padding": "lots" }');
  });
  afterAll(() => drop(dir));

  test('validate says why; show stops with exit 1 and shows no empty edit', () => {
    const v = run(dir, 'validate', 'empty');
    expect(v.code).toBe(1);
    expect(v.out).toStartWith('edits.json: The given data was not valid JSON.');
    const shown = run(dir, 'show', 'empty');
    expect(shown.code).toBe(1);
    expect(shown.out).toBe('');
    expect(shown.err).toContain("empty can't be read, so nothing was done; the file is left as it is.");
    const json = run(dir, 'show', 'empty', '--json');
    expect(json.code).toBe(1);
    const parsed = JSON.parse(json.out);
    expect(parsed).toMatchObject({ id: 'empty', folder: '<library>/empty' });
    expect(parsed.unreadable).toEqual([v.out.split('\n')[0]]);
    expect(run(dir, 'show', 'full').err).toStartWith('look.json: padding: Expected to decode Double but found a string instead.\n');
  });

  test('template, image, sound, mask, frame and export refuse it, and the files stay byte for byte', () => {
    const look = readFileSync(join(dir, 'full/look.json'), 'utf8');
    const fullEdits = readFileSync(join(dir, 'full/edits.json'), 'utf8');
    for (const id of ['empty', 'full']) {
      for (const args of [
        ['template', id, 'launch'],
        ['image', id, join(fixtures, 'media/logo.png')],
        ['sound', id, join(fixtures, 'media/beep.wav')],
        ['mask', id, '--rect', '0.1,0.1,0.2,0.2'],
        ['frame', id, '1', '--out', join(dir, 'frame.png')],
        ['export', id, '--out', join(dir, 'out.mp4')],
      ]) {
        const r = run(dir, ...args);
        expect(r.code).toBe(1);
        expect(r.err).toContain(`${id} can't be read, so nothing was done`);
      }
    }
    expect(readFileSync(join(dir, 'empty/edits.json'), 'utf8')).toBe(broken);
    expect(readFileSync(join(dir, 'full/look.json'), 'utf8')).toBe(look);
    expect(readFileSync(join(dir, 'full/edits.json'), 'utf8')).toBe(fullEdits);
  });
});

describe('verbs that change a recording leave it valid', () => {
  let lib = '';
  beforeAll(() => {
    lib = library('valid');
  });
  afterAll(() => drop(lib));

  const templates = ['clean', 'hero', 'before-after', 'spotlight', 'social', 'steps', 'launch'];
  const filled = (id: string) => {
    const file = join(lib, id, 'edits.json');
    const edits = JSON.parse(readFileSync(file, 'utf8'));
    for (const s of edits.segments) if (s.kind === 'text') s.text = s.text.replace(/\[[^\]]*\]/g, 'Line');
    writeFileSync(file, JSON.stringify(edits));
  };

  test('template --list matches test/golden/template/list.txt', () => {
    const r = run(lib, 'template', '--list');
    expect(r.code).toBe(0);
    expect(r.out.split('\n').filter(Boolean).map((l) => l.split(' ')[0])).toEqual(templates);
    matches('template/list.txt', r.out);
  });

  test('template: each one keeps the cuts, images and masks, flags its lines to fill, and validates once they are filled', () => {
    for (const name of templates) {
      const r = run(lib, 'template', 'full', name);
      if (name === 'launch') {
        expect(r.code).toBe(1);
        expect(r.err).toBe('Product Launch needs a video at least 10 s long. This one plays 0:09.40.\n');
        continue;
      }
      expect(r.code).toBe(0);
      expect(r.out).toMatch(/^[A-Z][^\n]* applied to full: \d+ segments, \d+ moves \(edits.json\)\n/);
      const edits = JSON.parse(readFileSync(join(lib, 'full/edits.json'), 'utf8'));
      expect(edits.segments.filter((s: any) => s.kind === 'image').map((s: any) => s.id)).toEqual(['img']);
      expect(edits.segments.filter((s: any) => s.kind === 'mask').map((s: any) => s.id).sort()).toEqual(['mask1', 'mask2']);
      expect(edits.splits).toEqual([3, 4.5, 7]);
      expect(edits.segments.filter((s: any) => s.kind === 'speed').length).toBe(1);
      const v = run(lib, 'validate', 'full');
      const unfilled = edits.segments.filter((s: any) => s.kind === 'text' && /\[[^\]]*\]/.test(s.text));
      expect(r.out.split('\n').filter((l) => l.startsWith('  to fill: ')).length).toBe(unfilled.length);
      if (unfilled.length) {
        expect(v.code).toBe(1);
        expect(v.out.split('\n').filter(Boolean).every((l) => /: unfilled “[^”]*\[/.test(l))).toBe(true);
        expect(run(lib, 'show', 'full').out).toContain('UNFILLED');
        filled('full');
      }
      expect(run(lib, 'validate', 'full').out).toBe('ok\n');
    }
    expect(run(lib, 'template', 'full', 'nope').err).toBe(`no template nope; one of ${templates.join(', ')}\n`);
  });

  test('template: every one on every frame shape and recording length validates, and show matches its golden', () => {
    const base = JSON.parse(readFileSync(join(lib, 'empty/meta.json'), 'utf8'));
    for (const seconds of [6, 12, 30, 90]) {
      for (const aspect of ['16:9', '9:16', '1:1']) {
        const id = `len${seconds}-${aspect.replace(':', 'x')}`;
        mkdirSync(join(lib, id), { recursive: true });
        const clicks = Array.from({ length: Math.floor(seconds / 4) }, (_, i) => ({ t: 1.5 + i * 4, x: 0.4, y: 0.5 }));
        writeFileSync(join(lib, id, 'meta.json'), JSON.stringify({ ...base, id, duration: seconds, clicks, created: 1600000000 + seconds }));
        for (const name of templates) {
          writeFileSync(join(lib, id, 'look.json'), JSON.stringify({ aspect, background: 'graphite' }));
          writeFileSync(join(lib, id, 'edits.json'), '{}');
          const r = run(lib, 'template', id, name);
          if (r.code === 1) {
            expect(seconds < 10 && name === 'launch').toBe(true);
            continue;
          }
          expect(r.code).toBe(0);
          filled(id);
          expect(`${name} ${id}: ${run(lib, 'validate', id).out}`).toBe(`${name} ${id}: ok\n`);
          if (seconds === 30 && aspect === '16:9') matches(`template/${name}.txt`, run(lib, 'show', id).out);
        }
        drop(join(lib, id));
      }
    }
  }, 300_000);

  test('export refuses a template line still to fill', () => {
    const file = join(lib, 'empty/edits.json');
    const before = existsSync(file) ? readFileSync(file, 'utf8') : '{}';
    expect(run(lib, 'template', 'empty', 'spotlight').code).toBe(0);
    const r = run(lib, 'export', 'empty', '--out', join(lib, 'out.mp4'));
    expect(r.code).toBe(1);
    expect(r.out).toContain(': unfilled “[Name the feature]”; write the line or delete the text');
    expect(existsSync(join(lib, 'out.mp4'))).toBe(false);
    writeFileSync(file, before);
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

describe('split cuts and joins, and the video stays the same', () => {
  let lib = '';
  beforeAll(() => {
    lib = library('valid', true);
  }, 300_000);
  afterAll(() => drop(lib));

  const frames = (id: string, times: number[]) =>
    times.map((t) => {
      const out = join(lib, `frame-${t}.png`);
      expect(run(lib, 'frame', id, String(t), '--source', '--out', out).code).toBe(0);
      return readFileSync(out).toString('base64');
    });

  test('split --all at three times renders the same frames, byte for byte', () => {
    const times = [1.2, 1.3, 1.31, 2.2, 2.7, 4.6, 5.5, 6.5, 8.7, 8.72];
    const before = frames('full', times);
    for (const t of ['1.3', '2.7', '8.7']) {
      const r = run(lib, 'split', 'full', t, '--all');
      expect(r.code).toBe(0);
      expect(r.out).toStartWith(`split all lanes of full at 0:0${t}`);
    }
    expect(run(lib, 'validate', 'full').out).toBe('ok\n');
    expect(frames('full', times)).toEqual(before);
    const edits = JSON.parse(readFileSync(join(lib, 'full/edits.json'), 'utf8'));
    expect(edits.segments.filter((s: any) => s.joinEnd).map((s: any) => s.id)).toEqual(['z1', 'sp1', 'spot', 't3', 'mask1', 'mask1-2', 'txt', 'img']);
  }, 120_000);

  test('split names one item; a move or an edge is refused with a reason', () => {
    const r = run(lib, 'split', 'joined', '5', 'i-2:p-2');
    expect(r.out).toBe('split i-2:p-2 of joined at 0:05.00 (edits.json): i-2:p-2 → i-2:p-3, joined\n');
    expect(run(lib, 'split', 'joined', '2', 't').out).toBe('split t of joined at 0:02.00 (edits.json): t → t-3, joined\n');
    expect(run(lib, 'validate', 'joined').out).toBe('ok\n');
    const edge = run(lib, 'split', 'joined', '1.05', 'z');
    expect(edge.code).toBe(1);
    expect(edge.err).toBe('Put the playhead inside it, at least 0.1 s from each end.\n');
    expect(run(lib, 'split', 'joined', '5', 'm').err).toBe('no segment, sound or image effect m in joined\n');
    expect(run(lib, 'split', 'joined', '3.5').err).toBe('The clip is already split there.\n');
  }, 30_000);
});
