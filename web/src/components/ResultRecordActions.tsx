// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
"use client";
import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import { changeScores } from "@/lib/score-client";
import { forgetPendingScore, rememberPendingScore } from "@/lib/pending-scores";
import type { ScoreRecord } from "@/lib/score-record";
import { ScoreActions, scoreButton } from "./ScoreActions";
export function ResultRecordActions({ record, onViewRecords }: { record: ScoreRecord; onViewRecords: () => void }) {
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(true);
  const saving = useRef(false);
  const save = useCallback(() => {
    if (saving.current) return;
    saving.current = true;
    const warning = rememberPendingScore(record);
    return changeScores({ action: "save", record }).then(() => {
      setSaved(true); setError(forgetPendingScore(record.id));
    }).catch((error: unknown) => {
      setError(`${error instanceof Error ? error.message : "저장하지 못했어요."} ${warning || "임시 기록은 이 브라우저에 남아 있어요. ‘나의 기록’에서 다시 저장할 수 있어요."}`);
    }).finally(() => { saving.current = false; setBusy(false); });
  }, [record]);
  useEffect(() => { void save(); }, [save]);
  return <><p className="mb-3 text-sm text-ink2" role="status">{error || (saved ? "나의 기록에 저장했어요." : "기록을 저장하는 중…")}</p>{error && <button disabled={busy} className={scoreButton} onClick={() => { setBusy(true); setError(""); void save(); }}>{busy ? "저장 중…" : "저장 다시 시도"}</button>}<ScoreActions record={record} /><Link href="/#records" onClick={onViewRecords} className="text-sm text-mint">나의 기록에서 확인하기 →</Link></>;
}
