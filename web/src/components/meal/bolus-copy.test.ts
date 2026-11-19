import { findDoseAdvice, messageStrings } from "@naensom/shared/dosing-vocabulary";
import { describe, expect, it } from "vitest";

import da from "../../../messages/da/log.json";
import en from "../../../messages/en/log.json";

// Issue #215: the "Bolus givet nu" tap is gone; the bolus time comes from an imported pump record,
// later. The only bolus string left in the log copy is the time template the chart legend and the
// meal markers use for a stored time.
describe("the log copy's only bolus string: a stored time", () => {
  it.each([
    ["da", da],
    ["en", en],
  ] as const)(
    "%s: keeps only Bolus {time}, with no tap, removal, undo or note",
    (_locale, copy) => {
      expect(copy.bolus).toEqual({ at: "Bolus {time}" });
    },
  );

  it("pairs no insulin figure with advice in the log screen's strings", () => {
    expect(findDoseAdvice(messageStrings({ "da/log.json": da, "en/log.json": en }))).toEqual([]);
  });
});
