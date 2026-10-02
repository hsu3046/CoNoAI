// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
"use client";
import { useCallback, useEffect, useState } from "react";
import { changeScores } from "@/lib/score-client";
import type { ScoreRecord } from "@/lib/score-record";
import { ScoreActions, scoreButton } from "./ScoreActions";
export function ResultRecordActions({ record }: { record: ScoreRecord }) {
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState("");
  const save = useCallback(() => {
    return changeScores({ action: "save", record }).then(() => { setSaved(true); setError(""); })
      .catch((error: unknown) => { setError(error instanceof Error ? error.message : "저장하지 못했어요."); });
  }, [record]);
  useEffect(() => { void save(); }, [save]);
  return <><p className="mb-3 text-sm text-ink2" role="status">{saved ? "나의 기록에 저장했어요." : error || "기록을 저장하는 중…"}</p>{error && <button className={scoreButton} onClick={() => void save()}>저장 다시 시도</button>}<ScoreActions record={record} /><a href="#records" className="text-sm text-mint">닫은 뒤 ‘나의 기록’에서 챌린지에 공개할 수 있어요.</a></>;
}
