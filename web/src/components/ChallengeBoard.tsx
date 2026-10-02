// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import { requestJSON, type ChallengeResponse } from "@/lib/score-client";
import { groupKey } from "@/lib/score-record";
import { Screen, SectionTitle } from "./Screen";
import { scoreButton } from "./ScoreActions";
export function ChallengeBoard() {
  const [data, setData] = useState<ChallengeResponse | null>(null);
  const [group, setGroup] = useState("");
  const [error, setError] = useState("");
  const generation = useRef(0);
  const load = useCallback(() => {
    const attempt = ++generation.current;
    return requestJSON<ChallengeResponse>("/api/challenges").then((next) => {
      if (attempt === generation.current) { setData(next); setError(""); }
    }).catch((error: unknown) => {
      if (attempt === generation.current) setError(error instanceof Error ? error.message : "순위를 불러오지 못했어요.");
    });
  }, []);
  useEffect(() => {
    const requests = generation;
    void load(); const changed = () => void load();
    window.addEventListener("cono-scores-changed", changed); window.addEventListener("focus", changed);
    return () => { requests.current++; window.removeEventListener("cono-scores-changed", changed); window.removeEventListener("focus", changed); };
  }, [load]);
  const groups = [...new Map(data?.entries.map(({ record }) => [groupKey(record), record])).entries()];
  const active = groups.some(([key]) => key === group) ? group : groups[0]?.[0];
  const rows = data?.entries.filter(({ record }) => groupKey(record) === active) ?? [];
  return <Screen id="challenge" glow={{ color: "rgba(255,204,92,0.09)", x: "75%", y: "50%" }}>
    <SectionTitle kicker="WEEKLY CHALLENGE" title="이번 주, 우리 집 가왕은?">한 곡 부르고 ‘나의 기록’에서 챌린지에 공개해 보세요. 같은 곡·난이도·채점 방식의 개인 최고 기록으로 겨뤄요.</SectionTitle>
    <div className="mx-auto mt-8 max-w-3xl rounded-3xl border border-gold/25 bg-gold/5 p-6">
      <p className="text-center text-sm text-ink2">로컬 테스트 순위 · {data?.week ?? "…"} 주간 · 월요일 00:00(한국 시간) 시작 · 동점은 같은 순위</p>
      <div className="my-5 flex flex-wrap justify-center gap-2" aria-label="챌린지 곡">
        {groups.map(([key, record]) => <button key={key} className={`${scoreButton} ${active === key ? "border-gold text-gold" : ""}`} aria-pressed={active === key} onClick={() => setGroup(key)}>{record.title} · {record.source === "macos" ? "Mac" : "웹"} · {record.difficulty === "hard" ? "어려움" : "보통"}</button>)}
      </div>
      {error && <p role="alert" className="text-stop">{error}</p>}
      {!data && !error && <p role="status">순위를 읽는 중…</p>}
      {data && !rows.length && <p className="py-10 text-center text-ink2">아직 공개된 기록이 없어요. 이번 주의 첫 주인공이 되어 보세요.</p>}
      <ol className="max-h-[440px] space-y-2 overflow-y-auto overscroll-contain">
        {rows.map(({ nickname, record }, index) => {
          const rank = rows.findIndex((v) => v.record.score === record.score) + 1;
          return <li key={record.id}><a href={`/scores/${record.id}`} className="flex items-center justify-between gap-3 rounded-xl bg-black/30 p-4 hover:bg-white/10"><span className="min-w-0 truncate"><span className="mr-3 text-gold">{rank <= 3 ? ["🥇", "🥈", "🥉"][rank - 1] : rank}</span>{nickname}</span><span className="font-display text-2xl text-gold">{record.score}<span className="sr-only">점, {index + 1}번째 기록</span></span></a></li>;
        })}
      </ol>
      <div className="mt-6 flex justify-center gap-3"><a href="#try" className={`${scoreButton} text-pink`}>도전하기</a><a href="#records" className={scoreButton}>내 기록 올리기</a><button className={scoreButton} onClick={() => void load()}>순위 새로고침</button></div>
      <p className="mt-4 text-center text-xs text-faint">가져온 점수는 사용자 제공 기록입니다. 공개를 해제하면 순위와 공유 페이지에서도 내려갑니다.</p>
    </div>
  </Screen>;
}
