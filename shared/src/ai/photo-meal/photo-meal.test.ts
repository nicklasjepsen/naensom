import { describe, expect, it } from "vitest";
import type { LookupResponse } from "../../schemas/food";
import { PhotoReading } from "../../schemas/ai";
import { FakeAiProvider, defaultFakeAnswer } from "../fake";
import { photoToMeal } from "./photo-meal";

const bar = {
  name: "Example oat bar",
  origin: "off",
  sourceRef: "off:5701234567899",
  carbsPer100g: 60,
  portions: [{ label: "1 bar", grams: 30, carbs: 18 }],
};
const bread = {
  name: "Example rye bread",
  origin: "frida",
  sourceRef: "frida:1",
  carbsPer100g: 40,
  portions: [],
};
const none: LookupResponse = { results: [], sources: {}, manual: {} };
const found = (food: object): LookupResponse => ({
  results: [{ source: "cache", verified: false, food } as LookupResponse["results"][number]],
  sources: {},
  manual: {},
});
const guess = (name: string, grams: number, carbs: number) => ({
  name,
  grams,
  carbs,
  confidence: "medium" as const,
  approx: true as const,
});
const vision = (items: unknown[]) => ({ kind: "json" as const, model: "fixture", json: { items } });

describe("photo to meal", () => {
  it("looks up a legible barcode and spends no further AI call on it", async () => {
    const fake = new FakeAiProvider([
      vision([
        {
          query: "Example oat bar",
          kind: "product",
          barcode: "5701234567899",
          estimate: guess("Oat bar", 30, 20),
        },
      ]),
    ]);
    const barcodes: string[] = [];
    const { meal, count } = await photoToMeal(fake, "AQID", "en", {
      text: () => Promise.reject(Error("not used")),
      barcode: (code) => {
        barcodes.push(code);
        return Promise.resolve(found(bar));
      },
    });
    expect(barcodes).toEqual(["5701234567899"]);
    expect(fake.calls).toHaveLength(1);
    expect(count).toBe(0);
    expect(meal.items).toEqual([
      { query: "Example oat bar", match: { source: "cache", food: bar, grams: 30 } },
    ]);
  });

  it("ignores a barcode that fails its checksum and matches by name instead", async () => {
    const fake = new FakeAiProvider([
      vision([
        {
          query: "Example rye bread",
          kind: "product",
          barcode: "5701234567891",
          estimate: guess("Rye bread", 50, 21),
        },
      ]),
      {
        kind: "tool-calls",
        model: "fixture",
        calls: [{ id: "1", name: "lookup", input: { query: "Example rye bread" } }],
      },
      {
        kind: "json",
        model: "fixture",
        json: {
          items: [
            {
              query: "Example rye bread",
              match: { source: "cache", foodRef: "frida:1", grams: 50 },
            },
          ],
          unmatched: [],
        },
      },
    ]);
    const { meal } = await photoToMeal(fake, "AQID", "en", {
      text: () => Promise.resolve(found(bread)),
      barcode: () => Promise.reject(Error("a bad checksum never reaches lookup")),
    });
    expect(meal.items).toEqual([
      { query: "Example rye bread", match: { source: "cache", food: bread, grams: 50 } },
    ]);
    expect(fake.calls[1]).toHaveProperty(
      "request.messages.0.content.0.text",
      "Example rye bread, 50 g",
    );
  });

  it("keeps the vision guess, marked approx, only for what lookup did not find", async () => {
    const fake = new FakeAiProvider([
      vision([{ query: "Example stew", kind: "dish", estimate: guess("Stew", 250, 35) }]),
      {
        kind: "tool-calls",
        model: "fixture",
        calls: [{ id: "1", name: "lookup", input: { query: "Example stew" } }],
      },
      {
        kind: "json",
        model: "fixture",
        json: {
          items: [{ query: "Example stew", estimate: guess("Stew from text", 250, 20) }],
          unmatched: [],
        },
      },
    ]);
    const { meal } = await photoToMeal(fake, "AQID", "en", {
      text: () => Promise.resolve(none),
      barcode: () => Promise.resolve(none),
    });
    expect(meal.items).toEqual([{ query: "Example stew", estimate: guess("Stew", 250, 35) }]);
  });

  it("rejects a reading that is not the schema and works with the fake provider", async () => {
    await expect(
      photoToMeal(new FakeAiProvider([vision([])]), "AQID", "en", {
        text: () => Promise.resolve(none),
        barcode: () => Promise.resolve(none),
      }),
    ).rejects.toMatchObject({ code: "ai-rejected" });
    const { meal } = await photoToMeal(new FakeAiProvider(defaultFakeAnswer), "AQID", "en", {
      text: () => Promise.resolve(none),
      barcode: () => Promise.resolve(none),
    });
    expect(meal.items).toHaveLength(1);
    expect(PhotoReading.safeParse(defaultFakeAnswer).success).toBe(false);
  });
});
