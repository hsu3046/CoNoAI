// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 의견: 메일 한 통으로 (폼·DB 없이)

import { Screen, SectionTitle } from "./Screen";

export const SUPPORT_EMAIL = "support@aib.vote";

export function Feedback() {
  return (
    <Screen id="feedback" glow={{ color: "rgba(255,143,176,0.09)", x: "50%", y: "50%" }}>
      <div className="text-center">
        <p className="text-6xl" style={{ animation: "floaty 4s ease-in-out infinite" }} aria-hidden>
          💌
        </p>
        <div className="mt-6">
          <SectionTitle kicker="FEEDBACK" title="써 보니 어떠세요?">
            불편한 점, 바라는 기능, 칭찬 한 스푼 — 무엇이든 메일로 보내 주세요.
          </SectionTitle>
        </div>
        <a
          href={`mailto:${SUPPORT_EMAIL}?subject=${encodeURIComponent("CoNo 의견")}`}
          className="mt-8 inline-block rounded-full bg-pink px-8 py-4 font-cute text-xl text-night shadow-[0_0_40px_rgba(255,143,176,0.55)] transition hover:scale-105"
        >
          ✉️ {SUPPORT_EMAIL}
        </a>
      </div>
    </Screen>
  );
}
