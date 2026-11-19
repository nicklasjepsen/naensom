import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { z } from "zod";

import {
  DOSE_ADVICE_ALLOW_LIST,
  DOSING_WORDS,
  SUGGESTION_WORDS,
  UNIT_AMOUNT,
  findDoseAdvice,
  findDosingVocabulary,
  findPumpFieldsInAiInput,
  findSuggestionVocabulary,
  findUnitAmounts,
  messageStrings,
  schemaVocabulary,
} from "./dosing-vocabulary";
import * as aiSchemas from "./schemas/ai";
import * as schemas from "./schemas/index";

const messagesDir = path.resolve(import.meta.dirname, "../../web/messages");
const pushMessagesDir = path.resolve(import.meta.dirname, "push/messages");
const pumpMessagesDir = path.resolve(import.meta.dirname, "pump/messages");
const liveMessagesDir = path.resolve(import.meta.dirname, "live/messages");
const iosPagesMessagesDir = path.resolve(
  import.meta.dirname,
  "../../web/src/lib/ios-pages/messages",
);

/** Every `web/messages/<locale>/<ns>.json`, keyed `<locale>/<ns>.json`. */
function readUiMessages(): Record<string, unknown> {
  const files: Record<string, unknown> = {};
  for (const locale of readdirSync(messagesDir, { withFileTypes: true })) {
    if (!locale.isDirectory()) continue;
    const dir = path.join(messagesDir, locale.name);
    for (const file of readdirSync(dir).filter((f) => f.endsWith(".json"))) {
      files[`${locale.name}/${file}`] = JSON.parse(
        readFileSync(path.join(dir, file), "utf8"),
      ) as unknown;
    }
  }
  return files;
}

describe("the dosing rule: Nænsom never calculates, suggests or takes a dose", () => {
  it("has exactly the dosing words, the suggestion words and the app's own promise", () => {
    expect([...DOSING_WORDS]).toEqual([
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
    ]);
    expect([...SUGGESTION_WORDS]).toEqual([
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
    ]);
    expect([...DOSE_ADVICE_ALLOW_LIST]).toEqual([
      "regner aldrig insulin",
      "Nænsom · åben kildekode · regner aldrig insulin",
      "Nænsom er åben kildekode, regner aldrig insulin og erstatter ikke din sensor-app eller pumpe-app.",
      "never calculates insulin",
      "Nænsom · open source · never calculates insulin",
      "Nænsom is open source, never calculates insulin and does not replace your sensor app or pump app.",
    ]);
  });

  it("flags a listed word, word-bounded and case-insensitive", () => {
    expect(findDosingVocabulary([["da.json:x", "ordene enheder insulin"]])).toEqual([
      { where: "da.json:x", text: "ordene enheder insulin", term: "insulin" },
      { where: "da.json:x", text: "ordene enheder insulin", term: "enheder insulin" },
    ]);
    expect(findDosingVocabulary([["k", "Insulin"]])).toHaveLength(1);
    expect(findDosingVocabulary([["k", "Din ICR er 10"]]).map((f) => f.term)).toEqual(["ICR"]);
    expect(findDosingVocabulary([["k", "Korrektion"]]).map((f) => f.term)).toEqual(["korrektion"]);
    expect(findDosingVocabulary([["k", "the ratio"]]).map((f) => f.term)).toEqual(["ratio"]);
    expect(findDosingVocabulary([["k", "dose it"]]).map((f) => f.term)).toEqual(["dose"]);
  });

  it("does not flag the bare words units and enheder, or words that only contain a listed one", () => {
    expect(
      findDosingVocabulary([
        ["k", "Enheder"],
        ["k", "Glucose unit"],
      ]),
    ).toEqual([]);
    // "2 units" is not a dosing word; it is a unit amount.
    expect(findDosingVocabulary([["k", "2 units"]])).toEqual([]);
    expect(findUnitAmounts([["k", "2 units"]])).toEqual([
      { where: "k", text: "2 units", amount: "2 units" },
    ]);
    expect(
      findDosingVocabulary([
        ["k", "insulinpumpe"],
        ["k", "rationel"],
        ["k", "pied"],
      ]),
    ).toEqual([]);
  });

  it("lets nothing through: a dosing word is found wherever it is looked for", () => {
    // Until 2026-11-19 an allow-list let some copy pass. What is looked at now is AI only.
    for (const text of ["Bolus 12:30", "Bolus", "Bolus før måltid", ...DOSE_ADVICE_ALLOW_LIST])
      expect(findDosingVocabulary([["k", text]]), text).not.toEqual([]);
  });

  it("walks every exported Zod schema's keys and enum values", () => {
    const vocabulary = schemaVocabulary(schemas);
    // Each schema is walked once, under the first export that reaches it.
    expect(vocabulary.some(([where, text]) => text === "mmol" && where.endsWith(".mmol"))).toBe(
      true,
    );
    expect(vocabulary.map(([, text]) => text)).toContain("tokenHash");
    expect(vocabulary.map(([, text]) => text)).toContain("double-up");
    // No AI schema names insulin in a key or an enum value: a model is neither given such a
    // figure nor asked for one.
    const ai = schemaVocabulary(aiSchemas);
    expect(ai.map(([, text]) => text)).toContain("totalCarbs");
    expect(findDosingVocabulary(ai)).toEqual([]);
  });

  it("reads every string in web/messages/<locale>/*.json", () => {
    const strings = messageStrings({ "da/a.json": { b: "Hej", c: ["x", "y"] } });
    expect(strings).toEqual([
      ["da/a.json:b", "Hej"],
      ["da/a.json:c.0", "x"],
      ["da/a.json:c.1", "y"],
    ]);
  });

  it("pairs no insulin figure with advice in the push copy, both locales", () => {
    const files: Record<string, unknown> = {};
    for (const file of readdirSync(pushMessagesDir).filter((f) => f.endsWith(".json"))) {
      files[`push/${file}`] = JSON.parse(
        readFileSync(path.join(pushMessagesDir, file), "utf8"),
      ) as unknown;
    }
    expect(Object.keys(files).sort()).toEqual(["push/da.json", "push/en.json"]);
    const strings = messageStrings(files);
    expect(strings.map(([where]) => where)).toEqual(
      expect.arrayContaining(["push/da.json:estimate.title", "push/da.json:symptom.body"]),
    );
    expect(findDoseAdvice(strings)).toEqual([]);
  });

  it("pairs no insulin figure with advice in the iPhone relay's alert copy", () => {
    const files: Record<string, unknown> = {};
    for (const file of readdirSync(liveMessagesDir).filter((f) => f.endsWith(".json"))) {
      files[`live/messages/${file}`] = JSON.parse(
        readFileSync(path.join(liveMessagesDir, file), "utf8"),
      ) as unknown;
    }
    expect(Object.keys(files).sort()).toEqual(["live/messages/da.json", "live/messages/en.json"]);
    const strings = messageStrings(files);
    expect(strings.map(([where]) => where)).toContain("live/messages/da.json:alert.low");
    expect(findDoseAdvice(strings)).toEqual([]);
  });

  it("pairs no insulin figure with advice on the iPhone app's web pages", () => {
    const files: Record<string, unknown> = {};
    for (const file of readdirSync(iosPagesMessagesDir).filter((f) => f.endsWith(".json"))) {
      files[`ios-pages/messages/${file}`] = JSON.parse(
        readFileSync(path.join(iosPagesMessagesDir, file), "utf8"),
      ) as unknown;
    }
    expect(Object.keys(files).sort()).toEqual([
      "ios-pages/messages/da.json",
      "ios-pages/messages/en.json",
    ]);
    const strings = messageStrings(files);
    expect(strings.map(([where]) => where)).toContain("ios-pages/messages/da.json:follow.title");
    expect(findDoseAdvice(strings)).toEqual([]);
  });

  it("pairs no insulin figure with advice in any UI string, the pump's copy included", () => {
    const files = readUiMessages();
    // Both locales are read, namespace by namespace; an empty walk would pass vacuously.
    expect(Object.keys(files)).toEqual(
      expect.arrayContaining(["da/app.json", "en/app.json", "da/pump.json", "en/pumpMeal.json"]),
    );
    const strings = messageStrings(files);
    expect(strings.length).toBeGreaterThan(100);
    // The copy does show what the pump reported, so the check has something to look at.
    expect(findUnitAmounts(strings).length + findDosingVocabulary(strings).length).toBeGreaterThan(0);
    expect(findDoseAdvice(strings)).toEqual([]);
  });

  it("pairs no insulin figure with advice in shared/src/pump/messages, with key parity", () => {
    const files: Record<string, unknown> = {};
    for (const file of readdirSync(pumpMessagesDir).filter((f) => f.endsWith(".json"))) {
      files[`pump/messages/${file}`] = JSON.parse(
        readFileSync(path.join(pumpMessagesDir, file), "utf8"),
      ) as unknown;
    }
    expect(Object.keys(files).sort()).toEqual(["pump/messages/da.json", "pump/messages/en.json"]);
    const strings = messageStrings(files);
    expect(strings.map(([where]) => where)).toContain("pump/messages/da.json:meal.item");
    expect(findDoseAdvice(strings)).toEqual([]);
    const keys = (file: string) =>
      strings
        .filter(([where]) => where.startsWith(`${file}:`))
        .map(([where]) => where.split(":")[1]);
    expect(keys("pump/messages/da.json")).toEqual(keys("pump/messages/en.json"));
    expect(keys("pump/messages/da.json").length).toBeGreaterThan(0);
  });

  it("lets copy show what the pump reports and nothing that advises about it", () => {
    const copy = (text: string): [string, string] => ["da/any.json:k", text];
    for (const text of [
      "Automatisk bolus 03:10 · 0,6 E",
      "Bolus 11:58 · 2,4 E",
      "Insulin i kroppen",
      "Insulin tilbage: {units} E",
      "Korrektion 1 E",
      "Pumpe til 11:58",
      // A suggestion word about something else is not advice about insulin.
      "Tag et billede",
      "Næste gang du logger et måltid",
      ...DOSE_ADVICE_ALLOW_LIST,
    ])
      expect(findDoseAdvice([copy(text)]), text).toEqual([]);
    expect(findDoseAdvice([copy("Du bør give 2 E")])).toEqual([
      { where: "da/any.json:k", text: "Du bør give 2 E", term: "bør", about: "2 E" },
      { where: "da/any.json:k", text: "Du bør give 2 E", term: "give", about: "2 E" },
    ]);
    expect(findDoseAdvice([copy("Beregnet bolus")]).map((f) => [f.term, f.about])).toEqual([
      ["beregn*", "bolus"],
    ]);
    for (const text of [
      "Tag 2 E næste gang",
      "We suggest 2 U",
      "You should take more insulin",
      "Anbefalet dosis",
      "Nænsom regner aldrig insulin, men du bør tage 2 E",
    ])
      expect(findDoseAdvice([copy(text)]), text).not.toEqual([]);
  });

  it("recognises an amount of insulin and nothing that only looks like one", () => {
    const other = (text: string): [string, string] => ["da/chart.json:k", text];
    expect(findUnitAmounts([other("Bolus 2,4 E")]).map((f) => f.amount)).toEqual(["2,4 E"]);
    expect(findUnitAmounts([other("giv 2 enheder")]).map((f) => f.amount)).toEqual(["2 enheder"]);
    expect(findUnitAmounts([other("{count} enheder")]).map((f) => f.amount)).toEqual([
      "{count} enheder",
    ]);
    expect(findUnitAmounts([other("1.5 U"), other("3 IE"), other("# units")])).toHaveLength(3);
    // A number next to something else, or a device count, is not an amount of insulin.
    expect(
      findUnitAmounts([
        other("ca. {carbs} g"),
        other("6,2 mmol/L"),
        other("{count, plural, one {# enhed} other {# enheder}}"),
        other("{count, plural, one {# device} other {# devices}}"),
        other("Enheder"),
        other("Vitamin E"),
        other("2 eksempler"),
      ]),
    ).toEqual([]);
  });

  it("fails on a suggestion word in any schema key or enum value, and finds none today", () => {
    expect(findSuggestionVocabulary(schemaVocabulary(schemas))).toEqual([]);
    const bad = {
      Bad: z.strictObject({ suggestedUnits: z.number(), kind: z.enum(["take", "ok"]) }),
    };
    expect(findSuggestionVocabulary(schemaVocabulary(bad)).map((f) => [f.text, f.term])).toEqual([
      ["suggestedUnits", "suggest*"],
      ["take", "take"],
    ]);
    expect(
      findSuggestionVocabulary([
        ["k", "anbefalet"],
        ["k", "Beregn"],
        ["k", "tag"],
        ["k", "tags"],
      ]).map((f) => f.text),
    ).toEqual(["anbefalet", "Beregn", "tag"]);
  });

  it("keeps the pump record out of every AI input (spec §5)", () => {
    const { InsightInput, WeekInsightInput } = schemas;
    expect(findPumpFieldsInAiInput(schemaVocabulary({ InsightInput, WeekInsightInput }))).toEqual(
      [],
    );
    for (const extra of [
      { bolusUnits: z.number() },
      { units: z.number() },
      { pumpCarbs: z.number() },
      { pumpBolusId: z.string() },
      { pump: z.strictObject({ carbs: z.number() }) },
    ]) {
      const [key] = Object.keys(extra);
      expect(
        findPumpFieldsInAiInput(schemaVocabulary({ InsightInput: InsightInput.extend(extra) })),
        key,
      ).not.toEqual([]);
      expect(
        findPumpFieldsInAiInput(
          schemaVocabulary({ WeekInsightInput: WeekInsightInput.extend(extra) }),
        ),
        key,
      ).not.toEqual([]);
    }
  });

  it("rejects bolus and a unit amount in a model answer, whatever copy may show", async () => {
    const { assertNoDosing } = await import("./ai/guard");
    for (const text of ["Bolus 11:58", "bolus", "2 units", "Automatisk bolus 03:10 · 0,6 E", "2 E"])
      expect(() => {
        assertNoDosing(text, "da/pump.json:k");
      }, text).toThrow();
    expect(() => {
      assertNoDosing("Toppen kom efter en time.", "k");
    }).not.toThrow();
  });
});

it("dosing guard covers every AI prompt and accepted insight fixture", async () => {
  const { assertNoDosing } = await import("./ai/guard");
  const { MealInsight, WeekInsight } = await import("./schemas/ai");
  const aiDir = path.join(import.meta.dirname, "ai");
  const prompts = readdirSync(aiDir, { recursive: true })
    .map(String)
    .filter((file) => /^prompt.*\.ts$/.test(path.basename(file)) && !file.endsWith(".test.ts"))
    .sort();
  const walked: string[] = [];
  const walk = (dir: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const file = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(file);
      else if (/^prompt.*\.ts$/.test(entry.name) && !entry.name.endsWith(".test.ts")) {
        walked.push(path.relative(aiDir, file));
        const text = readFileSync(file, "utf8");
        assertNoDosing(text, file);
        expect(UNIT_AMOUNT.test(text), file).toBe(false);
      }
    }
  };
  walk(aiDir);
  expect(walked.sort()).toEqual(prompts);
  const fixtures = path.resolve(import.meta.dirname, "../../fixtures/ai/insight");
  const files = readdirSync(fixtures).filter((file) => file.endsWith(".json"));
  expect(files).toEqual(expect.arrayContaining(["meal-da.json", "week-en.json"]));
  for (const file of files) {
    const value = JSON.parse(readFileSync(path.join(fixtures, file), "utf8")) as unknown;
    expect(MealInsight.safeParse(value).success || WeekInsight.safeParse(value).success).toBe(true);
    for (const [where, text] of messageStrings({ [file]: value })) {
      assertNoDosing(text, where);
      expect(UNIT_AMOUNT.test(text), where).toBe(false);
    }
  }
});
