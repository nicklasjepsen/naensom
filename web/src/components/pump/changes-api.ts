// The client side of `GET` and `PATCH /api/spaces/:id/pump/changes`. Browser-safe: the schema
// module only, never the shared barrel.
import { PumpChangesView, type PumpChangeDaysBody } from "@naensom/shared/schemas/pump";

import { PumpRequestError } from "./api";

const url = (spaceId: string) => `/api/spaces/${encodeURIComponent(spaceId)}/pump/changes`;

/** When the reservoir and the site were last changed, as the pump recorded it, and when next. */
export async function loadPumpChanges(
  spaceId: string,
  signal?: AbortSignal,
): Promise<PumpChangesView> {
  const response = await fetch(url(spaceId), {
    headers: { accept: "application/json" },
    credentials: "same-origin",
    ...(signal ? { signal } : {}),
  });
  if (!response.ok) throw new PumpRequestError(response.status);
  return PumpChangesView.parse(await response.json());
}

/** How many days the reservoir or the site lasts; the answer is the countdown as it now is. */
export async function savePumpChangeDays(
  spaceId: string,
  body: PumpChangeDaysBody,
): Promise<PumpChangesView> {
  const response = await fetch(url(spaceId), {
    method: "PATCH",
    headers: { accept: "application/json", "content-type": "application/json" },
    credentials: "same-origin",
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new PumpRequestError(response.status);
  return PumpChangesView.parse(await response.json());
}
