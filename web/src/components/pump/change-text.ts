// The countdown's words, as pure functions: how far away a change is, in the one unit a person
// would say ("in 1 day", "in 5 hours"), and when the last one was.
import type { AppLocale } from "@/lib/i18n/routing";

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

export type Countdown =
  | { kind: "unknown" }
  | { kind: "now" }
  | { kind: "due"; value: number; unit: "day" | "hour" | "minute" }
  | { kind: "overdue"; value: number; unit: "day" | "hour" | "minute" };

/**
 * The distance to `dueAt` in one unit: whole days from 22 hours (rounded, so 30 hours is "1 day"
 * and 40 hours "2 days"), hours from an hour, minutes below that; within a minute either way it
 * is "now". Past the due time it is the same scale, overdue.
 */
export function countdownTo(dueAt: string | undefined, now: Date): Countdown {
  if (dueAt === undefined) return { kind: "unknown" };
  const ms = Date.parse(dueAt) - now.getTime();
  if (Number.isNaN(ms)) return { kind: "unknown" };
  const distance = Math.abs(ms);
  if (distance < MINUTE) return { kind: "now" };
  const kind = ms > 0 ? "due" : "overdue";
  if (distance >= 22 * HOUR) {
    return { kind, value: Math.max(1, Math.round(distance / DAY)), unit: "day" };
  }
  if (distance >= HOUR) return { kind, value: Math.round(distance / HOUR), unit: "hour" };
  return { kind, value: Math.max(1, Math.round(distance / MINUTE)), unit: "minute" };
}

const intlLocale = (locale: AppLocale) => (locale === "da" ? "da-DK" : "en-GB");

/** "om 1 dag" / "in 1 day", or "for 3 timer siden" / "3 hours ago", in the reader's language. */
export function relativeText(countdown: Countdown, locale: AppLocale): string {
  if (countdown.kind !== "due" && countdown.kind !== "overdue") return "";
  const signed = countdown.kind === "due" ? countdown.value : -countdown.value;
  return new Intl.RelativeTimeFormat(intlLocale(locale), { numeric: "always" }).format(
    signed,
    countdown.unit,
  );
}

/** "lør. 14. nov. 09:12" / "Sat 14 Nov 09:12" in the space's zone: the change's own time. */
export function changeTime(iso: string, timeZone: string, locale: AppLocale): string {
  const at = new Date(iso);
  const day = new Intl.DateTimeFormat(intlLocale(locale), {
    weekday: "short",
    day: "numeric",
    month: "short",
    timeZone,
  }).format(at);
  const clock = new Intl.DateTimeFormat("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
    timeZone,
  }).format(at);
  return `${day} ${clock}`;
}
