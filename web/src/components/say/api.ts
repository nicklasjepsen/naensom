import { AiUsage, ParsedMeal } from "@naensom/shared/schemas/ai";
import { ParseAvailability } from "@/ai/parse/contract";
import type { z } from "zod";

class AiRequestError extends Error {
  constructor(readonly status: number) {
    super("ai-unavailable");
  }
}

async function request<T>(
  spaceId: string,
  path: string,
  schema: z.ZodType<T>,
  body?: unknown,
): Promise<T> {
  const response = await fetch(`/api/spaces/${encodeURIComponent(spaceId)}/${path}`, {
    method: body === undefined ? "GET" : "POST",
    credentials: "same-origin",
    headers: { "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  if (!response.ok) throw new AiRequestError(response.status);
  return schema.parse(await response.json());
}
export async function aiUsage(spaceId: string): Promise<{ enabled: boolean }> {
  try {
    return await request(spaceId, "ai", AiUsage);
  } catch (error) {
    if (error instanceof AiRequestError && error.status === 404)
      return request(spaceId, "parse", ParseAvailability);
    throw error;
  }
}
export const parseText = (spaceId: string, text: string) =>
  request(spaceId, "parse", ParsedMeal, { text });
function dataUrl(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return `data:image/jpeg;base64,${btoa(binary)}`;
}
/** A meal photo to a draft: matched foods where lookup finds them, guesses only where not. */
export const photoMeal = (spaceId: string, bytes: Uint8Array) =>
  request(spaceId, "photo-meal", ParsedMeal, { photoDataUrl: dataUrl(bytes) });
