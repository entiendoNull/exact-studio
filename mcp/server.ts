#!/usr/bin/env bun
// exact-studio MCP server: the CLI's verbs (and the two edit files) as MCP tools,
// so an agent can list, read, change, check, look at and export recordings.
// Plain JSON-RPC over stdio, one message per line; no dependencies.
// Everything goes through ./exact-studio, so the app's own renderer draws every frame.
import { readFileSync, writeFileSync, existsSync, mkdtempSync, unlinkSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';

const root = dirname(import.meta.dir);
const cli = join(root, 'exact-studio');

type Content = { type: 'text'; text: string } | { type: 'image'; data: string; mimeType: string };
type Result = { content: Content[]; isError?: boolean };

async function run(args: string[]): Promise<{ code: number; out: string; err: string }> {
  const p = Bun.spawn([cli, ...args], { cwd: root, stdout: 'pipe', stderr: 'pipe' });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  return { code, out, err };
}

const text = (t: string, isError = false): Result => ({ content: [{ type: 'text', text: t }], isError });
const outOf = (r: { code: number; out: string; err: string }) =>
  text((r.out + (r.code ? r.err : '')).trim() || (r.code ? `failed (exit ${r.code})` : 'ok'), r.code !== 0);

/** The recording's folder, from the CLI (so "latest" and unique prefixes work the same). */
async function folder(id: string): Promise<string> {
  const r = await run(['show', id, '--json']);
  const shown = (() => {
    try {
      return JSON.parse(r.out);
    } catch {
      return null;
    }
  })();
  if (!shown?.folder) throw new Error((r.err || r.out).trim() || `no recording "${id}"`);
  return shown.folder;
}

/** Pretty-printed with sorted keys, as the app writes them, so diffs stay readable. */
function stable(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(stable);
  if (v && typeof v === 'object')
    return Object.fromEntries(Object.keys(v).sort().map((k) => [k, stable((v as Record<string, unknown>)[k])]));
  return v;
}

/** Writes edits.json or look.json, checks it with the CLI, and puts the old file back if it fails. */
async function writeChecked(id: string, file: string, value: unknown): Promise<Result> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return text(`${file} must be a JSON object.`, true);
  const path = join(await folder(id), file);
  const old = existsSync(path) ? readFileSync(path) : null;
  writeFileSync(path, JSON.stringify(stable(value), null, 2) + '\n');
  const r = await run(['validate', id]);
  if (r.code) {
    if (old) writeFileSync(path, old);
    else unlinkSync(path);
    return text(`Not saved; ${file} is unchanged. Problems:\n${(r.out + r.err).trim()}`, true);
  }
  return text(`Saved ${file}. The app's open preview updates within a second.`);
}

/** The entries of docs/effects.md named `name` (a heading `name`, or a table row of it), each under its section's title. */
function effectEntries(name: string): { text: string; pictures: string[] } {
  const lines = readFileSync(join(root, 'docs/effects.md'), 'utf8').split('\n');
  const want = name.trim().toLowerCase();
  const level = (l: string) => /^(#+) /.exec(l)?.[1].length ?? 0;
  const out: string[] = [];
  let section = '', sectionAt = 0;
  for (let i = 0; i < lines.length; i++) {
    const n = level(lines[i]);
    if (n === 2) { section = lines[i].slice(3); sectionAt = i; }
    const head = /^#{3,4} `([^`]+)`/.exec(lines[i]);
    const row = /^\| `([^`]+)` \|/.exec(lines[i]);
    if (head && head[1].toLowerCase() === want) {
      let j = i + 1;
      while (j < lines.length && !(level(lines[j]) && level(lines[j]) <= n)) j++;
      out.push(`${section}:\n${lines.slice(i, j).join('\n').trim()}`);
    } else if (row && row[1].toLowerCase() === want) {
      let j = sectionAt + 1;
      while (j < lines.length && level(lines[j]) !== 2) j++;
      out.push(lines.slice(sectionAt, j).join('\n').trim());
    }
  }
  const text = out.join('\n\n');
  return { text, pictures: [...text.matchAll(/\]\(effects\/([^)]+\.png)\)/g)].map((m) => join(root, 'docs/effects', m[1])) };
}

const id = { type: 'string', description: 'A recording id, a unique start of one, or "latest".' };

/** A record verb's answer: what it printed, its warnings, and what to do about a refusal by its exit code. */
// @ref LLP 0007#exit-codes
// The CLI's own hints name its verbs; here they are replaced by `then`, which names the tools.
const recordOut = (r: { code: number; out: string; err: string }, then = ''): Result => {
  const out = r.out.split('\n').filter((l) => !/^(next: |Everything on that source is recorded\.)/.test(l)).join('\n');
  const said = [out.trim(), r.err.trim()].filter(Boolean).join('\n');
  const next: Record<number, string> = {
    3: 'A person must act before anything can be recorded. Tell them; do not retry until they have.',
    4: 'Exact Studio could not be reached. After a timeout, call recording_status before you try again, so you never start a second recording.',
  };
  return text([said || (r.code ? `failed (exit ${r.code})` : 'ok'), r.code ? next[r.code] : then].filter(Boolean).join('\n\n'), r.code !== 0);
};

const tools: { name: string; description: string; inputSchema: object; call: (a: any) => Promise<Result> }[] = [
  {
    name: 'list_sources',
    description:
      'Step 1 of recording. What can be recorded now, one per line: displays (display:1, display:2), Simulators and Android emulators (simulator:<device name>, as the app\'s sidebar lists them) and other apps\' windows (window:<App — Title>, or window:#<number> when two share a name). The first word of each line is the name start_recording takes. Opens Exact Studio when it is not running. Prefer a Simulator or one window over a display: everything on the source is recorded, notifications and secrets included.',
    inputSchema: { type: 'object', properties: {} },
    call: async () => recordOut(await run(['sources'])),
  },
  {
    name: 'start_recording',
    description:
      'Step 2 of recording. Starts recording one source at once, with no picker, in the Exact Studio app: the app shows its red mark with the time in the menu bar, as when a person records. Its own windows fade out while it records, so they never cover the source, and come back when it stops. Then drive the app or page you are recording with your other tools, and call stop_recording when done. Refused (nothing starts) when a recording is already running (it is never stopped or replaced), when the source matches nothing or more than one source (the candidates are listed: pick one and call again), or when Exact Studio lacks the Screen Recording permission (a person must allow it). Set max_seconds in case you cannot call stop_recording.',
    inputSchema: {
      type: 'object',
      properties: {
        source: {
          type: 'string',
          description:
            'A name from list_sources, such as "simulator:iPhone 17 Pro", "window:Safari — GitHub" or "display:1"; or a unique part of one, such as "iPhone 17 Pro" or "github". Or an area of a display: "area:x,y,w,h" in points from the display\'s top-left corner, optionally "@2" for display 2 (default display 1).',
        },
        sound: { type: 'boolean', description: 'Record the system\'s sound (a window\'s: its app\'s). Default: the app\'s System Sound setting.' },
        max_seconds: { type: 'number', description: 'Stops by itself after this many seconds. Recommended, so a recording never runs on when you stop early.' },
      },
      required: ['source'],
    },
    call: async (a) => {
      if (typeof a.source !== 'string' || !a.source.trim()) return text('source is required: a name from list_sources.', true);
      if (a.max_seconds !== undefined && !(typeof a.max_seconds === 'number' && a.max_seconds > 0)) return text('max_seconds is a number of seconds above 0.', true);
      return recordOut(
        await run([
          'record', 'start', a.source,
          ...(a.sound !== undefined ? ['--sound', a.sound ? 'on' : 'off'] : []),
          ...(a.max_seconds !== undefined ? ['--max', String(a.max_seconds)] : []),
        ]),
        'Everything on that source is recorded. Drive it with your other tools now, then call stop_recording.',
      );
    },
  },
  {
    name: 'recording_status',
    description:
      'Whether Exact Studio is recording now: the source, the seconds so far, who started it (an agent or the app), the id and folder; and the last recording that ended, with its id. Never opens the app.',
    inputSchema: { type: 'object', properties: {} },
    call: async () => recordOut(await run(['record', 'status'])),
  },
  {
    name: 'stop_recording',
    description:
      'Step 3 of recording. Stops the recording that start_recording began, and returns the new recording\'s id and folder. Next: show_recording with that id, validate_recording, render_frame to look at it, then edit (write_edits, add_mask to hide a secret, apply_template) and export_video. Refused when nothing is recording. A recording a person started in the app is left running unless any is true.',
    inputSchema: {
      type: 'object',
      properties: { any: { type: 'boolean', description: 'Also stop a recording a person started in the app. Only when the person asked you to.' } },
    },
    call: async (a) => {
      const r = await run(['record', 'stop', ...(a.any ? ['--any'] : [])]);
      const id = /^stopped (\S+)/m.exec(r.out)?.[1] ?? 'latest';
      return recordOut(r, `Next: show_recording with id "${id}", validate_recording, render_frame to look at it; then edit it and export_video.`);
    },
  },
  {
    name: 'list_recordings',
    description: 'The recordings in the library, newest first: id, kind, length and name.',
    inputSchema: { type: 'object', properties: {} },
    call: async () => outOf(await run(['list'])),
  },
  {
    name: 'show_recording',
    description: 'One recording in readable form: its length, clip parts, segments (texts with their own effects, images with their own moves and effects, effects with their reach, masks with their rect, zooms, speed, 3D; a text or image behind the video says so, with its order when it has one), sounds added over it, moves and look.',
    inputSchema: { type: 'object', properties: { id }, required: ['id'] },
    call: async (a) => outOf(await run(['show', a.id])),
  },
  {
    name: 'read_edits',
    description: 'The raw edits.json (the timeline) and look.json (the frame) of a recording. Read edit_format first to know the fields. It works when a file can\'t be read too (the other tools then refuse the recording and validate_recording says why), so you can repair it with write_edits or write_look.',
    inputSchema: { type: 'object', properties: { id }, required: ['id'] },
    call: async (a) => {
      const dir = await folder(a.id);
      const read = (f: string) => (existsSync(join(dir, f)) ? readFileSync(join(dir, f), 'utf8').trim() : '{}');
      return text(`edits.json:\n${read('edits.json')}\n\nlook.json:\n${read('look.json')}`);
    },
  },
  {
    name: 'write_edits',
    description: 'Replaces edits.json (the timeline) with the given object. It is checked first; if a check fails, nothing changes and the problems come back.',
    inputSchema: { type: 'object', properties: { id, edits: { type: 'object', description: 'The whole edits.json.' } }, required: ['id', 'edits'] },
    call: (a) => writeChecked(a.id, 'edits.json', a.edits),
  },
  {
    name: 'write_look',
    description: 'Replaces look.json (background, aspect, padding, corners, shadow, cursor) with the given object. Checked like write_edits.',
    inputSchema: { type: 'object', properties: { id, look: { type: 'object', description: 'The whole look.json.' } }, required: ['id', 'look'] },
    call: (a) => writeChecked(a.id, 'look.json', a.look),
  },
  {
    name: 'validate_recording',
    description: 'Checks edits.json and look.json; one line per problem.',
    inputSchema: { type: 'object', properties: { id }, required: ['id'] },
    call: async (a) => outOf(await run(['validate', a.id])),
  },
  {
    name: 'render_frame',
    description:
      'Renders one frame with the app\'s own renderer and returns it as an image. Use it to look at an edit before exporting. With raw, it returns the full recorded frame at that time instead: before the crop, at its own pixel size, with no edits. That is the picture a mask\'s rect measures: a pixel at (px, py) is x = px / width, y = py / height; the text says the size and where the crop is.',
    inputSchema: {
      type: 'object',
      properties: {
        id,
        time: { type: 'number', description: 'Seconds into the edited video (or into the raw recording with source).' },
        source: { type: 'boolean', description: 'Time is in the raw recording, before cuts and speed.' },
        raw: { type: 'boolean', description: 'Return the full recorded frame (before the crop, no edits) to measure a mask\'s rect on, not the finished frame.' },
      },
      required: ['id', 'time'],
    },
    call: async (a) => {
      const out = join(mkdtempSync(join(tmpdir(), 'exact-studio-mcp-')), 'frame.png');
      const r = await run(['frame', a.id, String(a.time), '--out', out, ...(a.source ? ['--source'] : []), ...(a.raw ? ['--raw'] : [])]);
      if (r.code || !existsSync(out)) return outOf(r);
      return { content: [{ type: 'image', data: readFileSync(out).toString('base64'), mimeType: 'image/png' }, { type: 'text', text: r.out.trim() || out }] };
    },
  },
  {
    name: 'export_video',
    description: 'Renders the finished video to an .mp4 and returns its path. Default: ~/Movies/Exact Studio/<name> <id>.mp4.',
    inputSchema: {
      type: 'object',
      properties: {
        id,
        quality: { type: 'string', enum: ['best', '1080p', '720p', 'small'] },
        out: { type: 'string', description: 'Where to write the .mp4 (an absolute path).' },
      },
      required: ['id'],
    },
    call: async (a) =>
      outOf(await run(['export', a.id, ...(a.quality ? ['--quality', a.quality] : []), ...(a.out ? ['--out', a.out] : [])])),
  },
  {
    name: 'apply_template',
    description:
      'Replaces the texts, effects, zooms and moves with a template fitted to the recording\'s length, clicks and frame. Cuts, speed changes, images, masks and sounds stay. ' +
      'clean: zooms on clicks, no text. hero: a slight 3D angle to open, then zooms. before-after: "Before" and "After" labels around the change. ' +
      'spotlight: one zoom on the key click, then one line. social: a hook line, then zooms. steps: a numbered line per step. launch: a title over a blurred opening, zooms, a closing line (10 s at least). ' +
      'A [bracketed] text is a line to fill: the result lists them, and validate_recording and export_video refuse them until they are written or deleted. Review the frames afterwards.',
    inputSchema: {
      type: 'object',
      properties: { id, name: { type: 'string', enum: ['clean', 'hero', 'before-after', 'spotlight', 'social', 'steps', 'launch'] } },
      required: ['id', 'name'],
    },
    call: async (a) => outOf(await run(['template', a.id, a.name])),
  },
  {
    name: 'add_image',
    description:
      'Puts a picture on top of the video: copies the file into the recording and adds an image segment on the first image lane free at that time (else a new one), which it returns. Then use read_edits and write_edits to set its place (x, y), size, moves and effects. This is the only way to bring a picture file into a recording.',
    inputSchema: {
      type: 'object',
      properties: {
        id,
        path: { type: 'string', description: 'The picture file (an absolute path): PNG, JPEG, HEIC, TIFF, GIF, WebP or BMP.' },
        at: { type: 'number', description: 'When it appears, in seconds of the recording. Default 0.' },
        for: { type: 'number', description: 'How long it shows, in seconds. Default 4.' },
      },
      required: ['id', 'path'],
    },
    call: async (a) =>
      outOf(await run(['image', a.id, a.path, ...(a.at !== undefined ? ['--at', String(a.at)] : []), ...(a.for !== undefined ? ['--for', String(a.for)] : [])])),
  },
  {
    name: 'add_sound',
    description:
      'Adds music or another sound over the video: copies the audio file into the recording and adds a sound, which it returns. An added sound plays straight through from its start: the video\'s cuts and speed changes do not cut it (the recorded sound, set by "volume", is the one that follows the cuts). Then use read_edits and write_edits to set its volume, fadeIn and fadeOut, or trim it with offset and length. This is the only way to bring a sound file into a recording.',
    inputSchema: {
      type: 'object',
      properties: {
        id,
        path: { type: 'string', description: 'The sound file (an absolute path): M4A, MP3, WAV, AIFF, AAC or CAF.' },
        at: { type: 'number', description: 'When it starts, in seconds of the recording. Default 0.' },
        for: { type: 'number', description: 'How many seconds of the file play. Default: all of it, or what fits before the video ends.' },
      },
      required: ['id', 'path'],
    },
    call: async (a) =>
      outOf(await run(['sound', a.id, a.path, ...(a.at !== undefined ? ['--at', String(a.at)] : []), ...(a.for !== undefined ? ['--for', String(a.for)] : [])])),
  },
  {
    name: 'add_mask',
    description:
      'Hides a part of the recording (an API key, a token, an email, a name) with a blur, big pixels or a solid box, and returns the new mask segment. rect is in 0–1 of the full recorded frame (before the crop), not of the finished frame: measure it on render_frame with raw. So a later crop never moves it off the secret, and it stays on that part of the recording when the video zooms, moves or turns in 3D. Only the part inside the crop shows. It never fades: it is at full strength from at to at + for, so start a little before the secret shows and end a little after. Then look at render_frame at its start, middle and end.',
    inputSchema: {
      type: 'object',
      properties: {
        id,
        rect: {
          type: 'object',
          description: 'What it hides, in 0–1 of the full recorded frame (before the crop), origin top-left; x + w and y + h at most 1.',
          properties: { x: { type: 'number' }, y: { type: 'number' }, w: { type: 'number' }, h: { type: 'number' } },
          required: ['x', 'y', 'w', 'h'],
        },
        at: { type: 'number', description: 'When it starts, in seconds of the recording. Default 0.' },
        for: { type: 'number', description: 'How long it lasts, in seconds. Default 4.' },
        style: { type: 'string', enum: ['blur', 'pixels', 'solid'], description: 'How it hides. Default blur.' },
        color: { type: 'string', description: 'For solid: "#RRGGBB". Default black.' },
      },
      required: ['id', 'rect'],
    },
    call: async (a) => {
      const r = a.rect ?? {};
      if (![r.x, r.y, r.w, r.h].every((v) => typeof v === 'number')) return text('rect needs numbers x, y, w and h.', true);
      return outOf(
        await run([
          'mask', a.id, '--rect', `${r.x},${r.y},${r.w},${r.h}`,
          ...(a.at !== undefined ? ['--at', String(a.at)] : []),
          ...(a.for !== undefined ? ['--for', String(a.for)] : []),
          ...(a.style ? ['--style', a.style] : []),
          ...(a.color ? ['--color', a.color] : []),
        ]),
      );
    },
  },
  {
    name: 'split',
    description:
      'Cuts at a moment of the recording, so each half can be changed, moved or removed on its own. With no item it splits the clip; with item it splits that segment (a text, zoom, effect, mask, image), sound, or an image\'s own effect ("<image id>:<effect id>"); with all it is Split All Lanes: the clip and every block under that moment. Moves are never cut. The halves are joined (joinStart and joinEnd), so the video looks and sounds exactly the same until you change one. Returns what it cut and the new ids.',
    inputSchema: {
      type: 'object',
      properties: {
        id,
        at: { type: 'number', description: 'Where to cut, in seconds of the recording.' },
        item: { type: 'string', description: 'A segment\'s or a sound\'s id, or "<image id>:<effect id>". Leave out to split the clip.' },
        all: { type: 'boolean', description: 'Split All Lanes: the clip and every block under that moment.' },
      },
      required: ['id', 'at'],
    },
    call: async (a) => {
      if (typeof a.at !== 'number') return text('at is a number of seconds of the recording.', true);
      return outOf(await run(['split', a.id, String(a.at), ...(a.all ? ['--all'] : a.item ? [a.item] : [])]));
    },
  },
  {
    name: 'edit_format',
    description: 'The edit file format (docs/edits.md): every field of edits.json and look.json, masks included, with examples. Read it before write_edits. What each effect looks like on screen is in effects_guide.',
    inputSchema: { type: 'object', properties: {} },
    call: async () => text(readFileSync(join(root, 'docs/edits.md'), 'utf8')),
  },
  {
    name: 'effects_guide',
    description:
      'What each effect, move style, text and image animation, text style and transition looks like on screen (docs/effects.md): what the viewer sees, its timing (ramps, which ends ease), its parameters and useful ranges, what it touches and its limits, and when to use or avoid it. With name (such as "orbit", "zoom", "letters-pop", "swipe", "crossfade"), only the entries of that name, with their picture strips. Read the entry before you use a thing for the first time in a session.',
    inputSchema: {
      type: 'object',
      properties: { name: { type: 'string', description: 'An effect, style, animation or transition name. Leave out for the whole reference.' } },
    },
    call: async (a) => {
      if (!a.name) return text(readFileSync(join(root, 'docs/effects.md'), 'utf8'));
      const found = effectEntries(String(a.name));
      if (!found.text) return text(`No entry named "${a.name}". Call effects_guide without a name for the whole reference.`, true);
      const pictures = found.pictures.filter(existsSync).map((p): Content => ({ type: 'image', data: readFileSync(p).toString('base64'), mimeType: 'image/png' }));
      return { content: [{ type: 'text', text: found.text }, ...pictures] };
    },
  },
  {
    name: 'directing_guide',
    description:
      'How to direct a recording into promotional material (a launch video, a demo, an ad): understand the product and the footage, find the key points, write the copy, pace the cuts, place zooms and texts with a reading-speed rule, review and hand over. Read it before editing a recording for an audience. The direct-recording skill.',
    inputSchema: { type: 'object', properties: {} },
    call: async () => text(readFileSync(join(root, '.claude/skills/direct-recording/SKILL.md'), 'utf8')),
  },
  {
    name: 'feedback_guide',
    description:
      'How to send feedback on Exact Studio (GitHub issues and pull requests on entiendoNull/exact-studio) when you hit a bug, a confusing tool or doc, or a missing feature: note it, ask the person at a natural break, never file without their yes, check for duplicates, write a report without private content. The send-feedback skill.',
    inputSchema: { type: 'object', properties: {} },
    call: async () => text(readFileSync(join(root, '.claude/skills/send-feedback/SKILL.md'), 'utf8')),
  },
];

async function handle(msg: any): Promise<unknown> {
  switch (msg.method) {
    case 'initialize':
      return {
        protocolVersion: msg.params?.protocolVersion ?? '2025-06-18',
        capabilities: { tools: {} },
        serverInfo: { name: 'exact-studio', version: '0.1.0' },
        instructions:
          'Record and edit Exact Studio screen recordings. To record without a person: list_sources → start_recording (with max_seconds) → drive the app you record with your other tools → stop_recording, which returns the new id → edit it as below. Everything on the source is recorded, so prefer a Simulator or one window, and hide any secret with add_mask. Never stop a recording you did not start. To edit, loop: list_recordings → show_recording → read_edits → write_edits/write_look → render_frame to look → export_video. Read edit_format before writing, and effects_guide with a name before you use an effect, move style, animation or transition for the first time: it says what the viewer sees, its timing and its limits. To put a picture on the video, call add_image first, then edit the segment it returns. A text or an image sits in front of the video, or behind it with layer "behind" (a logo or title revealed when the video moves away); order sets which of its kind is in front. A blur or mono reaches as far down the stack (background, behind the video, video, images, texts) as its scope says; to blur one text or one image alone, give it its own effects. To add music or a sound, call add_sound; it plays straight through, not cut by the video\'s cuts. To hide a secret (an API key, an email, a name), find it with render_frame raw, then call add_mask with its rect in 0–1 of that raw picture (the full recorded frame, before the crop), and check render_frame at the mask\'s start, middle and end. To make a recording into a promo, demo or ad for an audience, read directing_guide first: it decides what to cut, where to zoom, what the texts say and how long they stay. When Exact Studio gets in the way (a bug, a confusing tool, a missing feature), read feedback_guide: note it and ask the person before anything is sent.',
      };
    case 'ping':
      return {};
    case 'tools/list':
      return { tools: tools.map(({ call, ...t }) => t) };
    case 'tools/call': {
      const tool = tools.find((t) => t.name === msg.params?.name);
      if (!tool) throw Object.assign(new Error(`Unknown tool: ${msg.params?.name}`), { code: -32602 });
      try {
        return await tool.call(msg.params.arguments ?? {});
      } catch (e) {
        return text(String((e as Error).message ?? e), true);
      }
    }
    default:
      throw Object.assign(new Error(`Method not found: ${msg.method}`), { code: -32601 });
  }
}

const send = (m: unknown) => process.stdout.write(JSON.stringify(m) + '\n');

let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk: string) => {
  buffer += chunk;
  let nl: number;
  while ((nl = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (!line) continue;
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } });
      continue;
    }
    if (msg.id === undefined) continue; // a notification: nothing to answer
    handle(msg).then(
      (result) => send({ jsonrpc: '2.0', id: msg.id, result }),
      (e) => send({ jsonrpc: '2.0', id: msg.id, error: { code: e.code ?? -32603, message: String(e.message ?? e) } }),
    );
  }
});
