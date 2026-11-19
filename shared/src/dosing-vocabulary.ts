import { z } from "zod";

/**
 * The hard rule in test form: Nænsom never calculates, suggests or takes an insulin dose, and no AI
 * model is given insulin figures or gives any (owner, 2026-11-19; before that the rule also limited
 * where a dosing word or a unit amount could be shown).
 *
 * What is checked with these lists:
 * - AI: no listed word and no unit amount in a prompt, a generated text or an AI schema's keys, and
 *   no pump field in an AI input (`findDosingVocabulary`, `UNIT_AMOUNT`, `findPumpFieldsInAiInput`,
 *   `ai/guard.ts`). Nothing passes there: no allow-list.
 * - Copy: a string may name insulin or show an amount the pump reported, but it may not pair that
 *   with advice (`findDoseAdvice`).
 * - Schemas: no key or enum value suggests anything (`findSuggestionVocabulary`).
 *
 * The bare words `enhed`/`units` are not listed because here they mean devices and the glucose unit.
 */
export const DOSING_WORDS = [
  "insulin",
  "dosis",
  "dose",
  "dosing",
  "ratio",
  "correction",
  "korrektion",
  "ICR",
  "ISF",
  "IE",
  "IU",
  "bolus",
  "enheder insulin",
  "insulin units",
  "units of insulin",
] as const;

/**
 * The app's own promise, which names insulin next to "calculates": exactly these strings pass
 * `findDoseAdvice`, each Danish one with its English counterpart.
 */
export const DOSE_ADVICE_ALLOW_LIST = [
  "regner aldrig insulin",
  "Nænsom · åben kildekode · regner aldrig insulin",
  "Nænsom er åben kildekode, regner aldrig insulin og erstatter ikke din sensor-app eller pumpe-app.",
  "never calculates insulin",
  "Nænsom · open source · never calculates insulin",
  "Nænsom is open source, never calculates insulin and does not replace your sensor app or pump app.",
] as const;

/**
 * Words that turn a number into advice. They fail in every schema key and enum value, and in any
 * string that also names insulin or an amount of it (`findDoseAdvice`). A trailing `*` matches the
 * stem by prefix (`anbefal*` matches "anbefalet"); everything else is a whole word or phrase.
 */
export const SUGGESTION_WORDS = [
  "bør",
  "burde",
  "skal tage",
  "anbefal*",
  "foreslå*",
  "beregn*",
  "udregn*",
  "giv",
  "tag",
  "næste gang",
  "should",
  "recommend*",
  "suggest*",
  "calculat*",
  "compute*",
  "give",
  "take",
  "next time",
] as const;

/**
 * A number, an ICU `#` or a `{…}` placeholder followed by a unit word: "2 E", "{count} enheder",
 * "# units". It fails in AI prompts and generated text; in copy it is an amount of insulin, which
 * may be shown but not advised about. An ICU `# enhed`/`# enheder` is the passkey device count, so
 * `#` pairs only with the abbreviations and `units`, never with the Danish word for a device
 * (owner, 2026-10-18).
 */
export const UNIT_AMOUNT =
  /(?<![\p{L}\p{N}_])(?:(?:\p{N}+(?:[.,]\p{N}+)?|\{[^{}]*\})\s*(?:E|U|IE|IU|[Ee]nhed(?:er)?|[Uu]nits?)|#\s*(?:E|U|IE|IU|[Uu]nits?))(?![\p{L}\p{N}_])/u;

export interface DosingFinding {
  where: string;
  text: string;
  term: (typeof DOSING_WORDS)[number];
}

export interface SuggestionFinding {
  where: string;
  text: string;
  term: (typeof SUGGESTION_WORDS)[number];
}

export interface UnitAmountFinding {
  where: string;
  text: string;
  /** The amount and unit as written, "2 E". */
  amount: string;
}

/** A string that advises about insulin: a suggestion word beside a dosing word or a unit amount. */
export interface DoseAdviceFinding {
  where: string;
  text: string;
  /** The suggestion word. */
  term: (typeof SUGGESTION_WORDS)[number];
  /** What it is beside: the dosing word, or the amount as written ("2 E"). */
  about: string;
}

const escape = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
// Unicode-aware word boundaries so "insulinpumpe" and "rationel" do not match but "Insulin" does.
const wordBounded = (term: string, stem = false) =>
  new RegExp(
    `(?<![\\p{L}\\p{N}_])${escape(term)}${stem ? "\\p{L}*" : ""}(?![\\p{L}\\p{N}_])`,
    "iu",
  );
const patterns = DOSING_WORDS.map((term) => ({ term, re: wordBounded(term) }));
const suggestionPatterns = SUGGESTION_WORDS.map((term) => ({
  term,
  re: term.endsWith("*") ? wordBounded(term.slice(0, -1), true) : wordBounded(term),
}));

/**
 * Every listed term found in each `[where, text]` pair. Nothing is let through: this is what an AI
 * prompt, a generated text and an AI schema's keys are held to.
 */
export function findDosingVocabulary(
  strings: Iterable<readonly [string, string]>,
): DosingFinding[] {
  const findings: DosingFinding[] = [];
  for (const [where, text] of strings) {
    for (const { term, re } of patterns) {
      if (re.test(text)) findings.push({ where, text, term });
    }
  }
  return findings;
}

/** Every suggestion word found in each `[where, text]` pair; no allow-list applies. */
export function findSuggestionVocabulary(
  strings: Iterable<readonly [string, string]>,
): SuggestionFinding[] {
  const findings: SuggestionFinding[] = [];
  for (const [where, text] of strings) {
    for (const { term, re } of suggestionPatterns) {
      if (re.test(text)) findings.push({ where, text, term });
    }
  }
  return findings;
}

/** Every unit amount ("2 E", "{count} enheder", "# units") in each `[where, text]` pair. */
export function findUnitAmounts(strings: Iterable<readonly [string, string]>): UnitAmountFinding[] {
  const findings: UnitAmountFinding[] = [];
  for (const [where, text] of strings) {
    const match = UNIT_AMOUNT.exec(text);
    if (match) findings.push({ where, text, amount: match[0] });
  }
  return findings;
}

/**
 * Every string that pairs insulin with advice: a suggestion word in a text that also has a dosing
 * word or a unit amount ("Du bør give 2 E", "Beregnet bolus"). Showing a figure is fine ("Bolus
 * 11:58 · 2,4 E", "Insulin i kroppen"), and so is a suggestion word about something else ("Tag et
 * billede"). The app's own promise (`DOSE_ADVICE_ALLOW_LIST`) passes as a whole string.
 */
export function findDoseAdvice(strings: Iterable<readonly [string, string]>): DoseAdviceFinding[] {
  const findings: DoseAdviceFinding[] = [];
  for (const [where, text] of strings) {
    if ((DOSE_ADVICE_ALLOW_LIST as readonly string[]).includes(text)) continue;
    const about = patterns.find(({ re }) => re.test(text))?.term ?? UNIT_AMOUNT.exec(text)?.[0];
    if (about === undefined) continue;
    for (const { term, re } of suggestionPatterns) {
      if (re.test(text)) findings.push({ where, text, term, about });
    }
  }
  return findings;
}

/**
 * The keys an AI input may never carry: the pump record stays out of every model input. `units`, `bolusUnits`, `pumpCarbs`, anything starting with `pump`, and `carbs` under a
 * pump field. Walk `InsightInput` and `WeekInsightInput` with `schemaVocabulary` first.
 */
export function findPumpFieldsInAiInput(
  vocabulary: Iterable<readonly [string, string]>,
): [string, string][] {
  const out: [string, string][] = [];
  for (const [where, key] of vocabulary) {
    if (key === "units" || key === "bolusUnits" || key === "pumpCarbs" || /^pump/i.test(key))
      out.push([where, key]);
    else if (key === "carbs" && /\.pump/i.test(where)) out.push([where, key]);
  }
  return out;
}

/** Flattens `{ "da.json": { nested } }` into `[ "da.json:path.to.key", string ]` pairs. */
export function messageStrings(files: Record<string, unknown>): [string, string][] {
  const out: [string, string][] = [];
  const walk = (prefix: string, value: unknown) => {
    if (typeof value === "string") {
      out.push([prefix, value]);
    } else if (Array.isArray(value)) {
      value.forEach((item, index) => {
        walk(`${prefix}.${index}`, item);
      });
    } else if (typeof value === "object" && value !== null) {
      for (const [key, item] of Object.entries(value)) {
        walk(prefix.endsWith(":") ? `${prefix}${key}` : `${prefix}.${key}`, item);
      }
    }
  };
  for (const [file, content] of Object.entries(files)) walk(`${file}:`, content);
  return out;
}

/** Every object key and enum value reachable from each exported Zod schema in `exports`. */
export function schemaVocabulary(exports: Record<string, unknown>): [string, string][] {
  const out: [string, string][] = [];
  const seen = new Set<z.ZodType>();
  const walk = (where: string, schema: z.ZodType) => {
    if (seen.has(schema)) return;
    seen.add(schema);
    if (schema instanceof z.ZodObject) {
      for (const [key, child] of Object.entries<unknown>(schema.shape)) {
        out.push([`${where}.${key}`, key]);
        if (child instanceof z.ZodType) walk(`${where}.${key}`, child);
      }
    } else if (schema instanceof z.ZodEnum) {
      for (const value of schema.options) out.push([where, String(value)]);
    } else if (schema instanceof z.ZodLiteral) {
      for (const value of schema.values) out.push([where, String(value)]);
    } else if (schema instanceof z.ZodUnion || schema instanceof z.ZodDiscriminatedUnion) {
      const options: readonly unknown[] = schema.options;
      options.forEach((option, index) => {
        if (option instanceof z.ZodType) walk(`${where}[${index}]`, option);
      });
    } else if (schema instanceof z.ZodArray) {
      const element: unknown = schema.element;
      if (element instanceof z.ZodType) walk(`${where}[]`, element);
    } else if (
      schema instanceof z.ZodOptional ||
      schema instanceof z.ZodNullable ||
      schema instanceof z.ZodDefault
    ) {
      const inner: unknown = schema.unwrap();
      if (inner instanceof z.ZodType) walk(where, inner);
    } else if (schema instanceof z.ZodPipe) {
      const input: unknown = schema.in;
      const output: unknown = schema.out;
      if (input instanceof z.ZodType) walk(where, input);
      if (output instanceof z.ZodType) walk(where, output);
    }
  };
  for (const [name, value] of Object.entries(exports)) {
    if (value instanceof z.ZodType) walk(name, value);
    else if (typeof value === "object" && value !== null) {
      for (const [key, child] of Object.entries(value)) {
        if (child instanceof z.ZodType) walk(`${name}.${key}`, child);
      }
    }
  }
  return out;
}
