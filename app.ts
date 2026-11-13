// Exact Studio's data: every answer is the native module's (modules/apple/).
// The web has no module, so each source answers empty there.
import type { Answer, Result, Sources } from './app.contract.d.ts';

export const grants = '';

type Native = Parameters<Answer>[4];
const later = async <T>(native: Native, request: Record<string, unknown>, fallback: T): Promise<T> =>
  native?.available ? ((await native.later(request)) as T) : fallback;

const sources: Sources = {
  recorderStatus: async (_args, _store, _storage, native): Promise<Result<'recorderStatus'>> => {
    if (!native?.available) return { recording: false, name: '', kind: '', sound: true, error: '' };
    native.watch('status');
    return native.call({ op: 'status' }) as Result<'recorderStatus'>;
  },
  captureSources: (_args, _store, _storage, native) =>
    later(native, { op: 'sources' }, { items: [], allowed: false }),
  recordings: async (_args, _store, _storage, native) => {
    native?.watch('recordings');
    return later(native, { op: 'recordings' }, { items: [] });
  },
  editSelection: async ([id], _store, _storage, native): Promise<Result<'editSelection'>> => {
    if (!native?.available) return { id: '', kind: '', level: 0, rate: 0, start: 0, end: 0, startText: '', endText: '', removed: false, first: false, last: false, transition: 'cut', text: '', size: 0, color: '', weight: '', style: '', animIn: '', animOut: '', loop: '', rotation: 0, moveStyle: '', duration: 0, scale: 0, tilt: 0, turn: 0, roll: 0, hasAngles: false, scope: 'video', problem: '', file: '', opacity: 100, radius: 0, shadow: false, fx: '', volume: 100, fadeIn: 0, fadeOut: 0 };
    native.watch('edits');
    return native.call({ op: 'selection', id }) as Result<'editSelection'>;
  },
  editSummary: async ([id], _store, _storage, native): Promise<Result<'editSummary'>> => {
    if (!native?.available) return { parts: 1, removed: 0, effects: 0, lanes: 1, images: 0, moves: 0, length: 0, source: 0, playing: false, device: false, found: false, cursorDrawn: false, baseScale: 100, canUndoTemplate: false, threeOn: false, tilt: 0, turn: 0, roll: 0, angleMove: '', thickness: 5, edge: 'metal', sound: false, volume: 100, zoomed: false, wheelZoom: true };
    native.watch('edits');
    return native.call({ op: 'summary', id }) as Result<'editSummary'>;
  },
  recordingLook: async ([id], _store, _storage, native): Promise<Result<'recordingLook'>> => {
    if (!native?.available) return { background: 'ocean', aspect: '16:9', padding: 8, radius: 14, shadow: true, cursor: true, cursorSize: 150, clickEffect: true, smoothCursor: true, customA: '#6A11CB', customB: '#2575FC', customAngle: 135, customRadial: false };
    native.watch('edits');
    return native.call({ op: 'look', id }) as Result<'recordingLook'>;
  },
  editClip: ([id, what, track, number, kind], _store, _storage, native) =>
    later(native, { op: 'edit', id, do: what, track, number, kind }, { ok: false }),
  startRecording: ([source], _store, _storage, native) =>
    later(native, { op: 'start', source }, { ok: false, error: 'Recording needs the Mac app.' }),
  setSystemSound: ([on], _store, _storage, native) => later(native, { op: 'sound', on }, { ok: false }),
  stopRecording: (_args, _store, _storage, native) =>
    later(native, { op: 'stop' }, { ok: false, error: 'Not recording.', id: '' }),
  exportRecording: ([id, quality, to], _store, _storage, native) =>
    later(native, { op: 'export', id, quality, to }, { ok: false, error: 'Export needs the Mac app.', path: '', copied: false }),
  deleteRecording: ([id], _store, _storage, native) =>
    later(native, { op: 'delete', id }, { ok: false, error: '' }),
  openRecording: (_args, _store, _storage, native) =>
    later(native, { op: 'open' }, { ok: false, error: 'Opening needs the Mac app.', id: '' }),
  revealFile: ([path], _store, _storage, native) => later(native, { op: 'reveal', path }, { ok: false }),
  nudgeCrop: ([id, edge, by], _store, _storage, native) => later(native, { op: 'crop', id, edge, by }, { ok: false }),
};
export const answer: Answer = (source, args, store, storage, native) =>
  sources[source](args, store, storage, native);
