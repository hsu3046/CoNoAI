// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { mkdir, readFile, readdir, rename, rm, rmdir, stat, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { hostname } from "node:os";
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

function errorCode(error: unknown): string | undefined { return (error as NodeJS.ErrnoException).code; }

/** 토큰 파일을 지운 작성자만 빈 폴더를 정리한다. 다른 작성자의 새 잠금은 지우지 않는다. */
async function releaseLock(lock: string, ownerFile: string): Promise<void> {
  try { await unlink(path.join(lock, ownerFile)); }
  catch (error) { if (errorCode(error) === "ENOENT") return; throw error; }
  try { await rmdir(lock); }
  catch (error) { if (!["ENOENT", "EEXIST", "ENOTEMPTY"].includes(errorCode(error) ?? "")) throw error; }
}

async function reclaimTerminatedWriter(lock: string): Promise<void> {
  let ownerFile: string;
  let owner: Record<string, unknown>;
  try {
    const files = await readdir(lock);
    if (files.length !== 1 || !/^owner-[0-9a-f-]{36}\.json$/.test(files[0])) return;
    ownerFile = files[0];
    owner = object(JSON.parse(await readFile(path.join(lock, ownerFile), "utf8")));
  } catch { return; }
  if (owner.version !== 1 || owner.host !== hostname() || typeof owner.pid !== "number" || !Number.isInteger(owner.pid) || owner.pid <= 0 || ownerFile !== `owner-${owner.token}.json`) return;
  try { process.kill(owner.pid, 0); return; }
  catch (error) { if (errorCode(error) !== "ESRCH") return; }
  // PID가 사라진 경우만 회수한다. 경과 시간만으로 느린/정지된 작성자를 빼앗지 않는다.
  await releaseLock(lock, ownerFile);
}

export async function acquireLock(directory: string): Promise<() => Promise<void>> {
  // 구버전의 빈 잠금에는 소유자 정보가 없다. 실행 중인 구버전 서버일 수도 있어 자동 삭제하지 않는다.
  try {
    await stat(path.join(directory, ".write-lock"));
    throw new LocalStoreError("이전 버전의 저장 잠금이 남아 있어요. 서버를 모두 종료하고 백업한 뒤 .write-lock 폴더를 확인해 주세요.");
  } catch (error) { if (errorCode(error) !== "ENOENT") throw error; }
  const token = randomUUID();
  const ownerFile = `owner-${token}.json`;
  const claim = path.join(directory, `.write-claim-${token}`);
  const lock = path.join(directory, ".write-lock-v2");
  await mkdir(claim, { mode: 0o700 });
  try {
    await writeFile(path.join(claim, ownerFile), JSON.stringify({ version: 1, host: hostname(), pid: process.pid, token }), { flag: "wx", mode: 0o600 });
    for (let attempt = 0; attempt < 100; attempt++) {
      try {
        // 완성된 소유자 파일이 있는 폴더를 원자적으로 설치한다. 빈 상태로 죽는 초기화 구간이 없다.
        // 다른 작성자의 비어 있지 않은 폴더는 rename이 거부한다. 해제 중인 빈 폴더는 교체 가능하다.
        await rename(claim, lock);
        return () => releaseLock(lock, ownerFile);
      } catch (error) {
        if (!["EEXIST", "ENOTEMPTY"].includes(errorCode(error) ?? "")) throw error;
        await reclaimTerminatedWriter(lock);
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
    }
    throw new LocalStoreError("다른 저장 작업이 진행 중이거나 잠금 소유자를 확인할 수 없어요. 잠시 뒤 다시 시도해 주세요.");
  } finally {
    // 이미 설치한 잠금은 claim 경로에 없으므로 다른 작성자를 건드리지 않는다.
    await rm(claim, { recursive: true, force: true });
  }
}
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
    const release = await acquireLock(this.directory);
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
      await release();
    }
  }
}
export function repository(): ScoreRepository {
  if (process.env.VERCEL) throw new LocalStoreError("현재 기능은 로컬 테스트용이에요. 영구 저장소 연결 후 사용할 수 있어요.");
  return new JsonRepository(path.resolve(/* turbopackIgnore: true */ process.env.CONO_DATA_DIR || path.join(process.cwd(), ".local-data")));
}
