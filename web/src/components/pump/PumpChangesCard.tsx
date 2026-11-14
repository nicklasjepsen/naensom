"use client";

import type { PumpChangeKind, PumpChangesView } from "@naensom/shared/schemas/pump";
import { useTranslations } from "next-intl";
import { useId, useState } from "react";

import { Card } from "@/components/ui/Card";
import type { AppLocale } from "@/lib/i18n/routing";

import { changeTime, countdownTo, relativeText } from "./change-text";
import { savePumpChangeDays } from "./changes-api";
import styles from "./pump-changes.module.css";

const KINDS: PumpChangeKind[] = ["cartridge", "cannula"];
const DAY_CHOICES = Array.from({ length: 10 }, (_, i) => i + 1);

export interface PumpChangesCardProps {
  spaceId: string;
  view: PumpChangesView;
  now: Date;
  timeZone: string;
  locale: AppLocale;
  /** A fresh answer after the days were changed. */
  onSaved: (view: PumpChangesView) => void;
  save?: typeof savePumpChangeDays;
}

/**
 * "Pumpeskift": when the reservoir and the site are next due, in the words a person would use
 * ("om 1 dag"). Tapping a part shows when the pump recorded the last change and how many days the
 * part lasts, which can be changed there. The times come from the pump; nothing is typed. Past due
 * reads calmly, in the muted ink: this is a reminder, not an alarm.
 */
export function PumpChangesCard({
  spaceId,
  view,
  now,
  timeZone,
  locale,
  onSaved,
  save = savePumpChangeDays,
}: PumpChangesCardProps) {
  const t = useTranslations("pumpChanges");
  const [open, setOpen] = useState<PumpChangeKind | null>(null);
  const [failed, setFailed] = useState(false);
  const [busy, setBusy] = useState(false);
  const baseId = useId();

  async function setDays(kind: PumpChangeKind, days: number) {
    setBusy(true);
    setFailed(false);
    try {
      onSaved(
        await save(spaceId, kind === "cartridge" ? { cartridgeDays: days } : { cannulaDays: days }),
      );
    } catch {
      setFailed(true);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card className={styles.card} data-testid="pump-changes">
      <h2 className={styles.title}>{t("title")}</h2>
      <ul className={styles.list}>
        {KINDS.map((kind) => {
          const part = view[kind];
          const countdown = countdownTo(part.dueAt, now);
          const detailId = `${baseId}-${kind}`;
          const expanded = open === kind;
          let summary: string;
          if (countdown.kind === "unknown") summary = t("unknown");
          else if (countdown.kind === "now") summary = t("dueNow");
          else if (countdown.kind === "due")
            summary = t("due", { when: relativeText(countdown, locale) });
          else summary = t("overdue", { when: relativeText(countdown, locale) });
          return (
            <li key={kind} className={styles.item} data-testid={`pump-change-${kind}`}>
              <button
                type="button"
                className={styles.row}
                aria-expanded={expanded}
                aria-controls={detailId}
                onClick={() => {
                  setOpen(expanded ? null : kind);
                }}
              >
                <span className={styles.name}>{t(kind)}</span>
                <span
                  className={styles.when}
                  data-overdue={countdown.kind === "overdue" || countdown.kind === "now"}
                >
                  {summary}
                </span>
              </button>
              {expanded && (
                <div id={detailId} className={styles.detail}>
                  <p>
                    {part.lastAt
                      ? t("last", { time: changeTime(part.lastAt, timeZone, locale) })
                      : t("noneYet")}
                  </p>
                  {part.dueAt && (
                    <p>{t("next", { time: changeTime(part.dueAt, timeZone, locale) })}</p>
                  )}
                  <label className={styles.days}>
                    <span>{t("lasts")}</span>
                    <select
                      value={part.days}
                      disabled={busy}
                      onChange={(event) => {
                        void setDays(kind, Number(event.target.value));
                      }}
                    >
                      {DAY_CHOICES.map((days) => (
                        <option key={days} value={days}>
                          {t("days", { days })}
                        </option>
                      ))}
                    </select>
                  </label>
                  {failed && (
                    <p className={styles.failed} role="alert">
                      {t("saveFailed")}
                    </p>
                  )}
                </div>
              )}
            </li>
          );
        })}
      </ul>
      <p className={styles.hint}>{t("fromPump")}</p>
    </Card>
  );
}
