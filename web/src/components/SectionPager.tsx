// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 넓은 화면에서 한 섹션씩 넘기기: 휠·키보드 한 번에 다음(이전) 섹션으로 착 넘어간다.
// CSS scroll-snap mandatory 는 마우스 휠 한 칸(≈100px)을 원래 섹션으로 되돌려 다음 섹션으로 못 넘어가서 직접 한다.
//   - 스크롤 스토리(화면보다 긴 섹션) 안에서는 자유 스크롤. 끝에 닿은 뒤 더 내리면 다음 섹션으로
//   - 넘기는 동안과 직후 잠깐은 트랙패드 관성 휠을 무시 (두 칸씩 튀지 않게)
//   - 다른 곳이 이미 막은 휠(첫 화면 빨리 감기)은 건드리지 않는다
//   - 작은 화면·터치·동작 줄이기에서는 쓰지 않는다 (CSS proximity 스냅만)

"use client";

import { useEffect } from "react";

const DURATION = 700;
/** 넘긴 뒤 관성 휠을 무시할 시간 */
const COOLDOWN = 450;

export function SectionPager() {
  useEffect(() => {
    const wide = window.matchMedia("(min-width: 1024px) and (min-height: 700px)");
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

    /** 방향으로 한 칸. 처리했으면 true (기본 스크롤을 막는다) */
    const page = (direction: 1 | -1): boolean => {
      const y = window.scrollY;
      const { stops, free } = layout();
      // 긴 섹션 안(끝에 닿기 전)은 자유 스크롤
      const inside = free.find(([top, end]) => (direction > 0 ? y >= top - 2 && y < end - 2 : y > top + 2 && y <= end + 2));
      if (inside) return false;
      const target = direction > 0 ? stops.find((stop) => stop > y + 2) : [...stops].reverse().find((stop) => stop < y - 2);
      if (target === undefined) return false;
      animateTo(target);
      return true;
    };

    const onWheel = (event: WheelEvent) => {
      if (!wide.matches || reduced.matches || event.defaultPrevented || event.ctrlKey) return;
      if (Math.abs(event.deltaY) < Math.abs(event.deltaX)) return;
      if (animating || performance.now() < lockedUntil) {
        // 넘기는 중·직후의 관성 휠: 자유 구간 안이 아니면 삼킨다
        event.preventDefault();
        return;
      }
      if (Math.abs(event.deltaY) < 2) return;
      if (page(event.deltaY > 0 ? 1 : -1)) event.preventDefault();
    };

    const onKey = (event: KeyboardEvent) => {
      if (!wide.matches || reduced.matches || event.defaultPrevented || event.altKey || event.metaKey || event.ctrlKey) return;
      const target = event.target as HTMLElement | null;
      if (target?.closest("input, textarea, select, [contenteditable], [role=dialog]")) return;
      const down = event.key === "ArrowDown" || event.key === "PageDown" || (event.key === " " && !event.shiftKey);
      const up = event.key === "ArrowUp" || event.key === "PageUp" || (event.key === " " && event.shiftKey);
      if (!down && !up) return;
      if (target?.closest("button, a") && event.key === " ") return; // 버튼의 스페이스는 누르기
      if (animating) {
        event.preventDefault();
        return;
      }
      if (page(down ? 1 : -1)) event.preventDefault();
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
