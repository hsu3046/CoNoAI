// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { repository } from "@/lib/local-repository";
import { failure } from "@/lib/local-http";
import { groupKey, weekKey } from "@/lib/score-record";
export const dynamic = "force-dynamic";
export async function GET() {
  try {
    const data = await repository().read();
    const week = weekKey(new Date());
    const best = new Map<string, (typeof data.scores)[number]>();
    for (const entry of data.scores) {
      if (!entry.published || entry.record.source === "demo" || weekKey(new Date(entry.record.createdAt)) !== week) continue;
      const key = JSON.stringify([entry.ownerId, groupKey(entry.record)]);
      const previous = best.get(key);
      if (!previous || entry.record.score > previous.record.score || (entry.record.score === previous.record.score && entry.record.createdAt < previous.record.createdAt)) best.set(key, entry);
    }
    return Response.json({ week, entries: [...best.values()].map(({ ownerId, record }) => ({ record, nickname: data.profiles[ownerId]?.nickname ?? "나의 무대" })).sort((a, b) => b.record.score - a.record.score || a.record.createdAt.localeCompare(b.record.createdAt)) }, { headers: { "Cache-Control": "no-store" } });
  } catch (error) { return failure(error); }
}
