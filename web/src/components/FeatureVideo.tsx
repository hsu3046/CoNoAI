// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useOnLeave } from "@/fx/hooks";
import { claimAudio, onAudioClaim } from "@/fx/stems";
import type { VideoItem } from "@/lib/release";

export function FeatureVideo({ video }: { video: VideoItem }) {
  const element = useRef<HTMLVideoElement>(null);
  const [failed, setFailed] = useState(false);
  const owner = `guide-${video.id}`;
  const pause = useCallback(() => { element.current?.pause(); }, []);
  useOnLeave(element, pause);
  useEffect(() => onAudioClaim((active) => { if (active !== owner) pause(); }), [owner, pause]);
  useEffect(() => {
    const hidden = () => { if (document.hidden) pause(); };
    document.addEventListener("visibilitychange", hidden);
    return () => document.removeEventListener("visibilitychange", hidden);
  }, [pause]);

  return <>
    <video ref={element} src={video.src} poster={video.poster} controls playsInline preload="none"
      aria-label={`${video.title} 안내 영상`} className="aspect-video w-full bg-black object-contain"
      onPlay={() => claimAudio(owner)} onError={() => setFailed(true)}>
      <track kind="captions" src={video.captions} srcLang="ko" label="한국어 안내" default />
      <a href={video.src}>영상 파일 열기</a>
    </video>
    <figcaption className="p-5">
      <h3 className="font-cute text-xl">{video.title}</h3>
      <p className="mt-1 text-sm text-ink2">{video.caption}</p>
      {failed && <p role="alert" className="mt-3 text-sm text-stop">영상을 불러오지 못했어요. <a className="underline" href={video.src}>영상 파일 열기</a></p>}
      <a href={video.action.href} className="mt-4 inline-block rounded-full border border-mint/40 px-4 py-2 text-sm text-mint">{video.action.label} →</a>
      <details className="mt-4 text-sm text-ink2">
        <summary className="cursor-pointer">글로 읽는 사용법</summary>
        <ol className="mt-3 list-decimal space-y-2 pl-5">{video.transcript.map((step) => <li key={step}>{step}</li>)}</ol>
      </details>
    </figcaption>
  </>;
}
