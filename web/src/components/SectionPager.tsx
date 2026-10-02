// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 넓은 화면에서 한 섹션씩 넘기기: 아래로 휠·키보드 한 번에 다음 섹션으로 착 넘어간다.
// 위로는 걸지 않는다 — 올리는 건 방금 본 걸 다시 찾는 동작이라 자유 스크롤이 자연스럽다 (넘기는 중이면 멈추고 넘겨준다).
// CSS scroll-snap mandatory 는 마우스 휠 한 칸(≈100px)을 원래 섹션으로 되돌려 다음 섹션으로 못 넘어가서 직접 한다.
//   - 스크롤 스토리(화면보다 긴 섹션) 안에서는 자유 스크롤. 끝에 닿은 뒤 더 내리면 다음 섹션으로
//   - 넘기는 동안과 직후 잠깐은 트랙패드 관성 휠을 무시 (두 칸씩 튀지 않게)
//   - 다른 곳이 이미 막은 휠(첫 화면 빨리 감기)은 건드리지 않는다
//   - 마우스·트랙패드면 창 크기와 관계없이 쓴다 (작은 창에서 CSS 스냅으로 넘기면 휠 한 칸이 되돌아와 갇힌다).
//     터치·동작 줄이기에서는 쓰지 않는다 (터치는 CSS proximity 스냅만)

"use client";

import { useEffect } from "react";

const DURATION = 700;
/** 넘긴 뒤 관성 휠을 무시할 시간 */
const COOLDOWN = 450;

export function SectionPager() {
  useEffect(() => {
    const mouse = window.matchMedia("(pointer: fine)");
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
    let animating = false;
    let lockedUntil = 0;
    let frame = 0;

    // 넘길 수 있는 자리: 섹션 시작들 + 페이지 끝. 긴 섹션은 [시작, 끝-화면] 자유 구간
    const layout = () => {
      const sections = [...document.querySelectorAll<HTMLElement>("main > section")];
      const max = document.documentElement.scrollHeight - window.innerHeight;
      const stops: number[] = [];
      const free: [number, number][] = [];
      for (const section of sections) {
        const top = section.offsetTop;
        stops.push(top);
        const end = top + section.offsetHeight - window.innerHeight;
        if (end - top > 40) {
          free.push([top, end]);
          stops.push(end);
        }
      }
      stops.push(max);
      return { stops: [...new Set(stops.map(Math.round))].sort((a, b) => a - b), free };
    };

    const easeInOut = (x: number) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);
    const animateTo = (target: number) => {
      const from = window.scrollY;
      const start = performance.now();
      animating = true;
      cancelAnimationFrame(frame);
      const step = (now: number) => {
        const k = Math.min(1, (now - start) / DURATION);
        window.scrollTo({ top: from + (target - from) * easeInOut(k), behavior: "instant" });
        if (k < 1) {
          frame = requestAnimationFrame(step);
        } else {
          animating = false;
          lockedUntil = performance.now() + COOLDOWN;
        }
      };
      frame = requestAnimationFrame(step);
    };

    /** 아래로 한 칸. 처리했으면 true (기본 스크롤을 막는다) */
    const pageDown = (): boolean => {
      const y = window.scrollY;
      const { stops, free } = layout();
      // 긴 섹션 안(끝에 닿기 전)은 자유 스크롤
      if (free.some(([top, end]) => y >= top - 2 && y < end - 2)) return false;
      const target = stops.find((stop) => stop > y + 2);
      if (target === undefined) return false;
      animateTo(target);
      return true;
    };

    const stopAnimation = () => {
      cancelAnimationFrame(frame);
      animating = false;
      lockedUntil = 0;
    };

    const onWheel = (event: WheelEvent) => {
      if (!mouse.matches || reduced.matches || event.defaultPrevented || event.ctrlKey) return;
      // 기록 목록과 결과 모달 안에서는 바깥 섹션으로 넘기지 않는다.
      const target = event.target instanceof Element ? event.target : null;
      if (target?.closest("[role=dialog], .overscroll-contain, textarea")) return;
      if (Math.abs(event.deltaY) < Math.abs(event.deltaX)) return;
      if (event.deltaY < 0) {
        // 위로는 자유: 넘기는 중이면 그 자리에서 멈추고 브라우저에 맡긴다
        if (animating) stopAnimation();
        return;
      }
      if (animating || performance.now() < lockedUntil) {
        // 넘기는 중·직후의 관성 휠: 자유 구간 안이 아니면 삼킨다
        event.preventDefault();
        return;
      }
      if (Math.abs(event.deltaY) < 2) return;
      if (pageDown()) event.preventDefault();
    };

    const onKey = (event: KeyboardEvent) => {
      if (!mouse.matches || reduced.matches || event.defaultPrevented || event.altKey || event.metaKey || event.ctrlKey) return;
      const target = event.target as HTMLElement | null;
      if (target?.closest("input, textarea, select, [contenteditable], [role=dialog]")) return;
      const down = event.key === "ArrowDown" || event.key === "PageDown" || (event.key === " " && !event.shiftKey);
      const up = event.key === "ArrowUp" || event.key === "PageUp" || (event.key === " " && event.shiftKey);
      if (up) {
        if (animating) stopAnimation(); // 위로는 브라우저 기본 스크롤
        return;
      }
      if (!down) return;
      if (target?.closest("button, a") && event.key === " ") return; // 버튼의 스페이스는 누르기
      if (animating) {
        event.preventDefault();
        return;
      }
      if (pageDown()) event.preventDefault();
    };

    window.addEventListener("wheel", onWheel, { passive: false });
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("wheel", onWheel);
      window.removeEventListener("keydown", onKey);
      cancelAnimationFrame(frame);
    };
  }, []);

  return null;
}
