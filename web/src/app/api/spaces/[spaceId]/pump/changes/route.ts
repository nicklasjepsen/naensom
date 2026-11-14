import { HttpError, PumpChangeDaysBody, prisma, type Role } from "@naensom/shared";

import { json, logOutcome, parseBody, settingsRoute } from "@/components/settings/api-route";
import { requireRole } from "@/lib/auth/session";

import { savePumpChangeDays, toPumpChangesView } from "./pump-changes";

const ROUTE = "spaces.pump-changes";
interface Params {
  spaceId: string;
}

/**
 * The countdown is part of the pump record: owners and carers outside simpleMode only. A viewer
 * and a simpleMode session are 403 here, in the API, before anything is read.
 */
async function requirePumpRole(spaceId: string, ...roles: Role[]) {
  const access = await requireRole(spaceId, ...roles);
  if (access.session.simpleMode) throw new HttpError(403, "forbidden");
  return access;
}

/** When the reservoir and the site were last changed, as the pump recorded it, and when next. */
export const GET = settingsRoute<Params>(ROUTE, async (_request, { spaceId }) => {
  await requirePumpRole(spaceId, "owner", "carer");
  const row = await prisma.space.findUnique({ where: { id: spaceId } });
  if (!row) throw new HttpError(404, "not-found");
  return json(toPumpChangesView(row));
});

/** How many days the reservoir and the site last; owners and carers. */
export const PATCH = settingsRoute<Params>(ROUTE, async (request, { spaceId }) => {
  const { session } = await requirePumpRole(spaceId, "owner", "carer");
  const body = await parseBody(request, PumpChangeDaysBody);
  const view = await savePumpChangeDays(spaceId, body);
  logOutcome("pump.change-days-updated", ROUTE, "ok", { spaceId, userId: session.userId });
  return json(view);
});
