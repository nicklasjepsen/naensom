import { describe, expect, it } from "vitest";

import { changeTime, countdownTo, relativeText } from "./change-text";

const NOW = new Date("2026-11-14T12:00:00.000Z");
const at = (hours: number) => new Date(NOW.getTime() + hours * 3_600_000).toISOString();

describe("countdownTo", () => {
  it("says nothing without a change from the pump", () => {
    expect(countdownTo(undefined, NOW)).toEqual({ kind: "unknown" });
  });

  it("counts whole days from 22 hours, rounded", () => {
    expect(countdownTo(at(22), NOW)).toEqual({ kind: "due", value: 1, unit: "day" });
    expect(countdownTo(at(30), NOW)).toEqual({ kind: "due", value: 1, unit: "day" });
    expect(countdownTo(at(40), NOW)).toEqual({ kind: "due", value: 2, unit: "day" });
    expect(countdownTo(at(72), NOW)).toEqual({ kind: "due", value: 3, unit: "day" });
  });

  it("counts hours below that and minutes below an hour", () => {
    expect(countdownTo(at(5.4), NOW)).toEqual({ kind: "due", value: 5, unit: "hour" });
    expect(countdownTo(at(0.5), NOW)).toEqual({ kind: "due", value: 30, unit: "minute" });
  });

  it("is now within a minute, and overdue past it on the same scale", () => {
    expect(countdownTo(at(0.01), NOW)).toEqual({ kind: "now" });
    expect(countdownTo(at(-3), NOW)).toEqual({ kind: "overdue", value: 3, unit: "hour" });
    expect(countdownTo(at(-26), NOW)).toEqual({ kind: "overdue", value: 1, unit: "day" });
  });
});

describe("relativeText", () => {
  it("reads like a person says it, in both languages", () => {
    expect(relativeText({ kind: "due", value: 1, unit: "day" }, "en")).toBe("in 1 day");
    expect(relativeText({ kind: "due", value: 1, unit: "day" }, "da")).toBe("om 1 dag");
    expect(relativeText({ kind: "due", value: 5, unit: "hour" }, "da")).toBe("om 5 timer");
    expect(relativeText({ kind: "overdue", value: 3, unit: "hour" }, "en")).toBe("3 hours ago");
    expect(relativeText({ kind: "overdue", value: 3, unit: "hour" }, "da")).toBe(
      "for 3 timer siden",
    );
  });
});

describe("changeTime", () => {
  it("gives the weekday, the date and the clock in the space's zone", () => {
    expect(changeTime("2026-11-14T08:12:00.000Z", "Europe/Copenhagen", "en")).toBe(
      "Sat 14 Nov 09:12",
    );
    expect(changeTime("2026-11-14T08:12:00.000Z", "Europe/Copenhagen", "da")).toMatch(
      /^lør\.? 14\. nov\.? 09:12$/,
    );
  });
});
