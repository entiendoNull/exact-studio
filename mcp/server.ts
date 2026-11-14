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
  if (r.code) throw new Error((r.err || r.out).trim() || `no recording "${id}"`);
  return JSON.parse(r.out).folder;
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

const id = { type: 'string', description: 'A recording id, a unique start of one, or "latest".' };

const tools: { name: string; description: string; inputSchema: object; call: (a: any) => Promise<Result> }[] = [
  {
    name: 'list_recordings',
    description: 'The recordings in the library, newest first: id, kind, length and name.',
    inputSchema: { type: 'object', properties: {} },
    call: async () => outOf(await run(['list'])),
  },
  {
    name: 'show_recording',
    description: 'One recording in readable form: its length, clip parts, segments (texts, images with their own moves and effects, effects, masks with their rect, zooms, speed, 3D), sounds added over it, moves and look.',
    inputSchema: { type: 'object', properties: { id }, required: ['id'] },
    call: async (a) => outOf(await run(['show', a.id])),
  },
  {
    name: 'read_edits',
    description: 'The raw edits.json (the timeline) and look.json (the frame) of a recording. Read edit_format first to know the fields.',
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
    description: 'Replaces the texts, effects and moves with a template laid out for the recording\'s aspect. Cuts stay.',
    inputSchema: {
      type: 'object',
      properties: { id, name: { type: 'string', enum: ['launch', 'hero', 'tour', 'teaser'] } },
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
    name: 'edit_format',
    description: 'The edit file format (docs/edits.md): every field of edits.json and look.json, masks included, with examples. Read it before write_edits.',
    inputSchema: { type: 'object', properties: {} },
    call: async () => text(readFileSync(join(root, 'docs/edits.md'), 'utf8')),
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
          'Edit Exact Studio screen recordings. Loop: list_recordings → show_recording → read_edits → write_edits/write_look → render_frame to look → export_video. Read edit_format before writing. To put a picture on the video, call add_image first, then edit the segment it returns. To add music or a sound, call add_sound; it plays straight through, not cut by the video\'s cuts. To hide a secret (an API key, an email, a name), find it with render_frame raw, then call add_mask with its rect in 0–1 of that raw picture (the full recorded frame, before the crop), and check render_frame at the mask\'s start, middle and end.',
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
