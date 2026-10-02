// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
"use client";
import { useState } from "react";
import { changeScores, exportScores, saveScoreImage, shareRecord } from "@/lib/score-client";
import type { ScoreRecord } from "@/lib/score-record";
export const scoreButton = "rounded-full border border-white/20 bg-white/5 px-4 py-2 text-sm transition hover:border-pink disabled:opacity-50";

export function ScoreActions({ record, published = false, canPublish = false }: { record: ScoreRecord; published?: boolean; canPublish?: boolean }) {
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const perform = async (work: () => Promise<string | void>) => {
    if (busy) return;
    setBusy(true); setNotice("");
    try { setNotice((await work()) || ""); }
    catch (error) { setNotice(error instanceof Error ? error.message : "처리하지 못했어요. 다시 시도해 주세요."); }
    finally { setBusy(false); }
  };
  return <div>
    <div className="flex flex-wrap justify-center gap-2">
      <button className={scoreButton} disabled={busy} onClick={() => void perform(() => shareRecord(record, published ? `${location.origin}/scores/${record.id}` : undefined))}>점수 공유</button>
      <button className={scoreButton} disabled={busy} onClick={() => void perform(async () => { await saveScoreImage(record); return "점수 이미지를 저장했어요."; })}>이미지 저장</button>
      <button className={scoreButton} disabled={busy} onClick={() => void perform(async () => { exportScores([record]); return "점수 JSON을 내보냈어요."; })}>JSON 내보내기</button>
      {canPublish && record.source !== "demo" && <button className={`${scoreButton} text-gold`} disabled={busy} onClick={() => void perform(async () => {
        await changeScores({ action: "publish", id: record.id, published: !published });
        return published ? "공유를 해제했어요." : "공유 페이지와 이번 주 챌린지에 공개했어요.";
      })}>{published ? "공유 해제" : "챌린지에 공개"}</button>}
    </div>
    <p role="status" className="mt-2 min-h-5 text-center text-sm text-mint">{busy ? "처리 중…" : notice}</p>
  </div>;
}
