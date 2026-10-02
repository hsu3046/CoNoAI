// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { acquireLock, LocalStoreError } from "./local-repository.ts";
import { parseLyricsRecord, type LyricsRecord } from "./lyrics-record.ts";
import { object, UUID } from "./score-record.ts";

export type LyricsData = { schemaVersion: 1; lyrics: { ownerId: string; record: LyricsRecord }[] };
const MAX_STORE_BYTES = 32 * 1_048_576;
export class LyricsRepository {
  readonly directory: string;
  constructor(directory: string) { this.directory = directory; }
  async read(): Promise<LyricsData> {
    try {
      const file = path.join(this.directory, "store.json");
      if ((await stat(file)).size > MAX_STORE_BYTES) throw new Error("Store too large");
      const raw = await readFile(file);
      if (raw.byteLength > MAX_STORE_BYTES) throw new Error("Store too large");
      const data = object(JSON.parse(raw.toString("utf8")));
      if (data.schemaVersion !== 1 || !Array.isArray(data.lyrics)) throw new Error("Invalid schema");
      const ids = new Set<string>();
      const lyrics = data.lyrics.map((value) => {
        const entry = object(value), record = parseLyricsRecord(entry.record);
        if (typeof entry.ownerId !== "string" || !UUID.test(entry.ownerId) || ids.has(record.id)) throw new Error("Invalid owner or duplicate ID");
        ids.add(record.id);
        return { ownerId: entry.ownerId, record };
      });
      return { schemaVersion: 1, lyrics };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return { schemaVersion: 1, lyrics: [] };
      throw new LocalStoreError("가사 보관함을 읽지 못했어요. 원본은 보존했습니다. 저장 파일과 권한을 확인해 주세요.");
    }
  }
  async update<T>(change: (data: LyricsData) => T): Promise<T> {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const release = await acquireLock(this.directory);
    const temporary = path.join(this.directory, `.lyrics-${randomUUID()}.tmp`);
    try {
      const data = await this.read();
      const result = change(data);
      const serialized = JSON.stringify(data);
      if (Buffer.byteLength(serialized) > MAX_STORE_BYTES) throw new LocalStoreError("가사 저장소가 가득 찼어요. 파일로 백업한 뒤 정리해 주세요.");
      await writeFile(temporary, serialized, { flag: "wx", mode: 0o600 });
      await rename(temporary, path.join(this.directory, "store.json"));
      return result;
    } finally {
      try { await rm(temporary, { force: true }); } finally { await release(); }
    }
  }
}
export function lyricsRepository(): LyricsRepository {
  if (process.env.VERCEL) throw new LocalStoreError("현재 가사 보관함은 로컬 테스트용이에요. 영구 저장소 연결 후 사용할 수 있어요.");
  const base = path.resolve(/* turbopackIgnore: true */ process.env.CONO_DATA_DIR || path.join(process.cwd(), ".local-data"));
  return new LyricsRepository(path.join(base, "lyrics"));
}
