type Schema = Record<string, any>;

const typeOf = (v: unknown) => (v === null ? 'null' : Array.isArray(v) ? 'array' : Number.isInteger(v) ? 'integer' : typeof v);
const fits = (v: unknown, t: string) => typeOf(v) === t || (t === 'number' && typeOf(v) === 'integer');

export function check(schema: Schema, value: unknown, at = ''): string[] {
  const out: string[] = [];
  const here = at || '/';
  if (schema.type) {
    const types: string[] = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.some((t) => fits(value, t))) return [`${here}: ${JSON.stringify(value)} is not ${types.join(' or ')}`];
  }
  if (schema.enum && !schema.enum.some((e: unknown) => e === value)) out.push(`${here}: ${JSON.stringify(value)} is not one of ${schema.enum.join(', ')}`);
  if ('const' in schema && schema.const !== value) out.push(`${here}: is not ${JSON.stringify(schema.const)}`);
  if (typeof value === 'number') {
    if (schema.minimum !== undefined && value < schema.minimum) out.push(`${here}: ${value} is below ${schema.minimum}`);
    if (schema.maximum !== undefined && value > schema.maximum) out.push(`${here}: ${value} is above ${schema.maximum}`);
    if (schema.exclusiveMinimum !== undefined && value <= schema.exclusiveMinimum) out.push(`${here}: ${value} is not above ${schema.exclusiveMinimum}`);
  }
  if (typeof value === 'string' && schema.pattern && !new RegExp(schema.pattern, 'u').test(value)) out.push(`${here}: ${value} does not match ${schema.pattern}`);
  if (Array.isArray(value) && schema.items) value.forEach((v, i) => out.push(...check(schema.items, v, `${at}/${i}`)));
  if (typeOf(value) === 'object') {
    const obj = value as Record<string, unknown>;
    for (const k of schema.required ?? []) if (!(k in obj)) out.push(`${here}: missing ${k}`);
    for (const [k, v] of Object.entries(obj)) {
      if (schema.properties?.[k]) out.push(...check(schema.properties[k], v, `${at}/${k}`));
      else if (schema.additionalProperties === false) out.push(`${here}: ${k} is not allowed`);
      else if (typeof schema.additionalProperties === 'object') out.push(...check(schema.additionalProperties, v, `${at}/${k}`));
    }
  }
  for (const s of schema.allOf ?? []) out.push(...check(s, value, at));
  if (schema.anyOf && !schema.anyOf.some((s: Schema) => check(s, value, at).length === 0)) out.push(`${here}: matches none of its forms`);
  if (schema.if && check(schema.if, value, at).length === 0 && schema.then) out.push(...check(schema.then, value, at));
  return out;
}
