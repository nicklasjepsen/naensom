import type { ProbeResult } from "../schemas/glucose";
import type { PumpBolus, PumpChange } from "../schemas/pump";

/**
 * The only thing the rest of the app knows about a pump record (v0.7.0 plan §5). Read-only, like
 * `GlucoseSource`: an adapter fetches what the pump delivered and never sends anything back.
 * Adapters: `NightscoutPumpSource` (tconnectsync's Combo Bolus treatments); a file import or
 * another uploader later is another implementation. The cycle knows this interface, not Nightscout.
 */
export interface PumpSource {
  /** Boluses recorded at or after `since`, oldest first, each with its `ts` and its units. */
  fetchBolusesSince(since: Date): Promise<PumpBolus[]>;
  /**
   * Reservoir and infusion-set fills recorded at or after `since`, oldest first. Optional: an
   * adapter whose record has no such events leaves it out and the countdown stays empty.
   */
  fetchChangesSince?(since: Date): Promise<PumpChange[]>;
  /** Checks the credential without storing anything. */
  probe(): Promise<ProbeResult>;
}
