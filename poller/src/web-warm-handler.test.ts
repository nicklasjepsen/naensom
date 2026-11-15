import { describe, expect, it, vi } from "vitest";

import { createWebWarmHandler, WEB_WARM_SCHEDULE } from "./web-warm-handler";

const URL = "https://app.example.test/api/health";

function recorder() {
  const lines: { level: string; msg: string; fields: unknown }[] = [];
  return {
    lines,
    log: {
      info: (msg: string, fields?: unknown) => lines.push({ level: "info", msg, fields }),
      warn: (msg: string, fields?: unknown) => lines.push({ level: "warn", msg, fields }),
    },
  };
}

function clock(...times: number[]) {
  let i = 0;
  return () => times[Math.min(i++, times.length - 1)] ?? 0;
}

describe("web keep-warm", () => {
  it("runs every five minutes, half a minute after the glucose poll", () => {
    expect(WEB_WARM_SCHEDULE).toBe("30 */5 * * * *");
  });

  it("asks the health endpoint once and logs the status and the time it took", async () => {
    const { lines, log } = recorder();
    const fetch = vi.fn((_url: string | URL | Request, _init?: RequestInit) =>
      Promise.resolve(new Response('{"ok":true}', { status: 200 })),
    );
    await createWebWarmHandler({ url: URL, fetch, log, now: clock(1000, 1450) })();
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(fetch.mock.calls[0]?.[0]).toBe(URL);
    expect(lines).toEqual([
      { level: "info", msg: "web-warm.done", fields: { status: 200, durationMs: 450 } },
    ]);
  });

  it("warns on an unhealthy answer and on a network error, and never throws", async () => {
    const { lines, log } = recorder();
    const unhealthy = vi.fn(() => Promise.resolve(new Response("{}", { status: 503 })));
    await createWebWarmHandler({ url: URL, fetch: unhealthy, log, now: clock(0, 20) })();
    const broken = vi.fn(() => Promise.reject(new TypeError("fetch failed")));
    await expect(
      createWebWarmHandler({ url: URL, fetch: broken, log, now: clock(0, 5) })(),
    ).resolves.toBeUndefined();
    expect(lines).toEqual([
      { level: "warn", msg: "web-warm.failed", fields: { status: 503, durationMs: 20 } },
      { level: "warn", msg: "web-warm.failed", fields: { durationMs: 5, code: "TypeError" } },
    ]);
  });

  it("does nothing without WEB_HEALTH_URL", async () => {
    const fetch = vi.fn();
    await createWebWarmHandler({ url: undefined, fetch })();
    expect(fetch).not.toHaveBeenCalled();
  });
});
