"use client";

import type { Role } from "@naensom/shared/schemas/index";
import type { PumpChangesView } from "@naensom/shared/schemas/pump";
import { useCallback, useEffect, useState } from "react";

import type { FeedEventType } from "@/lib/live/live-feed";

import { loadPumpChanges } from "./changes-api";
import { PUMP_RECHECK_MS } from "./usePumpHistory";

export type PumpChangesState =
  | { status: "off" }
  | { status: "loading" }
  | { status: "failed" }
  | { status: "ready"; view: PumpChangesView };

type Subscribe = (type: FeedEventType, handler: () => void) => () => void;

/** A new fill from the pump, a changed interval, or the record connected or dropped. */
export const PUMP_CHANGES_REFRESH_ON: FeedEventType[] = ["pump.changes", "pump.status"];

export interface PumpChangesOptions {
  subscribe: Subscribe | undefined;
  role: Role;
  simpleMode: boolean;
  enabled?: boolean;
}

/**
 * The change countdown for a space: read once, again on `pump.changes` and `pump.status`, and every
 * `PUMP_RECHECK_MS` after a failed read until one succeeds. A viewer and a simpleMode session ask
 * for nothing; the route refuses both anyway. `replace` puts a fresh answer (after a save) on
 * screen without another read.
 */
export function usePumpChanges(
  spaceId: string,
  { subscribe, role, simpleMode, enabled = true }: PumpChangesOptions,
): { state: PumpChangesState; replace: (view: PumpChangesView) => void } {
  const allowed = enabled && role !== "viewer" && !simpleMode;
  const [state, setState] = useState<{ spaceId: string; state: PumpChangesState; retry: boolean }>({
    spaceId: "",
    state: { status: "loading" },
    retry: false,
  });
  const [version, setVersion] = useState(0);
  const refresh = useCallback(() => {
    setVersion((v) => v + 1);
  }, []);
  const replace = useCallback(
    (view: PumpChangesView) => {
      setState({ spaceId, state: { status: "ready", view }, retry: false });
    },
    [spaceId],
  );

  useEffect(() => {
    if (!allowed) return;
    const controller = new AbortController();
    loadPumpChanges(spaceId, controller.signal)
      .then((view) => {
        setState({ spaceId, state: { status: "ready", view }, retry: false });
      })
      .catch(() => {
        if (controller.signal.aborted) return;
        setState((prev) =>
          prev.spaceId === spaceId && prev.state.status === "ready"
            ? { ...prev, retry: true }
            : { spaceId, state: { status: "failed" }, retry: true },
        );
      });
    return () => {
      controller.abort();
    };
  }, [allowed, spaceId, version]);

  const retry = allowed && state.spaceId === spaceId && state.retry;
  useEffect(() => {
    if (!retry) return;
    const timer = setTimeout(refresh, PUMP_RECHECK_MS);
    return () => {
      clearTimeout(timer);
    };
  }, [retry, version, refresh]);

  useEffect(() => {
    if (!allowed || !subscribe) return;
    const offs = PUMP_CHANGES_REFRESH_ON.map((type) => subscribe(type, refresh));
    return () => {
      for (const off of offs) off();
    };
  }, [allowed, subscribe, refresh]);

  if (!allowed) return { state: { status: "off" }, replace };
  return { state: state.spaceId === spaceId ? state.state : { status: "loading" }, replace };
}
