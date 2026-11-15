import { app } from "@azure/functions";

import { createWebWarmHandler, WEB_WARM_SCHEDULE } from "../web-warm-handler";

// Keeps the web app's server and its database connection warm between uses (web-warm-handler.ts).
// Read at run time, so a missing setting means no keep-warm and never a failed startup.
app.timer("web-warm", {
  schedule: WEB_WARM_SCHEDULE,
  runOnStartup: false,
  handler: () => createWebWarmHandler({ url: process.env.WEB_HEALTH_URL })(),
});
