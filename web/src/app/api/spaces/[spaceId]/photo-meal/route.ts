import { HttpError, log } from "@naensom/shared";
import { PhotoMealRequest } from "@naensom/shared/schemas/ai";
import { estimateImage } from "@/ai/estimate/photo";
import { photoMealForSession } from "@/ai/photo-meal/service";
import { json, requireSpaceRole, spaceRoute } from "@/lib/live/server";
import { estimateBody } from "../estimates/http";
import { parseDeps, parseSessionDb } from "../parse/server";

/**
 * A meal photo to a draft the person reviews (owner, 2026-11-15). The photo goes to the AI
 * provider only on this explicit action and is not stored here; nothing is logged until the
 * person saves the meal.
 */
export const POST = spaceRoute("photo-meal.post", async (request, spaceId) => {
  const { session } = await requireSpaceRole(
    request,
    spaceId,
    ["owner", "carer"],
    parseSessionDb(),
  );
  if (session.simpleMode) throw new HttpError(400, "simple-mode");
  const body = await estimateBody(request);
  const parsed = PhotoMealRequest.safeParse(body);
  if (!parsed.success) throw new HttpError(400, "validation");
  const bytes = await estimateImage(parsed.data.photoDataUrl);
  const deps = parseDeps();
  let count = 0;
  try {
    const provider = await deps.provider(spaceId, session);
    const { meal } = await photoMealForSession(
      { ...deps, provider },
      spaceId,
      session,
      bytes,
      () => {
        count++;
      },
    );
    log.info("photo-meal.finished", { spaceId, userId: session.userId, count });
    return json(meal);
  } catch (error) {
    const safe = error instanceof HttpError ? error : new HttpError(503, "ai-unavailable");
    log.warn("photo-meal.failed", { spaceId, userId: session.userId, count, code: safe.code });
    throw safe;
  }
});
