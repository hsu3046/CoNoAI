// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 애니메이션 공용 훅: 화면에 보일 때만 돌기 · 스크롤 진행도 · 움직임 줄이기 설정.

"use client";

import { useEffect, useRef, useState, type RefObject } from "react";

/** 사용자가 "동작 줄이기" 를 켰는지 */
export function useReducedMotion(): boolean {
  const [reduced, setReduced] = useState(false);
  useEffect(() => {
    const query = window.matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => setReduced(query.matches);
    update();
    query.addEventListener("change", update);
    return () => query.removeEventListener("change", update);
  }, []);
  return reduced;
}

/** 요소가 화면에 들어왔는지 (한 번 들어오면 once 면 계속 true) */
export function useInView<T extends Element>(options: { once?: boolean; margin?: string } = {}): [RefObject<T | null>, boolean] {
  const ref = useRef<T>(null);
  const [inView, setInView] = useState(false);
  const { once = false, margin = "0px" } = options;
  useEffect(() => {
    const element = ref.current;
    if (!element) return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setInView(true);
          if (once) observer.disconnect();
        } else if (!once) {
          setInView(false);
        }
      },
      { rootMargin: margin },
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, [once, margin]);
  return [ref, inView];
}

/** 요소가 화면 밖으로 나가면 onLeave (소리 멈추기 등). 관찰 콜백에서 부르므로 안에서 setState 해도 된다 */
export function useOnLeave(ref: RefObject<Element | null>, onLeave: () => void, margin = "0px") {
  const callback = useRef(onLeave);
  useEffect(() => {
    callback.current = onLeave;
  }, [onLeave]);
  useEffect(() => {
    const element = ref.current;
    if (!element) return;
    const observer = new IntersectionObserver(([entry]) => !entry.isIntersecting && callback.current(), { rootMargin: margin });
    observer.observe(element);
    return () => observer.disconnect();
  }, [ref, margin]);
}

/** 캔버스를 기기 픽셀 비율에 맞추고 크기(CSS px)를 돌려준다 */
export function fitCanvas(canvas: HTMLCanvasElement): { width: number; height: number; ctx: CanvasRenderingContext2D | null } {
  const ratio = Math.min(2, window.devicePixelRatio || 1);
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) {
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
  }
  const ctx = canvas.getContext("2d");
  ctx?.setTransform(ratio, 0, 0, ratio, 0, 0);
  return { width, height, ctx };
}

let resolvedFonts: { display: string; cute: string; sans: string } | null = null;

/** 캔버스용 실제 글꼴 이름 (캔버스는 CSS 변수를 못 읽는다 — next/font 가 만든 이름을 꺼낸다) */
export function canvasFonts() {
  if (resolvedFonts) return resolvedFonts;
  const style = getComputedStyle(document.documentElement);
  const read = (name: string, fallback: string) => {
    const value = style.getPropertyValue(name).trim();
    return value ? `${value}, ${fallback}` : fallback;
  };
  resolvedFonts = {
    display: read("--font-black-han-sans", "sans-serif"),
    cute: read("--font-jua", "sans-serif"),
    sans: read("--font-noto-sans-kr", "sans-serif"),
  };
  return resolvedFonts;
}
