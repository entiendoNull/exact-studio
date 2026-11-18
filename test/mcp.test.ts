import { afterAll, beforeAll, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { drop, library, root } from './library';

let lib = '';
let server: ReturnType<typeof Bun.spawn>;
let lines: AsyncIterator<string>;
let next = 1;

async function* split(stream: ReadableStream<Uint8Array>) {
  const decoder = new TextDecoder();
  let buffer = '';
  for await (const chunk of stream) {
    buffer += decoder.decode(chunk);
    let nl: number;
    while ((nl = buffer.indexOf('\n')) >= 0) {
      yield buffer.slice(0, nl);
      buffer = buffer.slice(nl + 1);
    }
  }
}

async function call(method: string, params: object = {}) {
  const id = next++;
  (server.stdin as any).write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  (server.stdin as any).flush();
  const { value } = await lines.next();
  const reply = JSON.parse(value);
  expect(reply.id).toBe(id);
  return reply;
}

const tool = async (name: string, args: object) => (await call('tools/call', { name, arguments: args })).result;

beforeAll(() => {
  lib = library('valid');
  server = Bun.spawn(['bun', join(root, 'mcp/server.ts')], {
    cwd: root,
    stdin: 'pipe',
    stdout: 'pipe',
    stderr: 'inherit',
    env: { ...process.env, EXACT_STUDIO_LIBRARY: lib, EXACT_STUDIO_NO_LAUNCH: '1' },
  });
  lines = split(server.stdout as ReadableStream<Uint8Array>)[Symbol.asyncIterator]();
});

afterAll(() => {
  server.kill();
  drop(lib);
});

test('initialize names the server', async () => {
  const r = await call('initialize', { protocolVersion: '2025-06-18' });
  expect(r.result.serverInfo.name).toBe('exact-studio');
  expect(r.result.capabilities).toEqual({ tools: {} });
});

test('tools/list offers every tool, each with a schema', async () => {
  const { result } = await call('tools/list');
  expect(result.tools.map((t: any) => t.name)).toEqual([
    'list_sources', 'start_recording', 'recording_status', 'stop_recording', 'list_recordings', 'show_recording',
    'read_edits', 'write_edits', 'write_look', 'validate_recording', 'render_frame', 'export_video', 'apply_template',
    'add_image', 'add_sound', 'add_mask', 'edit_format',
  ]);
  for (const t of result.tools) expect(t.inputSchema.type).toBe('object');
});

test('validate_recording and show_recording answer through the CLI', async () => {
  expect(await tool('validate_recording', { id: 'full' })).toEqual({ content: [{ type: 'text', text: 'ok' }], isError: false });
  const shown = await tool('show_recording', { id: 'old' });
  expect(shown.content[0].text).toStartWith('Before text lanes  (window, old-format)');
});

test('write_edits keeps a valid edit and refuses a clash, leaving the file as it was', async () => {
  const file = join(lib, 'empty/edits.json');
  const zoom = { id: 'z', kind: 'zoom', start: 1, end: 3, lane: 0, level: 2 };
  const saved = await tool('write_edits', { id: 'empty', edits: { segments: [zoom] } });
  expect(saved.isError).toBe(false);
  const kept = readFileSync(file, 'utf8');
  const refused = await tool('write_edits', { id: 'empty', edits: { lanes: 2, segments: [zoom, { ...zoom, id: 'y', lane: 1 }] } });
  expect(refused.isError).toBe(true);
  expect(refused.content[0].text).toContain('Two zooms can’t overlap.');
  expect(readFileSync(file, 'utf8')).toBe(kept);
});

test('an unknown tool or method is an error, not a crash', async () => {
  expect((await call('tools/call', { name: 'nope' })).error.code).toBe(-32602);
  expect((await call('nope')).error.code).toBe(-32601);
  expect((await call('ping')).result).toEqual({});
});
