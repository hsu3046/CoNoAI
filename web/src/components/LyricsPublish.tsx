// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
"use client";
import { useEffect, useMemo, useRef, useState } from "react";
import type { LyricsRecord } from "@/lib/lyrics-record";
import { publishPayload, UNCERTAIN_PUBLICATION, type PublishChallenge } from "@/lib/lrclib-publish";
import { lyricsRequest, LyricsRequestError } from "@/lib/lyrics-client";
import { LyricsDialog } from "./LyricsDialog";
import { scoreButton } from "./ScoreActions";

function solveInWorker(challenge: PublishChallenge, signal: AbortSignal): Promise<string> {
  signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL("../workers/lrclib-pow.ts", import.meta.url), { type: "module" });
    const finish = (error?: Error, token?: string) => {
      worker.terminate(); window.clearTimeout(timer); signal.removeEventListener("abort", cancel);
      if (error) reject(error); else resolve(token!);
    };
    const cancel = () => finish(new DOMException("Cancelled", "AbortError"));
    const timer = window.setTimeout(() => finish(new Error("인증 계산이 2분을 넘어 멈췄어요. 나중에 다시 시도해 주세요.")), 121_000);
    signal.addEventListener("abort", cancel, { once: true });
    worker.onmessage = (event: MessageEvent<{ token?: string; error?: string }>) => {
      if (event.data.token) finish(undefined, event.data.token);
      else finish(new Error(event.data.error || "인증 계산을 마치지 못했어요."));
    };
    worker.onerror = () => finish(new Error("게시 인증 계산을 시작하지 못했어요. 브라우저를 확인해 주세요."));
    worker.postMessage(challenge);
  });
}

export function LyricsPublish({ record, onClose }: { record: LyricsRecord; onClose: () => void }) {
  const [consent, setConsent] = useState(false);
  const [phase, setPhase] = useState<"review" | "preparing" | "solving" | "sending" | "done" | "uncertain">("review");
  const [error, setError] = useState("");
  const [retryAt, setRetryAt] = useState(0);
  const [retrySeconds, setRetrySeconds] = useState(0);
  const active = useRef<AbortController | null>(null);
  const mounted = useRef(true);
  const busy = ["preparing", "solving", "sending"].includes(phase);
  const { preview, validation } = useMemo(() => {
    try { return { preview: publishPayload(record), validation: "" }; }
    catch (error) { return { preview: null, validation: error instanceof Error ? error.message : "공개할 가사를 확인해 주세요." }; }
  }, [record]);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; active.current?.abort(); }; }, []);
  useEffect(() => {
    if (!busy) return;
    const prevent = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = ""; };
    window.addEventListener("beforeunload", prevent);
    return () => window.removeEventListener("beforeunload", prevent);
  }, [busy]);
  useEffect(() => {
    if (!retryAt) return;
    const timer = window.setInterval(() => {
      const remaining = Math.max(0, Math.ceil((retryAt - Date.now()) / 1000));
      setRetrySeconds(remaining);
      if (remaining === 0) window.clearInterval(timer);
    }, 1000);
    return () => window.clearInterval(timer);
  }, [retryAt]);
  const publish = async () => {
    if (!consent || !preview || active.current || retrySeconds > 0) return;
    const controller = new AbortController(); active.current = controller;
    let sent = false;
    setError(""); setPhase("preparing");
    try {
      const base = { id: record.id, version: record.version, consent: true };
      const { challenge } = await lyricsRequest<{ challenge: PublishChallenge }>("/api/lyrics/publish", { ...base, action: "challenge" }, controller.signal);
      controller.signal.throwIfAborted();
      setPhase("solving");
      const token = await solveInWorker(challenge, controller.signal);
      // Worker 완료 후 취소가 도착한 경우에도 POST를 보내지 않는다.
      controller.signal.throwIfAborted();
      setPhase("sending"); sent = true;
      await lyricsRequest("/api/lyrics/publish", { ...base, action: "publish", token }, controller.signal);
      if (mounted.current) setPhase("done");
    } catch (error) {
      if (!mounted.current) return;
      const aborted = controller.signal.aborted || error instanceof DOMException && ["AbortError", "TimeoutError"].includes(error.name);
      const message = error instanceof Error ? error.message : "게시를 마치지 못했어요.";
      if (error instanceof LyricsRequestError && error.status === 429) {
        const seconds = error.retryAfterSeconds ?? 60;
        setRetryAt(Date.now() + seconds * 1000); setRetrySeconds(seconds);
      }
      if (sent && (aborted || !(error instanceof LyricsRequestError) || message === UNCERTAIN_PUBLICATION)) { setPhase("uncertain"); setError(UNCERTAIN_PUBLICATION); }
      else { setPhase("review"); setError(aborted ? "게시를 취소했어요. 개인 가사는 그대로입니다." : message); }
    } finally { active.current = null; }
  };
  return <LyricsDialog title="LRCLIB 공개 전 검토" onClose={onClose} locked={busy}>
    <p className="mt-4 text-sm leading-relaxed text-ink2">개인 보관함과 별개로 <a className="text-sky underline" href="https://lrclib.net" target="_blank" rel="noreferrer">LRCLIB</a>에 누구나 볼 수 있는 사본을 게시합니다. 공개 후 이 보관함에서 지워도 공개본은 지워지지 않습니다.</p>
    <dl className="my-5 grid grid-cols-[5rem_1fr] gap-2 text-sm"><dt className="text-ink2">곡</dt><dd>{record.title}</dd><dt className="text-ink2">가수</dt><dd>{record.artist}</dd><dt className="text-ink2">앨범</dt><dd>{record.album || "미입력"}</dd><dt className="text-ink2">곡 길이</dt><dd>{record.duration === null ? "미입력" : `${record.duration}초`}</dd></dl>
    {preview && <><p className="text-xs text-ink2">전송할 {record.format === "lrc" ? "줄 시각 가사 · 단어 태그는 개인 원본에 유지" : "일반 가사"}</p><pre className="my-3 max-h-60 overflow-auto whitespace-pre-wrap rounded-2xl border border-white/10 bg-black/30 p-4 text-sm">{preview.syncedLyrics || preview.plainLyrics}</pre></>}
    {validation && <p role="alert" className="my-4 text-stop">{validation}</p>}
    {phase === "done" ? <p role="status" className="my-4 text-mint">LRCLIB 공개 전송을 완료했어요. 개인 가사도 그대로 남아 있습니다.</p> : <label className="my-5 flex items-start gap-3 text-sm leading-relaxed"><input type="checkbox" className="mt-1 size-5 accent-mint" checked={consent} disabled={busy || phase === "uncertain"} onChange={(event) => setConsent(event.target.checked)} />공개할 권한이 있는 가사이며, 제목·가수·곡 길이와 내용을 확인했습니다. LRCLIB 공개 게시에 동의합니다.</label>}
    {error && <p role="alert" className="my-4 text-stop">{error}</p>}
    {retrySeconds > 0 && <p role="status" className="my-4 text-gold">서비스 대기시간이 {retrySeconds}초 남았어요. 대기가 끝나도 자동으로 전송하지 않습니다.</p>}
    {busy && <p role="status" className="my-4 text-gold">{phase === "preparing" ? "LRCLIB 인증 요청 중…" : phase === "solving" ? "브라우저에서 게시 인증 계산 중… 최대 2분이 걸릴 수 있어요." : "LRCLIB에 전송 중… 지금 취소하면 게시 여부를 확인하지 못할 수 있어요."}</p>}
    <div className="mt-5 flex flex-wrap justify-end gap-3">
      {busy ? <button className={scoreButton} onClick={() => active.current?.abort()}>게시 취소</button> : <button className={scoreButton} onClick={onClose}>닫기</button>}
      {phase !== "done" && phase !== "uncertain" && <button className={`${scoreButton} border-mint/60 text-mint`} disabled={busy || !consent || !preview || retrySeconds > 0} onClick={() => void publish()}>동의하고 LRCLIB에 공개</button>}
      {phase === "uncertain" && <a className={scoreButton} href="https://lrclib.net" target="_blank" rel="noreferrer">LRCLIB에서 확인</a>}
    </div>
  </LyricsDialog>;
}
