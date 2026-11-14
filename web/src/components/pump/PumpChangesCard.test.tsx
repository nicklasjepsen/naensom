import "@testing-library/jest-dom/vitest";

import type { PumpChangesView } from "@naensom/shared/schemas/pump";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { I18nProvider } from "@/lib/i18n/Provider";
import { getMessages } from "@/lib/i18n/messages";
import type { AppLocale } from "@/lib/i18n/routing";

import { PumpChangesCard } from "./PumpChangesCard";

const NOW = new Date("2026-11-14T12:00:00.000Z");
const VIEW: PumpChangesView = {
  cartridge: {
    lastAt: "2026-11-12T13:00:00.000Z",
    dueAt: "2026-11-15T13:00:00.000Z",
    days: 3,
  },
  cannula: {
    lastAt: "2026-11-11T09:00:00.000Z",
    dueAt: "2026-11-14T09:00:00.000Z",
    days: 3,
  },
  configured: true,
};

afterEach(() => {
  cleanup();
});

function mount(
  props: { view?: PumpChangesView; locale?: AppLocale; save?: () => Promise<PumpChangesView> } = {},
) {
  const onSaved = vi.fn();
  const save = vi.fn(props.save ?? (() => Promise.resolve(VIEW)));
  const locale = props.locale ?? "da";
  render(
    <I18nProvider locale={locale} messages={getMessages(locale)}>
      <PumpChangesCard
        spaceId="s1"
        view={props.view ?? VIEW}
        now={NOW}
        timeZone="Europe/Copenhagen"
        locale={locale}
        onSaved={onSaved}
        save={save}
      />
    </I18nProvider>,
  );
  return { onSaved, save };
}

describe("PumpChangesCard", () => {
  it("says when each part is due in plain words", () => {
    mount();
    expect(screen.getByTestId("pump-change-cartridge")).toHaveTextContent(
      "ReservoirSkiftes om 1 dag",
    );
    expect(screen.getByTestId("pump-change-cannula")).toHaveTextContent(
      "KanyleSkulle skiftes for 3 timer siden",
    );
  });

  it("reads in English too", () => {
    mount({ locale: "en" });
    expect(screen.getByTestId("pump-change-cartridge")).toHaveTextContent(
      "ReservoirChange in 1 day",
    );
    expect(screen.getByTestId("pump-change-cannula")).toHaveTextContent("SiteWas due 3 hours ago");
  });

  it("shows the last change time when a part is tapped, and hides it again", () => {
    mount();
    const row = within(screen.getByTestId("pump-change-cartridge")).getByRole("button");
    expect(row).toHaveAttribute("aria-expanded", "false");
    fireEvent.click(row);
    expect(row).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByText(/^Sidst skiftet .*12\. nov.* 14:00$/)).toBeInTheDocument();
    expect(screen.getByText(/^Næste gang .*15\. nov.* 14:00$/)).toBeInTheDocument();
    fireEvent.click(row);
    expect(screen.queryByText(/^Sidst skiftet/)).toBeNull();
  });

  it("says so when the pump has not sent a change yet", () => {
    mount({ view: { ...VIEW, cannula: { days: 3 } } });
    expect(screen.getByTestId("pump-change-cannula")).toHaveTextContent(
      "Intet skift fra pumpen endnu",
    );
  });

  it("saves a new interval and hands back the fresh countdown", async () => {
    const { save, onSaved } = mount();
    fireEvent.click(within(screen.getByTestId("pump-change-cannula")).getByRole("button"));
    fireEvent.change(screen.getByRole("combobox"), { target: { value: "2" } });
    await waitFor(() => {
      expect(onSaved).toHaveBeenCalledWith(VIEW);
    });
    expect(save).toHaveBeenCalledWith("s1", { cannulaDays: 2 });
  });

  it("says when a save did not go through", async () => {
    mount({ save: () => Promise.reject(new Error("x")) });
    fireEvent.click(within(screen.getByTestId("pump-change-cartridge")).getByRole("button"));
    fireEvent.change(screen.getByRole("combobox"), { target: { value: "4" } });
    expect(await screen.findByRole("alert")).toHaveTextContent("Det blev ikke gemt. Prøv igen.");
  });
});
