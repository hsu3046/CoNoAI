// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import { changeScores, exportScores, requestJSON, type HistoryResponse } from "@/lib/score-client";
import { MAX_ARCHIVE_BYTES, parseDocument } from "@/lib/score-record";
import { forgetPendingScore, PENDING_SCORE_PREFIX, PENDING_SCORES_CHANGED, readPendingScores, type PendingScores } from "@/lib/pending-scores";
import { Screen, SectionTitle } from "./Screen";
import { ScoreActions, scoreButton } from "./ScoreActions";

export function ScoreLibrary() {
  const [data, setData] = useState<HistoryResponse | null>(null);
  const [nickname, setNickname] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [query, setQuery] = useState("");
  const [pendingDelete, setPendingDelete] = useState<string | null>(null);
  const [pending, setPending] = useState<PendingScores>({ records: [], warning: "" });
  const [pendingDiscard, setPendingDiscard] = useState<string | null>(null);
  const generation = useRef(0);
  const loaded = useRef(false);
  const reload = useCallback(() => {
    const attempt = ++generation.current;
    return requestJSON<HistoryResponse>("/api/scores").then((next) => {
      if (attempt !== generation.current) return;
      setData(next); setError("");
      if (!loaded.current) { setNickname(next.nickname); loaded.current = true; }
    }).catch((error: unknown) => {
      if (attempt === generation.current) setError(error instanceof Error ? error.message : "기록을 읽지 못했어요.");
    });
  }, []);
  useEffect(() => {
    const requests = generation;
    void reload();
    const changed = () => void reload();
    window.addEventListener("cono-scores-changed", changed);
    return () => { requests.current++; window.removeEventListener("cono-scores-changed", changed); };
  }, [reload]);
  useEffect(() => {
    const changed = () => setPending(readPendingScores());
    const storage = (event: StorageEvent) => { if (event.key === null || event.key.startsWith(PENDING_SCORE_PREFIX)) changed(); };
    changed();
    window.addEventListener(PENDING_SCORES_CHANGED, changed);
    window.addEventListener("storage", storage);
    return () => { window.removeEventListener(PENDING_SCORES_CHANGED, changed); window.removeEventListener("storage", storage); };
  }, []);
  const perform = async (work: () => Promise<void>) => {
    setBusy(true); setError("");
    try { await work(); await reload(); } catch (error) { setError(error instanceof Error ? error.message : "처리하지 못했어요."); }
    finally { setBusy(false); }
  };
  const records = data?.records.filter((record) => `${record.title} ${record.artist}`.toLowerCase().includes(query.toLowerCase())) ?? [];
  return <Screen id="records" glow={{ color: "rgba(94,224,184,0.08)", x: "30%", y: "40%" }}>
    <SectionTitle kicker="MY STAGE" title="한 곡 한 곡, 나의 기록">브라우저 체험을 마치면 자동 저장됩니다. Mac 앱의 ‘노래 기록’에서 내보낸 JSON도 가져올 수 있어요.</SectionTitle>
    <div className="mx-auto mt-8 max-w-4xl space-y-5">
      <p className="text-center text-sm text-ink2">로컬 테스트 · 기록은 이 서버의 JSON에 저장돼요. 쿠키를 지우기 전 JSON으로 백업하세요.</p>
      {pending.warning && <p role="alert" className="text-center text-stop">{pending.warning}</p>}
      {pending.records.length > 0 && <section aria-label="저장 대기 중인 기록" className="space-y-4 rounded-3xl border border-gold/30 p-5">
        <h3 className="font-cute text-2xl text-gold">저장 대기 {pending.records.length}곡</h3>
        <p className="text-sm text-ink2">아직 서버 저장이 확인되지 않은 점수예요. 브라우저 데이터를 지우기 전에 다시 저장하거나 JSON으로 내보내 주세요. 공개하려면 서버에 저장한 뒤 선택해 주세요.</p>
        {pending.records.map((record) => <article key={record.id} className="rounded-2xl border border-white/10 p-4">
          <h4 className="mb-3 font-cute text-xl">{record.title} · {record.score}점</h4>
          <ScoreActions record={record} />
          <div className="mt-3 flex flex-wrap justify-center gap-3 text-sm">
            <button className={scoreButton} disabled={busy} onClick={() => void perform(async () => {
              // 쿠키가 바뀌거나 앞 요청이 뒤늦게 성공했어도 비공개 사본으로 안전하게 복구한다.
              await changeScores({ action: "import", document: { schemaVersion: 1, records: [record] } });
              const warning = forgetPendingScore(record.id);
              if (warning) throw new Error(warning);
            })}>다시 저장</button>
            {pendingDiscard === record.id ? <><span>임시 기록을 삭제할까요?</span><button disabled={busy} onClick={() => { setError(forgetPendingScore(record.id)); setPendingDiscard(null); }}>삭제 확인</button><button onClick={() => setPendingDiscard(null)}>취소</button></> : <button disabled={busy} onClick={() => setPendingDiscard(record.id)}>임시 기록 삭제</button>}
          </div>
        </article>)}
      </section>}
      <form className="flex flex-wrap justify-center gap-2" onSubmit={(event) => { event.preventDefault(); void perform(() => changeScores({ action: "profile", nickname })); }}>
        <label className="flex items-center gap-2">닉네임<input className="w-40 rounded-xl border border-white/20 bg-black/30 p-2 text-base" value={nickname} disabled={!data} maxLength={24} onChange={(e) => setNickname(e.target.value)} /></label>
        <button className={scoreButton} disabled={busy || !data}>닉네임 저장</button>
      </form>
      <div className="flex flex-wrap justify-center gap-2">
        <label className={`${scoreButton} cursor-pointer`}>JSON 가져오기<input aria-label="점수 JSON 가져오기" className="sr-only" type="file" accept=".json,application/json" disabled={busy || !data} onChange={(event) => {
          const file = event.target.files?.[0]; event.target.value = "";
          if (file) void perform(async () => {
            if (file.size > MAX_ARCHIVE_BYTES) throw new Error("파일은 1 MB까지 가져올 수 있어요.");
            const document = parseDocument(JSON.parse(await file.text()));
            await changeScores({ action: "import", document });
          });
        }} /></label>
        <button className={scoreButton} disabled={!data?.records.length} onClick={() => {
          try { if (data) exportScores(data.records); }
          catch (error) { setError(error instanceof Error ? error.message : "백업을 만들지 못했어요."); }
        }}>전체 JSON 내보내기</button>
        <button className={scoreButton} disabled={busy} onClick={() => void reload()}>새로고침</button>
      </div>
      {error && <p role="alert" className="text-center text-stop">{error}</p>}
      {!data && !error && <p role="status" className="text-center">기록을 읽는 중…</p>}
      {data && <>
        <div className="flex flex-wrap items-center justify-between gap-4 text-ink2"><p>{data.records.length}곡 · 최고 {data.records.length ? Math.max(...data.records.map((r) => r.score)) : "—"}점</p><input aria-label="곡 검색" placeholder="곡·가수 검색" className="rounded-xl border border-white/15 bg-black/30 p-3 text-base" value={query} onChange={(e) => setQuery(e.target.value)} /></div>
        {!records.length && <p className="rounded-3xl border border-dashed border-white/20 p-10 text-center text-ink2">{query ? "검색한 곡이 없어요." : "첫 무대를 기다리고 있어요."} <a className="text-mint underline" href="#try">한 곡 부르러 가기</a></p>}
        <div className="max-h-[620px] space-y-4 overflow-y-auto overscroll-contain">
          {records.map((record) => <article key={record.id} className="rounded-3xl border border-white/10 bg-white/[0.03] p-5">
            <div className="mb-4 flex items-start justify-between gap-4"><div><h3 className="font-cute text-2xl">{record.title}</h3><p className="text-sm text-ink2">{record.artist} · {record.source === "macos" ? "Mac" : record.source === "demo" ? "데모" : "브라우저"} · {record.difficulty === "hard" ? "어려움" : "보통"} · {new Date(record.createdAt).toLocaleDateString("ko-KR")}</p></div><strong className="font-display text-4xl text-gold">{record.score}<small className="text-base">점</small></strong></div>
            <ScoreActions record={record} published={record.published} canPublish />
            <div className="flex justify-end gap-3 text-sm text-faint">{record.published && <a href={`/scores/${record.id}`} className="text-mint underline">공유 페이지</a>}{pendingDelete === record.id ? <><span>이 기록을 삭제할까요?</span><button disabled={busy} onClick={() => void perform(async () => { await changeScores({ action: "delete", id: record.id }); setPendingDelete(null); })}>삭제 확인</button><button onClick={() => setPendingDelete(null)}>취소</button></> : <button onClick={() => setPendingDelete(record.id)}>기록 삭제</button>}</div>
          </article>)}
        </div>
      </>}
    </div>
  </Screen>;
}
