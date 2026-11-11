// Exact Studio's data: every answer is the native module's (modules/apple/).
// The web has no module, so each source answers empty there.
import type { Answer, Result, Sources } from './app.contract.d.ts';

export const grants = '';

type Native = Parameters<Answer>[4];
const later = async <T>(native: Native, request: Record<string, unknown>, fallback: T): Promise<T> =>
  native?.available ? ((await native.later(request)) as T) : fallback;

const sources: Sources = {
  recorderStatus: async (_args, _store, _storage, native): Promise<Result<'recorderStatus'>> => {
    if (!native?.available) return { recording: false, name: '', kind: '' };
    native.watch('status');
    return native.call({ op: 'status' }) as Result<'recorderStatus'>;
  },
  captureSources: (_args, _store, _storage, native) =>
    later(native, { op: 'sources' }, { items: [], allowed: false }),
  recordings: async (_args, _store, _storage, native) => {
    native?.watch('recordings');
    return later(native, { op: 'recordings' }, { items: [] });
  },
  startRecording: ([source], _store, _storage, native) =>
    later(native, { op: 'start', source }, { ok: false, error: 'Recording needs the Mac app.' }),
  stopRecording: (_args, _store, _storage, native) =>
    later(native, { op: 'stop' }, { ok: false, error: 'Not recording.', id: '' }),
  exportRecording: ([id, look], _store, _storage, native) =>
    later(native, { op: 'export', id, look }, { ok: false, error: 'Export needs the Mac app.', path: '' }),
  deleteRecording: ([id], _store, _storage, native) =>
    later(native, { op: 'delete', id }, { ok: false, error: '' }),
  revealFile: ([path], _store, _storage, native) => later(native, { op: 'reveal', path }, { ok: false }),
  nudgeCrop: ([id, edge, by], _store, _storage, native) => later(native, { op: 'crop', id, edge, by }, { ok: false }),
};
export const answer: Answer = (source, args, store, storage, native) =>
  sources[source](args, store, storage, native);
