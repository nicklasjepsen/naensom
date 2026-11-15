// @vitest-environment node
import { afterEach, expect, it, vi } from "vitest";
import { FakeAiProvider } from "@naensom/shared/ai/fake";
import { MemoryFoodRepository } from "@naensom/shared/food/memory";
import { FakeFoodSource } from "@naensom/shared/food/fake";
import { FakeLiveDb, captureLog, liveRequest, spaceContext } from "@/lib/live/test-support";
import plate from "../estimates/fixtures/plate.json";
import { configureParse } from "../parse/server";
import { POST } from "./route";

const guess = { name: "Example stew", grams: 250, carbs: 35, confidence: "low", approx: true };
function setup(simpleMode = false) {
  const auth = new FakeLiveDb(() => new Date());
  auth.addSpace("s1");
  for (const role of ["owner", "carer", "viewer"] as const) auth.addMember(role, "s1", role);
  const db = auth.db;
  // loadSession reads the user with user.findFirst; this session's user is changed there.
  const original = db.user.findFirst.bind(db.user);
  db.user.findFirst = vi.fn(async (args: Parameters<typeof original>[0]) => {
    const user = await original(args);
    return user ? { ...user, simpleMode, locale: "en" } : null;
  }) as unknown as typeof original;
  const fake = new FakeAiProvider([
    {
      kind: "json",
      model: "fixture",
      json: { items: [{ query: "Example stew", kind: "dish", estimate: guess }] },
    },
    {
      kind: "tool-calls",
      model: "fixture",
      calls: [{ id: "1", name: "lookup", input: { query: "Example stew" } }],
    },
    {
      kind: "json",
      model: "fixture",
      json: { items: [], unmatched: ["Example stew"] },
    },
  ]);
  const source = new FakeFoodSource({ id: "fake-remote", kind: "remote" });
  configureParse({
    sessionDb: db,
    repo: new MemoryFoodRepository(),
    sources: [source],
    provider: () => Promise.resolve(fake),
  });
  return { fake, source };
}
function post(user = "carer", body: unknown = { photoDataUrl: plate.photoDataUrl }) {
  const req = liveRequest("s1", "photo-meal", `sess-${user}`);
  return POST(
    new Request(req, { method: "POST", headers: req.headers, body: JSON.stringify(body) }),
    spaceContext("s1"),
  );
}
afterEach(() => {
  configureParse({});
  vi.restoreAllMocks();
});

it.each(["owner", "carer"])("turns a photo into a draft for %s, guesses marked", async (role) => {
  const { fake, source } = setup();
  const logs = captureLog();
  const response = await post(role);
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({
    items: [{ query: "Example stew", estimate: guess }],
    unmatched: ["Example stew"],
  });
  expect(fake.calls.map((call) => call.kind)).toEqual(["vision", "complete", "complete"]);
  expect(source.calls).toEqual([{ method: "search", q: "Example stew", locale: "en" }]);
  expect(logs.all()).not.toMatch(/stew|Example/);
  expect(logs.all()).not.toContain(plate.photoDataUrl.split(",")[1]?.slice(0, 40));
});

it.each([
  ["viewer", false, 403],
  ["carer", true, 400],
] as const)("rejects %s simple=%s before any AI call", async (user, simple, status) => {
  const { fake } = setup(simple);
  expect((await post(user)).status).toBe(status);
  expect(fake.calls).toHaveLength(0);
});

it("rejects something that is not a JPEG before any AI call", async () => {
  const { fake } = setup();
  expect((await post("carer", { photoDataUrl: "data:image/png;base64,AAAA" })).status).toBe(400);
  expect(fake.calls).toHaveLength(0);
});
