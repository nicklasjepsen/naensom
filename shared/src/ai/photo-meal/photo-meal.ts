import { HttpError } from "../../schemas/api";
import { ParsedMeal, PhotoReading, type ParsedItem } from "../../schemas/ai";
import type { LookupResponse, LookupResult } from "../../schemas/food";
import type { Locale } from "../../schemas/settings";
import { normaliseBarcode } from "../../food/barcode";
import { guardOutput } from "../guard";
import { parseMeal } from "../parse/parse";
import type { AiProvider } from "../types";
import { photoMealPrompt } from "./prompt";

export interface PhotoMealLookups {
  /** A text lookup over the library, the shared cache and the configured sources. */
  text: (query: string) => Promise<LookupResponse>;
  /** The same lookup by barcode. */
  barcode: (barcode: string) => Promise<LookupResponse>;
}

/** A matched row with an amount: the portion the model saw in grams, else the food's first portion. */
function matchFrom(query: string, row: LookupResult, grams: number | undefined): ParsedItem | null {
  const food = row.food;
  if (food.carbsPer100g != null && grams !== undefined)
    return { query, match: { source: row.source, food, grams: Math.min(5000, Math.round(grams)) } };
  const portion = food.portions[0];
  if (portion) return { query, match: { source: row.source, food, portionLabel: portion.label } };
  if (food.carbsPer100g != null) return { query, match: { source: row.source, food, grams: 100 } };
  return null;
}

/**
 * Photo to meal draft (owner, 2026-11-15). One vision call says what is in the photo; a barcode it
 * reads goes to the barcode lookup, and everything else goes through Say entry's grounded parse,
 * so carbs come from a real row wherever one is found. The vision guess is shown only for a food
 * that no lookup found, and always as approx. Nothing is logged here: the person reviews the
 * draft and saves the meal.
 */
export async function photoToMeal(
  provider: AiProvider,
  base64: string,
  locale: Locale,
  lookups: PhotoMealLookups,
  onToolCall: () => void = () => undefined,
): Promise<{ meal: ParsedMeal; count: number }> {
  const result = await provider.vision({
    role: "everyday",
    use: "estimate",
    system: photoMealPrompt(locale),
    prompt: "What food is in this photo?",
    image: { mediaType: "image/jpeg", base64 },
    outputSchema: PhotoReading,
  });
  if (result.kind !== "json") throw new HttpError(503, "ai-unavailable");
  const reading = PhotoReading.safeParse(result.json);
  if (!reading.success) throw new HttpError(422, "ai-rejected");
  guardOutput(reading.data);

  const items: ParsedItem[] = [];
  const rest: PhotoReading["items"] = [];
  for (const item of reading.data.items) {
    const code = item.barcode ? normaliseBarcode(item.barcode) : null;
    if (code) {
      const found = (await lookups.barcode(code).catch(() => null))?.results[0];
      const matched = found ? matchFrom(item.query, found, item.estimate.grams) : null;
      if (matched) {
        items.push(matched);
        continue;
      }
    }
    rest.push(item);
  }
  if (rest.length === 0) return { meal: { items, unmatched: [] }, count: 0 };

  const text = rest
    .map((item) =>
      item.estimate.grams === undefined ? item.query : `${item.query}, ${item.estimate.grams} g`,
    )
    .join("\n");
  const { meal, count } = await parseMeal(provider, text, locale, lookups.text, onToolCall);
  // The photo was seen by the vision call and not by parse: for a food lookup did not find, the
  // vision guess is the better one. A food lookup found but could not place stays unmatched, so
  // the person can search for it, and gets the guess beside it.
  const key = (value: string) => value.trim().toLocaleLowerCase(locale);
  const seen = new Map(rest.map((item) => [key(item.query), item.estimate]));
  for (const item of meal.items) {
    const estimate = item.estimate ? seen.get(key(item.query)) : undefined;
    items.push(estimate ? { query: item.query, estimate } : item);
  }
  for (const query of meal.unmatched) {
    const estimate = seen.get(key(query));
    if (estimate) items.push({ query, estimate });
  }
  const parsed = ParsedMeal.safeParse({ items: items.slice(0, 12), unmatched: meal.unmatched });
  if (!parsed.success) throw new HttpError(502, "ai-rejected");
  return { meal: parsed.data, count };
}
