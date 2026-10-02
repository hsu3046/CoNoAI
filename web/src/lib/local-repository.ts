// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { object, parseRecord, type ScoreRecord } from "./score-record.ts";
export type SavedScore = { ownerId: string; record: ScoreRecord; published: boolean };
export type LocalData = {
  schemaVersion: 1;
  profiles: Record<string, { nickname: string }>;
  scores: SavedScore[];
  feedback: { id: string; createdAt: string; ownerId: string; mood: number | null; message: string; email: string }[];
};
// 영구 저장 구현의 경계. DB 연결 시 이 계약의 구현만 교체한다.
export interface ScoreRepository { read(): Promise<LocalData>; update<T>(change: (data: LocalData) => T): Promise<T> }
export class LocalStoreError extends Error {}
function validate(value: unknown): LocalData {
  const v = object(value);
  if (v.schemaVersion !== 1 || !Array.isArray(v.scores) || !Array.isArray(v.feedback)) throw new Error("Invalid store version");
  for (const profile of Object.values(object(v.profiles))) if (typeof object(profile).nickname !== "string") throw new Error("Invalid profile");
  for (const score of v.scores) {
    const entry = object(score);
    if (typeof entry.ownerId !== "string" || typeof entry.published !== "boolean") throw new Error("Invalid owner");
    parseRecord(entry.record);
  }
  for (const feedback of v.feedback) {
    const entry = object(feedback);
    if (typeof entry.ownerId !== "string" || typeof entry.createdAt !== "string" || typeof entry.message !== "string") throw new Error("Invalid feedback");
  }
  return value as LocalData;
}
export class JsonRepository implements ScoreRepository {
  private readonly directory: string;
  constructor(directory: string) { this.directory = directory; }
  async read(): Promise<LocalData> {
    try {
      const file = path.join(this.directory, "store.json");
      if ((await stat(file)).size > 32 * 1024 * 1024) throw new Error("Store too large");
      return validate(JSON.parse(await readFile(file, "utf8")));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return { schemaVersion: 1, profiles: {}, scores: [], feedback: [] };
      throw new LocalStoreError("로컬 저장 파일을 읽지 못했어요. 원본은 보존했습니다. 파일 권한과 JSON을 확인해 주세요.");
    }
  }
  async update<T>(change: (data: LocalData) => T): Promise<T> {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const lock = path.join(this.directory, ".write-lock");
    // 여러 서버 프로세스 사이에서도 원자적인 잠금. 손상/잠금을 무시하고 덮어쓰지 않는다.
    let acquired = false;
    for (let attempt = 0; attempt < 100; attempt++) {
      try { await mkdir(lock); acquired = true; break; }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
    }
    if (!acquired) throw new LocalStoreError("다른 저장 작업이 진행 중이에요. 잠시 뒤 다시 시도해 주세요.");
    const temporary = path.join(this.directory, `.store-${randomUUID()}.tmp`);
    try {
      const data = await this.read();
      const result = change(data);
      const serialized = JSON.stringify(data, null, 2);
      if (Buffer.byteLength(serialized) > 32 * 1024 * 1024) throw new LocalStoreError("로컬 저장소가 가득 찼어요. 기록을 백업하고 정리해 주세요.");
      await writeFile(temporary, serialized, { flag: "wx", mode: 0o600 });
      await rename(temporary, path.join(this.directory, "store.json"));
      return result;
    } finally {
      await rm(temporary, { force: true });
      await rm(lock, { recursive: true });
    }
  }
}
export function repository(): ScoreRepository {
  if (process.env.VERCEL) throw new LocalStoreError("현재 기능은 로컬 테스트용이에요. 영구 저장소 연결 후 사용할 수 있어요.");
  return new JsonRepository(path.resolve(/* turbopackIgnore: true */ process.env.CONO_DATA_DIR || path.join(process.cwd(), ".local-data")));
}
