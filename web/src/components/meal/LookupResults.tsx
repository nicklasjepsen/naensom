"use client";
import type {
  FoodCandidate,
  FoodView,
  LookupResponse,
  LookupResult,
} from "@naensom/shared/schemas/food";
import { useLocale, useTranslations } from "next-intl";
import Link from "next/link";

import { localeHref, resolveLocale } from "@/lib/i18n/routing";

import { FoodPhoto } from "../food/FoodPhoto";
import { ListRow } from "../ui/ListRow";
import { Notice } from "../ui/Notice";
import styles from "./meal.module.css";
import { useSourceLine } from "./source-line";

const DOWN = new Set(["timeout", "error", "rate-limited"]);

/** The sources that did not answer this lookup. */
export function sourcesDown(response: LookupResponse): string[] {
  return Object.entries(response.sources)
    .filter(([, status]) => DOWN.has(status))
    .map(([id]) => id);
}
/** Food sources this lookup left out because it was the as-you-type one (`remote: false`). */
function sourcesSkipped(response: LookupResponse): string[] {
  return Object.entries(response.sources)
    .filter(([id, status]) => status === "skipped" && id !== "semantic")
    .map(([id]) => id);
}

export const isLibraryFood = (food: FoodView | FoodCandidate): food is FoodView => "id" in food;

/**
 * The lookup's answer in the order the server resolved it (own library first, §4), each row with
 * its badge and source line, a notice per source that did not answer, and last the row
 * "Jeg kender tallet selv", which is always there (§4 step 5), followed by "Fra opskrift", the
 * manual path's way to a dish from a recipe (v0.6.0 plan §6).
 */
export function LookupResults({
  response,
  query,
  highlighted,
  onPick,
  onManual,
  onSearchAll,
  desktop = false,
}: {
  response: LookupResponse;
  query: string;
  highlighted?: number;
  onPick: (result: LookupResult) => void;
  onManual: () => void;
  /** Given while the answer is the as-you-type one: a row that searches every source. */
  onSearchAll?: (() => void) | undefined;
  desktop?: boolean;
}) {
  const t = useTranslations("log");
  const recipe = useTranslations("recipe.waysIn");
  const locale = resolveLocale(useLocale());
  const { line, sourceName } = useSourceLine();
  const down = sourcesDown(response);
  const skipped = onSearchAll ? sourcesSkipped(response) : [];
  const manualName = response.manual.name ?? query.trim();
  return (
    <div className={styles.results} data-testid="lookup-results">
      {desktop ? (
        <p className={styles.resultsMeta}>
          {t("results.desktopCount", { count: response.results.length })}
        </p>
      ) : (
        response.results.length > 0 && <p className={styles.resultsMeta}>{t("results.ownFirst")}</p>
      )}
      {down.map((id) => (
        <Notice key={id} tone="sunken" role="status">
          {t("sourceDown", { source: sourceName(id) })}
        </Notice>
      ))}
      <ul className={styles.resultList} role="list">
        {response.results.map((result, index) => {
          const key = isLibraryFood(result.food)
            ? result.food.id
            : `${result.food.origin}:${result.food.sourceRef}`;
          return (
            <li
              key={key}
              className={styles.resultItem}
              data-highlighted={highlighted === index ? "true" : undefined}
            >
              <ListRow
                title={result.food.name}
                verified={result.verified}
                secondary={line(result.food)}
                photo={
                  <FoodPhoto
                    src={isLibraryFood(result.food) ? result.food.photo?.thumbUrl : undefined}
                  />
                }
                onClick={() => {
                  onPick(result);
                }}
              />
            </li>
          );
        })}
        {skipped.length > 0 && (
          <li className={styles.resultItem}>
            <button type="button" className={styles.manualRow} onClick={onSearchAll}>
              <strong>
                {t("searchAll.title", {
                  sources: new Intl.ListFormat(locale, { type: "conjunction" }).format(
                    skipped.map(sourceName),
                  ),
                })}
              </strong>
              <span>{t("searchAll.subtitle")}</span>
            </button>
          </li>
        )}
        <li
          className={styles.resultItem}
          data-highlighted={highlighted === response.results.length ? "true" : undefined}
        >
          <button type="button" className={styles.manualRow} onClick={onManual}>
            <strong>{t("manual.title")}</strong>
            <span>
              {manualName ? t("manual.subtitle", { q: manualName }) : t("manual.subtitleEmpty")}
            </span>
          </button>
        </li>
        <li className={styles.resultItem}>
          <Link
            href={localeHref(locale, "/recipe/new")}
            className={styles.manualRow}
            data-testid="from-recipe"
          >
            <strong>{recipe("fromRecipe")}</strong>
            <span>{recipe("fromRecipeSubtitle")}</span>
          </Link>
        </li>
      </ul>
    </div>
  );
}
