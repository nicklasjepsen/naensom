import { lookup, type FoodRepository, type FoodSource, type SessionContext } from "@naensom/shared";
import type { AiProvider } from "@naensom/shared/ai";
import { photoToMeal } from "@naensom/shared/ai/photo-meal/photo-meal";

/** Photo to meal draft for one session: the same lookups as Say entry and the barcode scanner. */
export function photoMealForSession(
  deps: { provider: AiProvider; repo: FoodRepository; sources: FoodSource[] },
  spaceId: string,
  session: SessionContext,
  bytes: Uint8Array,
  onToolCall: () => void,
) {
  const base = { spaceId, session, locale: session.locale };
  return photoToMeal(
    deps.provider,
    Buffer.from(bytes).toString("base64"),
    session.locale,
    {
      text: (q) => lookup(deps.repo, deps.sources, { ...base, query: { q, remote: true } }),
      barcode: (barcode) => lookup(deps.repo, deps.sources, { ...base, query: { barcode } }),
    },
    onToolCall,
  );
}
