import { describe, expect, test } from 'bun:test';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { root } from './library';

const doc = readFileSync(join(root, 'docs/effects.md'), 'utf8');
const swift = (file: string) => readFileSync(join(root, 'modules/apple', file), 'utf8');
const compositor = swift('Compositor.swift'), editor = swift('Editor.swift');
const schema = JSON.parse(readFileSync(join(root, 'schema/edits.schema.json'), 'utf8'));
const segment = schema.properties.segments.items.properties;

function list(source: string, name: string): string[] {
  const m = new RegExp(`static let ${name} = \\[([^\\]]*)\\]`).exec(source);
  if (!m) throw new Error(`no static let ${name}`);
  return [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]);
}

function described(field: string, kind: string): string[] {
  const m = new RegExp(`${kind}: ([a-z, ()]+?)(;|$)`).exec(segment[field].description);
  if (!m) throw new Error(`the schema's ${field} does not list ${kind}`);
  return m[1].replace(/\([^)]*\)/g, '').split(',').map((s) => s.trim());
}

type Entries = { names: Set<string>; subs: Map<string, Set<string>> };

function sections(): Map<string, Entries> {
  const out = new Map<string, Entries>();
  let section: Entries | undefined, sub: Set<string> | undefined;
  for (const line of doc.split('\n')) {
    const h2 = /^## (.+)$/.exec(line);
    if (h2) {
      section = { names: new Set(), subs: new Map() };
      out.set(h2[1].trim(), section);
      sub = undefined;
      continue;
    }
    if (!section) continue;
    const h3 = /^### `([^`]+)`/.exec(line);
    if (h3) {
      section.names.add(h3[1]);
      sub = new Set();
      section.subs.set(h3[1], sub);
      continue;
    }
    const h4 = /^#### `([^`]+)`/.exec(line);
    if (h4) {
      sub?.add(h4[1]);
      continue;
    }
    const row = /^\| `([^`]+)` \|/.exec(line);
    if (row) section.names.add(row[1]);
  }
  return out;
}

const shown = sections();
const missing = (names: string[], have: Set<string> | undefined) => names.filter((n) => n !== 'none' && !have?.has(n));
const entries = (title: string) => shown.get(title)?.names;
const subEntries = (title: string, name: string) => shown.get(title)?.subs.get(name);

describe('docs/effects.md has an entry for every name the code accepts', () => {
  const kinds = [...list(compositor, 'kinds'), ...list(compositor, 'visual')].filter((k) => k !== 'text' && k !== 'image');
  const cases: [string, string[], Set<string> | undefined][] = [
    ['effects on the video (Segment.kinds)', kinds, entries('Effects on the video')],
    ['3D turn styles (schema)', described('style', '3d'), subEntries('Effects on the video', '3d')],
    ['mask styles (Segment.maskStyles)', list(compositor, 'maskStyles'), subEntries('Effects on the video', 'mask')],
    ['reaches (schema scope)', segment.scope.enum, entries('Whole-frame reach')],
    ['transitions (schema)', schema.properties.transitions.additionalProperties.enum, entries('Transitions')],
    ['move styles (schema, video and image)', [...schema.properties.moves.items.properties.style.enum, ...segment.moves.items.properties.style.enum], entries('Move styles')],
    ['3D edges (schema)', schema.properties.three.properties.edge.enum, entries('3D edges')],
    ['text entrances (Editor.textIns)', [...list(editor, 'textIns'), ...segment.animIn.enum], entries('Text entrances')],
    ['text exits (Editor.textOuts)', [...list(editor, 'textOuts'), ...segment.animOut.enum], entries('Text exits')],
    ['text loops (Editor.loops)', [...list(editor, 'loops'), ...segment.loop.enum], entries('Text loops')],
    ['text styles (schema)', described('style', 'text'), entries('Text styles')],
    ['text weights (schema)', segment.weight.enum, entries('Text weights')],
    ['text colours (schema)', segment.color.anyOf[0].enum, entries('Text colours')],
    ['image entrances (Editor.imageIns)', list(editor, 'imageIns'), entries('Image entrances')],
    ['image exits (Editor.imageOuts)', list(editor, 'imageOuts'), entries('Image exits')],
    ['image effects (Segment.imageEffects)', [...list(compositor, 'imageEffects'), ...segment.effects.items.properties.kind.enum], entries('Image effects')],
    ['text effects (Segment.textEffects)', list(compositor, 'textEffects'), entries('Text effects')],
  ];
  for (const [what, names, have] of cases) {
    test(what, () => {
      expect(names.length).toBeGreaterThan(0);
      expect(missing(names, have)).toEqual([]);
    });
  }
});

describe('the picture strips', () => {
  const dir = join(root, 'docs/effects');
  const linked = [...doc.matchAll(/\]\(effects\/([^)]+)\)/g)].map((m) => m[1]);
  const files = readdirSync(dir).filter((f) => f.endsWith('.png'));

  test('every strip the doc links exists', () => {
    expect(linked.filter((f) => !existsSync(join(dir, f)))).toEqual([]);
  });
  test('every strip in docs/effects is linked', () => {
    expect(files.filter((f) => !linked.includes(f))).toEqual([]);
  });
  test('together they stay under 3 MB', () => {
    expect(files.reduce((n, f) => n + statSync(join(dir, f)).size, 0)).toBeLessThan(3_000_000);
  });
});
