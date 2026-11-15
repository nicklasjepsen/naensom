import { cookies } from "next/headers";
import { after } from "next/server";
import {
  emit as defaultEmit,
  HttpError,
  log,
  prisma,
  SessionContext,
  type EmitFn,
  type PrismaClient,
  type Role,
} from "@naensom/shared";

export const SESSION_COOKIE = "frejsi_session";
/** 90 days, as the cookie's Max-Age (plan §6). */
export const SESSION_MAX_AGE_SECONDS = 90 * 24 * 60 * 60;
const TOUCH_INTERVAL_MS = 60 * 60 * 1000;

/** The Prisma delegates the session helpers use; tests pass a fake. */
export type SessionDb = Pick<PrismaClient, "session" | "user" | "membership">;

export interface SessionDeps {
  db?: SessionDb;
  emit?: EmitFn;
  now?: () => Date;
  /** Runs the hourly touch off the request's path; tests pass one they can await. */
  defer?: (task: () => Promise<void>) => void;
}

/**
 * After the response has gone, through Next's `after()`. Outside a request scope (a script, a
 * test without its own `defer`) `after()` throws, and the task simply runs without being awaited.
 */
export function afterResponse(task: () => Promise<void>): void {
  try {
    after(task);
  } catch {
    void task();
  }
}

/** Sessions whose touch is running in this process, so parallel requests do not touch twice. */
const touching = new Set<string>();

/**
 * Loads the session row and its user with memberships (plan §6). Returns null for an unknown or
 * expired session. `Session.lastSeenAt` and `User.lastSeen` are touched at most once per hour,
 * after the response (`deps.defer`); People shows `lastSeen` as "Sidst set", so that touch is a
 * member write and emits `member.updated` to every space of the user. The session row itself is
 * device bookkeeping.
 */
export async function loadSession(
  sessionId: string,
  deps: SessionDeps = {},
): Promise<SessionContext | null> {
  const db = deps.db ?? prisma;
  const emit = deps.emit ?? defaultEmit;
  const now = deps.now ?? (() => new Date());
  const at = now();

  // Three single-table reads at once, so the check costs one round trip to the database and not
  // three: an `include` of the user and the memberships is sent as three queries one after another
  // on SQL Server, and every API call starts here. The user and the memberships are found through
  // the session id, so all three describe the same session.
  const bySession = { sessions: { some: { id: sessionId } } };
  const [row, user, memberships] = await Promise.all([
    db.session.findUnique({
      where: { id: sessionId },
      select: { id: true, userId: true, expiresAt: true, lastSeenAt: true },
    }),
    db.user.findFirst({
      where: bySession,
      select: {
        id: true,
        name: true,
        simpleMode: true,
        accent: true,
        theme: true,
        locale: true,
      },
    }),
    db.membership.findMany({ where: { user: bySession }, select: { spaceId: true, role: true } }),
  ]);
  if (!row || user?.id !== row.userId) return null;
  if (row.expiresAt.getTime() <= at.getTime()) return null;

  if (at.getTime() - row.lastSeenAt.getTime() >= TOUCH_INTERVAL_MS && !touching.has(row.id)) {
    // The touch is bookkeeping (two writes and an event per space, each a round trip to the
    // database), and it falls on the first request after an hour away, which is the one that
    // opens the app. It runs after the response so that request is not kept waiting for it.
    touching.add(row.id);
    const spaceIds = memberships.map((m) => m.spaceId);
    (deps.defer ?? afterResponse)(async () => {
      try {
        await Promise.all([
          db.session.update({ where: { id: row.id }, data: { lastSeenAt: at } }),
          db.user.update({ where: { id: row.userId }, data: { lastSeen: at } }),
        ]);
        await Promise.all(
          spaceIds.map((spaceId) => emit(spaceId, "member.updated", { userId: row.userId })),
        );
      } catch (error) {
        log.warn("session.touch-failed", {
          userId: row.userId,
          code: error instanceof Error ? error.name : "unknown",
        });
      } finally {
        touching.delete(row.id);
      }
    });
  }

  return SessionContext.parse({
    userId: user.id,
    name: user.name,
    simpleMode: user.simpleMode,
    accent: user.accent,
    theme: user.theme,
    locale: user.locale,
    memberships: memberships.map((m) => ({ spaceId: m.spaceId, role: m.role })),
  });
}

/** The session behind the `frejsi_session` cookie of the current request, or null. */
export async function getSession(deps: SessionDeps = {}): Promise<SessionContext | null> {
  const store = await cookies();
  const id = store.get(SESSION_COOKIE)?.value;
  if (!id) return null;
  return loadSession(id, deps);
}

/**
 * The membership of `session` in `spaceId` when its role is one of `roles` (any role when none
 * are given). Throws 404 for a non-member so space ids do not leak, 403 for an insufficient role
 * and for a missing session.
 */
export function assertRole(
  session: SessionContext | null,
  spaceId: string,
  ...roles: Role[]
): { session: SessionContext; role: Role } {
  if (!session) throw new HttpError(403, "forbidden");
  const membership = session.memberships.find((m) => m.spaceId === spaceId);
  if (!membership) throw new HttpError(404, "not-found");
  if (roles.length > 0 && !roles.includes(membership.role)) {
    throw new HttpError(403, "forbidden");
  }
  return { session, role: membership.role };
}

/** `assertRole` over the current request's session. Every API route calls this, not the UI. */
export async function requireRole(
  spaceId: string,
  ...roles: Role[]
): Promise<{ session: SessionContext; role: Role }>;
export async function requireRole(
  spaceId: string,
  deps: SessionDeps,
  ...roles: Role[]
): Promise<{ session: SessionContext; role: Role }>;
export async function requireRole(
  spaceId: string,
  depsOrRole: SessionDeps | Role = {},
  ...roles: Role[]
): Promise<{ session: SessionContext; role: Role }> {
  // Keep the caller's clock through the cookie lookup and expiry check, as requireSpaceRole does.
  const deps = typeof depsOrRole === "string" ? {} : depsOrRole;
  const allowedRoles = typeof depsOrRole === "string" ? [depsOrRole, ...roles] : roles;
  return assertRole(await getSession(deps), spaceId, ...allowedRoles);
}
