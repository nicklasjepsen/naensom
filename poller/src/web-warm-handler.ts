import { log as defaultLog, type Logger } from "@naensom/shared";

/**
 * Every five minutes, offset from `poll` so the two never start in the same second. The web app's
 * server on Static Web Apps is recycled after a while without requests, and its pooled database
 * connections go stale, so the first open after a quiet hour paid for both (seen as 2–15 s opens in
 * the load reports, `docs/operations.md`). One health request keeps the server and a database
 * connection in use.
 */
export const WEB_WARM_SCHEDULE = "30 */5 * * * *";

/** Long enough for a cold start to finish, short enough that a hung request ends before the next run. */
export const WEB_WARM_TIMEOUT_MS = 60_000;

export interface WebWarmDeps {
  /** The web app's health endpoint (`WEB_HEALTH_URL`); unset means no keep-warm (Docker, a fork). */
  url: string | undefined;
  fetch?: typeof fetch;
  now?: () => number;
  log?: Pick<Logger, "info" | "warn">;
}

/**
 * One GET of the health endpoint. Logs the status and how long it took, never the body; a failure
 * is a warning and never throws, because a missed keep-warm is not worth a failed invocation.
 */
export function createWebWarmHandler(deps: WebWarmDeps): () => Promise<void> {
  const doFetch = deps.fetch ?? fetch;
  const now = deps.now ?? (() => Date.now());
  const log = deps.log ?? defaultLog;
  return async () => {
    if (!deps.url) return;
    const started = now();
    try {
      const response = await doFetch(deps.url, {
        method: "GET",
        headers: { "user-agent": "naensom-web-warm" },
        signal: AbortSignal.timeout(WEB_WARM_TIMEOUT_MS),
      });
      // Read the body so the connection is released; its content is not needed.
      await response.arrayBuffer();
      const fields = { status: response.status, durationMs: now() - started };
      if (response.ok) log.info("web-warm.done", fields);
      else log.warn("web-warm.failed", fields);
    } catch (error) {
      log.warn("web-warm.failed", {
        durationMs: now() - started,
        code: error instanceof Error ? error.name : "unknown",
      });
    }
  };
}
