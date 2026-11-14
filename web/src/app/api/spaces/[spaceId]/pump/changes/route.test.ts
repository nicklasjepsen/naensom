// @vitest-environment node
import { isGlucoseEvent, type EventSink } from "@naensom/shared";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  cookieStoreFor,
  params,
  request,
  seedSpace,
  T0,
  USERS,
  type Who,
} from "@/components/settings/route-test-support";
import { FakeAuthDb, recordingSink, type RecordedEvent } from "@/lib/auth/test-support";

import { GET, PATCH } from "./route";

const shared = vi.hoisted(() => {
  const holder: { db: Record<string, unknown>; sink: EventSink; request: Request | null } = {
    db: {},
    sink: { publish: () => Promise.resolve() },
    request: null,
  };
  const sink: EventSink = { publish: (group, envelope) => holder.sink.publish(group, envelope) };
  return {
    holder,
    prisma: new Proxy({}, { get: (_target, key: string) => holder.db[key] }),
    sink,
  };
});
vi.mock("@naensom/shared", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  prisma: shared.prisma,
  createEventSinkFromEnv: () => shared.sink,
}));
vi.mock("next/headers", () => ({ cookies: cookieStoreFor(() => shared.holder.request) }));

const CONFIG = JSON.stringify({
  type: "nightscout",
  secretRef: "pump-s1/1",
  connectedBy: "u-owner",
});

let fake: FakeAuthDb;
let events: RecordedEvent[];
let published: { group: string; envelope: { type: string } }[];

beforeEach(() => {
  vi.useFakeTimers({ now: T0, toFake: ["Date"] });
  fake = new FakeAuthDb(() => T0);
  seedSpace(fake);
  for (const row of fake.rows("space")) {
    Object.assign(row, {
      pumpSource: CONFIG,
      pumpStatus: "connected",
      pumpFailures: 0,
      lastPumpAt: null,
      pumpCartridgeAt: new Date("2026-10-13T09:00:00.000Z"),
      pumpCannulaAt: null,
      pumpCartridgeDays: 3,
      pumpCannulaDays: 3,
    });
  }
  const recorder = recordingSink();
  events = recorder.events;
  published = recorder.published;
  shared.holder.db = fake.db as unknown as Record<string, unknown>;
  shared.holder.sink = recorder.sink;
  vi.spyOn(process.stdout, "write").mockImplementation(() => true);
});
afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});

const path = (spaceId: string) => `/api/spaces/${spaceId}/pump/changes`;
function get(as: Who | null, spaceId = "s1") {
  const req = request(path(spaceId), { as });
  shared.holder.request = req;
  return GET(req, params({ spaceId }));
}
function patch(as: Who | null, body: unknown, spaceId = "s1") {
  const req = request(path(spaceId), { method: "PATCH", body, as });
  shared.holder.request = req;
  return PATCH(req, params({ spaceId }));
}
const space = () => fake.rows("space").find((s) => s.id === "s1") ?? {};
const inSimpleMode = (who: Who) => {
  const user = fake.rows("user").find((u) => u.id === USERS[who]);
  if (user) user.simpleMode = true;
};

describe("GET /api/spaces/:id/pump/changes", () => {
  it("gives an owner and a carer each part's last fill, when it is due and its interval", async () => {
    for (const who of ["owner", "carer"] as const) {
      const response = await get(who);
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({
        cartridge: {
          lastAt: "2026-10-13T09:00:00.000Z",
          dueAt: "2026-10-16T09:00:00.000Z",
          days: 3,
        },
        cannula: { days: 3 },
        configured: true,
      });
    }
  });

  it("says when no pump record is set up", async () => {
    Object.assign(space(), { pumpSource: null });
    const body = (await (await get("owner")).json()) as { configured: boolean };
    expect(body.configured).toBe(false);
  });

  it("refuses a viewer, a simpleMode session and someone signed out, in the API", async () => {
    expect((await get("viewer")).status).toBe(403);
    expect((await get(null)).status).toBe(403);
    inSimpleMode("carer");
    expect((await get("carer")).status).toBe(403);
  });
});

describe("PATCH /api/spaces/:id/pump/changes", () => {
  it("sets the days and emits one pump.changes in the glucose group", async () => {
    const response = await patch("carer", { cannulaDays: 2 });
    expect(response.status).toBe(200);
    const body = (await response.json()) as { cannula: { days: number } };
    expect(body.cannula.days).toBe(2);
    expect(space()).toMatchObject({ pumpCannulaDays: 2, pumpCartridgeDays: 3 });
    expect(events.map((e) => [e.type, e.payload])).toEqual([
      ["pump.changes", { kinds: ["cannula"] }],
    ]);
    expect(isGlucoseEvent("pump.changes")).toBe(true);
    expect(published.map((p) => p.envelope.type)).toEqual(["pump.changes"]);
  });

  it("writes and emits nothing when the days are what they were", async () => {
    expect((await patch("owner", { cartridgeDays: 3 })).status).toBe(200);
    expect(events).toEqual([]);
  });

  it("refuses days outside 1 to 10, an empty body, a viewer and simpleMode", async () => {
    expect((await patch("owner", { cannulaDays: 0 })).status).toBe(400);
    expect((await patch("owner", { cannulaDays: 11 })).status).toBe(400);
    expect((await patch("owner", { cannulaDays: 2.5 })).status).toBe(400);
    expect((await patch("owner", {})).status).toBe(400);
    expect((await patch("viewer", { cannulaDays: 2 })).status).toBe(403);
    inSimpleMode("owner");
    expect((await patch("owner", { cannulaDays: 2 })).status).toBe(403);
    expect(events).toEqual([]);
  });
});
