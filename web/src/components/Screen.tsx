// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 한 화면 = 한 섹션: 화면 높이에 맞추고 스크롤이 섹션 시작에 착 걸린다 (globals.css 의 scroll-snap).
// 넓은 화면에서는 좌우를 나눠 쓰고, 좁은 화면에서는 위아래로 쌓인다.

import type { ReactNode } from "react";

/** 헤더·섹션·스토리가 함께 쓰는 폭과 좌우 여백 (왼쪽 끝이 로고와 한 줄로 맞는다) */
export const CONTAINER = "mx-auto w-full max-w-[1280px] px-5 sm:px-8 lg:px-12";

export function Screen({
  id,
  children,
  glow,
  className = "",
  innerRef,
}: {
  id?: string;
  children: ReactNode;
  /** 섹션마다 다른 색의 은은한 번짐 */
  glow?: { color: string; x: string; y: string };
  className?: string;
  innerRef?: React.Ref<HTMLElement>;
}) {
  return (
    <section
      id={id}
      ref={innerRef}
      className={`relative isolate flex min-h-dvh snap-start flex-col justify-center pb-10 pt-24 ${className}`}
    >
      {glow && (
        <div
          className="pointer-events-none absolute inset-0 -z-10"
          aria-hidden
          style={{ background: `radial-gradient(ellipse 55% 45% at ${glow.x} ${glow.y}, ${glow.color}, transparent 70%)` }}
        />
      )}
      <div className={CONTAINER}>{children}</div>
    </section>
  );
}

export function SectionTitle({ kicker, title, align = "center", children }: { kicker: string; title: string; align?: "center" | "left"; children?: ReactNode }) {
  return (
    <div className={align === "center" ? "text-center" : "text-left"}>
      <p className="font-display text-sm tracking-[0.3em] text-pink">{kicker}</p>
      <h2 className="mt-3 text-balance font-cute text-4xl leading-tight sm:text-5xl">{title}</h2>
      {children && <div className={`mt-4 text-base leading-relaxed text-ink2 ${align === "center" ? "mx-auto max-w-2xl" : "max-w-xl"}`}>{children}</div>}
    </div>
  );
}
