// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { parseRecord, type ScoreRecord } from "./score-record.ts";

export const PENDING_SCORE_PREFIX = "cono-pending-score-v1:";
export const PENDING_SCORES_CHANGED = "cono-pending-scores-changed";
export type PendingScores = { records: ScoreRecord[]; warning: string };
type PendingStorage = Pick<Storage, "length" | "key" | "getItem" | "setItem" | "removeItem">;

/** 기록별 키를 써서 다른 탭의 새 점수를 읽기/쓰기 경쟁으로 덮어쓰지 않는다. */
export class PendingScoreStore {
  private readonly storage: () => PendingStorage;
  private readonly memory = new Map<string, ScoreRecord>();

  constructor(storage: () => PendingStorage) { this.storage = storage; }

  remember(value: ScoreRecord): string {
    const record = parseRecord(value);
    this.memory.set(record.id, record);
    try {
      const storage = this.storage();
      const key = PENDING_SCORE_PREFIX + record.id;
      const existing = storage.getItem(key);
      // 손상되었거나 같은 ID의 다른 원본이면 사용자의 파일을 대체하지 않는다.
      if (existing !== null && JSON.stringify(parseRecord(JSON.parse(existing))) !== JSON.stringify(record)) throw new Error("conflict");
      storage.setItem(key, JSON.stringify(record));
      this.memory.delete(record.id);
      return "";
    } catch {
      return "브라우저에 임시 보관하지 못했어요. 이 창을 떠나기 전에 JSON으로 내보내 주세요.";
    }
  }

  read(): PendingScores {
    const records = new Map<string, ScoreRecord>();
    let warning = "";
    try {
      const storage = this.storage();
      for (let index = 0; index < storage.length; index++) {
        const key = storage.key(index);
        if (!key?.startsWith(PENDING_SCORE_PREFIX)) continue;
        try {
          const source = storage.getItem(key);
          if (source === null) continue;
          const record = parseRecord(JSON.parse(source));
          if (key !== PENDING_SCORE_PREFIX + record.id) throw new Error("id");
          records.set(record.id, record);
        } catch {
          warning = "읽지 못한 임시 기록이 있어요. 원본은 브라우저에 그대로 보존했습니다.";
        }
      }
    } catch {
      warning = "브라우저 임시 저장소에 접근하지 못했어요. 이 창의 점수는 JSON으로 백업해 주세요.";
    }
    for (const record of this.memory.values()) records.set(record.id, record);
    if (this.memory.size) warning = [warning, "임시 저장에 실패한 점수는 이 창에서만 보관 중이에요. 새로고침하거나 닫기 전에 JSON으로 내보내 주세요."].filter(Boolean).join(" ");
    return { records: [...records.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt)), warning };
  }

  forget(id: string): string {
    try {
      this.storage().removeItem(PENDING_SCORE_PREFIX + id);
      this.memory.delete(id);
      return "";
    } catch {
      return "브라우저의 임시 기록을 정리하지 못했어요. 다시 시도해 주세요.";
    }
  }
}

const pending = new PendingScoreStore(() => window.localStorage);
export const readPendingScores = () => pending.read();
export function rememberPendingScore(record: ScoreRecord): string {
  const warning = pending.remember(record);
  window.dispatchEvent(new Event(PENDING_SCORES_CHANGED));
  return warning;
}
export function forgetPendingScore(id: string): string {
  const warning = pending.forget(id);
  window.dispatchEvent(new Event(PENDING_SCORES_CHANGED));
  return warning;
}
