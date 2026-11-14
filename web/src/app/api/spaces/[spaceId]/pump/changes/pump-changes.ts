// The change countdown's server side: the newest reservoir (cartridge) and infusion-set (cannula)
// fill and sensor session the pump recorded, and how many days each lasts. The fill times are written by the pump
// cycle only; this module reads them and writes the two intervals.
import {
  HttpError,
  PumpChangesView,
  PumpSourceConfig,
  type PumpChangeDaysBody,
  type PumpChangeKind,
} from "@naensom/shared";

import { run, type AuthDeps } from "@/lib/auth/core";

const DAY_MS = 86_400_000;

/** The Space columns the countdown reads. */
export interface PumpChangesRow {
  pumpSource: string | null;
  pumpCartridgeAt: Date | null;
  pumpCannulaAt: Date | null;
  pumpCartridgeDays: number;
  pumpCannulaDays: number;
  pumpSensorAt: Date | null;
  pumpSensorDays: number;
}

function configured(pumpSource: string | null): boolean {
  if (!pumpSource) return false;
  try {
    return PumpSourceConfig.safeParse(JSON.parse(pumpSource)).success;
  } catch {
    return false;
  }
}

/** A stored time more than this after now never happened; it reads as no change yet. */
const FUTURE_SLACK_MS = 10 * 60_000;

function part(lastAt: Date | null, days: number, now: Date) {
  if (lastAt === null || lastAt.getTime() > now.getTime() + FUTURE_SLACK_MS) return { days };
  return {
    lastAt: lastAt.toISOString(),
    dueAt: new Date(lastAt.getTime() + days * DAY_MS).toISOString(),
    days,
  };
}

/** The view of the row: each part's last fill, when it is due, its interval; never the config. */
export function toPumpChangesView(row: PumpChangesRow, now: Date): PumpChangesView {
  return PumpChangesView.parse({
    cartridge: part(row.pumpCartridgeAt, row.pumpCartridgeDays, now),
    cannula: part(row.pumpCannulaAt, row.pumpCannulaDays, now),
    sensor: part(row.pumpSensorAt, row.pumpSensorDays, now),
    configured: configured(row.pumpSource),
  });
}

/**
 * Sets how many days a part lasts and emits one `pump.changes` naming the parts whose interval
 * changed, so every open countdown reads again. Nothing to change writes and emits nothing.
 */
export function savePumpChangeDays(
  spaceId: string,
  body: PumpChangeDaysBody,
  deps: AuthDeps = {},
): Promise<PumpChangesView> {
  return run(
    deps,
    async (tx, emit, now) => {
      const current = await tx.space.findUnique({ where: { id: spaceId } });
      if (!current) throw new HttpError(404, "not-found");
      const data: {
        pumpCartridgeDays?: number;
        pumpCannulaDays?: number;
        pumpSensorDays?: number;
      } = {};
      const kinds: PumpChangeKind[] = [];
      if (body.cannulaDays !== undefined && body.cannulaDays !== current.pumpCannulaDays) {
        data.pumpCannulaDays = body.cannulaDays;
        kinds.push("cannula");
      }
      if (body.cartridgeDays !== undefined && body.cartridgeDays !== current.pumpCartridgeDays) {
        data.pumpCartridgeDays = body.cartridgeDays;
        kinds.push("cartridge");
      }
      if (body.sensorDays !== undefined && body.sensorDays !== current.pumpSensorDays) {
        data.pumpSensorDays = body.sensorDays;
        kinds.push("sensor");
      }
      if (kinds.length === 0) return toPumpChangesView(current, now());
      const row = await tx.space.update({ where: { id: spaceId }, data });
      await emit(spaceId, "pump.changes", { kinds });
      return toPumpChangesView(row, now());
    },
    { serializable: true },
  );
}
