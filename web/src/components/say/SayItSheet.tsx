"use client";
import type { ParsedItem, ParsedMeal } from "@naensom/shared/schemas/ai";
import { useTranslations } from "next-intl";
import { useCallback, useEffect, useRef, useState } from "react";
import { PhotoPicker } from "../food/PhotoPicker";
import { BackButton } from "../ui/BackButton";
import { Button } from "../ui/Button";
import { Notice } from "../ui/Notice";
import { createSymptom } from "../symptoms/api";
import { readBarcodeInPhoto } from "@/lib/barcode/detect";
import { parseText, photoMeal } from "./api";
import { MicButton } from "./MicButton";
import { ParsedItems, type ParsedSymptom } from "./ParsedItems";
import styles from "./say.module.css";

export function SayItSheet({
  spaceId,
  locale,
  active = true,
  onClose,
  onAdd,
  onSearch,
  photo = null,
  onBarcode,
}: {
  active?: boolean;
  /** A photo taken from Log's photo tile: the sheet opens on it and reads it at once. */
  photo?: Uint8Array | null;
  /** A barcode found in a photo; the caller looks it up like a scan, with no AI call. */
  onBarcode?: (code: string) => void;
  spaceId: string;
  locale: string;
  onClose: () => void;
  onAdd: (items: ParsedItem[]) => Promise<void>;
  onSearch: (query: string) => void;
}) {
  const t = useTranslations("say");
  const [text, setText] = useState("");
  const [meal, setMeal] = useState<ParsedMeal | null>(null);
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const [version, setVersion] = useState(0);
  const panel = useRef<HTMLElement>(null);
  const pending = useRef(false);
  const live = useRef(true);
  /** Feelings already logged from the current answer: a retry after a failure never repeats one. */
  const logged = useRef(new Set<string>());
  const updateText = useCallback((value: string) => {
    if (pending.current) return;
    setText(value);
    setMeal(null);
    setFailed(false);
  }, []);
  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);
  useEffect(() => {
    if (!active) return;
    const previous = document.activeElement;
    panel.current?.focus();
    return () => {
      if (previous instanceof HTMLElement) previous.focus();
    };
  }, [active]);
  /**
   * A barcode in the photo is a scan (no AI call); anything else goes to photo-to-meal, whose
   * draft lists matched foods with their real carbs and guesses marked as guesses.
   */
  function fromPhoto(bytes: Uint8Array) {
    void run(async () => {
      if (onBarcode) {
        const code = await readBarcodeInPhoto(bytes).catch(() => null);
        if (code) {
          onBarcode(code);
          return;
        }
      }
      show(await photoMeal(spaceId, bytes));
    });
  }
  const latestPhoto = useRef<Uint8Array | null>(null);
  useEffect(() => {
    if (!active || !photo || latestPhoto.current === photo) return;
    latestPhoto.current = photo;
    fromPhoto(photo);
  });
  async function run(action: () => Promise<void>) {
    if (pending.current) return;
    pending.current = true;
    setBusy(true);
    setFailed(false);
    try {
      await action();
    } catch {
      if (live.current) setFailed(true);
    } finally {
      pending.current = false;
      if (live.current) setBusy(false);
    }
  }
  function show(answer: ParsedMeal) {
    logged.current.clear();
    if (live.current) {
      setMeal(answer);
      setVersion((v) => v + 1);
    }
  }
  /**
   * The feelings go through the symptoms route right away; the food goes to the meal draft, and
   * only when there is food. "jeg har ondt i maven" alone logs a symptom and no meal (plan §5).
   */
  async function add(items: ParsedItem[], symptoms: ParsedSymptom[]) {
    for (const symptom of symptoms) {
      const key = `${symptom.kind}\u0000${symptom.note ?? ""}`;
      if (logged.current.has(key)) continue;
      await createSymptom(spaceId, {
        kind: symptom.kind,
        ...(symptom.note ? { note: symptom.note } : {}),
      });
      logged.current.add(key);
    }
    if (items.length > 0) await onAdd(items);
    logged.current.clear();
    if (live.current) {
      setMeal(null);
      setText("");
    }
    if (items.length === 0) onClose();
  }
  return (
    <section
      hidden={!active}
      ref={panel}
      tabIndex={-1}
      className={styles.sheet}
      aria-label={t("title")}
      onKeyDown={(event) => {
        if (event.key === "Escape" && !busy) onClose();
      }}
    >
      <header className={styles.header}>
        <BackButton onClick={onClose} label={t("back")} disabled={busy} />
        <h2>{t("title")}</h2>
      </header>
      {active && <MicButton locale={locale} onTranscript={updateText} disabled={busy} />}
      <form
        onSubmit={(event) => {
          event.preventDefault();
          if (text.trim())
            void run(async () => {
              show(await parseText(spaceId, text.trim()));
            });
        }}
      >
        <label className={styles.field}>
          {t("field")}
          <textarea
            maxLength={500}
            placeholder={t("placeholder")}
            value={text}
            disabled={busy}
            onChange={(event) => {
              updateText(event.target.value);
            }}
          />
        </label>
        <Button size="phone" type="submit" disabled={busy || !text.trim()}>
          {t("find")}
        </Button>
      </form>
      <fieldset disabled={busy} className={styles.photos}>
        <PhotoPicker onPhoto={fromPhoto} />
      </fieldset>
      {busy && <p role="status">{t("looking")}</p>}
      {failed && (
        <Notice role="status" tone="sunken">
          {t("unavailable")}
        </Notice>
      )}
      {meal && (
        <ParsedItems
          key={version}
          meal={meal}
          locale={locale}
          busy={busy}
          onSearch={onSearch}
          onAdd={(items, symptoms) => void run(() => add(items, symptoms))}
        />
      )}
    </section>
  );
}
