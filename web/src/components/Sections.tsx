// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 소개 섹션들: 기능 · 사용법 · 영상 · 챌린지 예고 · 자주 묻는 질문 · 다운로드 · 바닥글

"use client";

import Image from "next/image";
import { useState, type ReactNode } from "react";
import { useInView } from "@/fx/hooks";
import { release, videos } from "@/lib/release";
import { CONTAINER, Screen, SectionTitle } from "./Screen";

function Reveal({ children, delay = 0, className = "" }: { children: ReactNode; delay?: number; className?: string }) {
  // 화면 아래 끝에 닿기 조금 전부터 나타나기 시작 (스크롤보다 늦게 튀어나오지 않게)
  const [ref, inView] = useInView<HTMLDivElement>({ once: true, margin: "0px 0px 80px 0px" });
  return (
    <div ref={ref} className={`reveal ${inView ? "in" : ""} ${className}`} style={{ transitionDelay: `${delay}ms` }}>
      {children}
    </div>
  );
}

// MARK: - 기능

const FEATURES: { icon: string; title: string; body: string; tint: string }[] = [
  { icon: "🎧", title: "어떤 앱이든", body: "Apple Music, 브라우저의 YouTube, Spotify, 멜론… Mac에서 소리가 나면 노래방이 됩니다.", tint: "#5cc7ff" },
  { icon: "🪄", title: "AI 반주", body: "내 컴퓨터 안에서 노래의 보컬만 제거합니다. 곡을 다운로드하거나 전송하지 않아요.", tint: "#ff8fb0" },
  { icon: "🎼", title: "가사 표시 및 싱크", body: "가사를 찾아와 목소리에 맞춰 자동 싱크. Apple Music 계정을 연결하면 음절 단위까지.", tint: "#5ee0b8" },
  { icon: "📈", title: "원곡 음정 바", body: "AI가 원곡 가수의 음정을 자동으로 읽어 막대로 보여 줘요. 어디서 올리고 내릴지 한눈에.", tint: "#ffcc5c" },
  { icon: "🎚️", title: "내 키 · 가이드 보컬", body: "원곡 음역을 재서 내 목소리에 맞는 키로. 헷갈리는 부분은 원곡 목소리를 살짝 섞어서.", tint: "#b88cff" },
  { icon: "🏆", title: "정확한 AI 채점", body: "마이크로 부르면 AI가 정확하게 실시간 채점. 100점 만점에 도전해보세요!", tint: "#ff734d" },
  { icon: "🔇", title: "광고는 알아서 음소거", body: "YouTube 노래를 반주로 사용할 때, 광고 소리는 자동으로 음소거해 줘요.", tint: "#5cc7ff" },
  { icon: "⏹", title: "1절만 부르고 끝내기", body: "원하는 노래를 부르고 싶은 만큼만. 가격은 공짜, 시간은 무제한!", tint: "#ff8fb0" },
];

export function Features() {
  return (
    <Screen glow={{ color: "rgba(255,143,176,0.09)", x: "15%", y: "40%" }}>
      <div className="grid items-center gap-10 lg:grid-cols-[minmax(0,0.75fr)_minmax(0,1.8fr)]">
        <SectionTitle kicker="FEATURES" title="노래방 기계가 내 Mac 안으로" align="left">
          <p>따로 곡을 받거나 반주를 찾을 필요 없어요. 늘 쓰던 음악 앱이 그대로 노래방 기계가 됩니다.</p>
        </SectionTitle>
        <div className="grid gap-3 sm:grid-cols-2">
          {FEATURES.map((feature, index) => (
            <Reveal key={feature.title} delay={(index % 2) * 60 + Math.floor(index / 2) * 60}>
              <article className="group relative flex h-full gap-4 overflow-hidden rounded-2xl border border-white/10 bg-white/[0.035] p-4 transition duration-300 hover:-translate-y-1 hover:border-white/25">
                <div
                  className="pointer-events-none absolute -right-8 -top-8 size-28 rounded-full opacity-20 blur-2xl transition-opacity duration-500 group-hover:opacity-50"
                  style={{ background: feature.tint }}
                />
                <div
                  className="grid size-12 shrink-0 place-items-center rounded-xl text-2xl transition-transform duration-500 group-hover:rotate-[-8deg] group-hover:scale-110"
                  style={{ background: `${feature.tint}22`, boxShadow: `0 0 20px ${feature.tint}33` }}
                >
                  {feature.icon}
                </div>
                <div className="min-w-0">
                  <h3 className="font-cute text-xl">{feature.title}</h3>
                  <p className="mt-1 text-sm leading-relaxed text-ink2">{feature.body}</p>
                </div>
              </article>
            </Reveal>
          ))}
        </div>
      </div>
    </Screen>
  );
}

// MARK: - 사용법

export function HowTo() {
  return (
    <Screen id="how" glow={{ color: "rgba(94,224,184,0.08)", x: "85%", y: "30%" }}>
      <SectionTitle kicker="HOW TO" title="설치 방법">
        지금은 Mac에서만 사용할 수 있어요. Windows나 스마트폰은 조금 기다려 주세요.
      </SectionTitle>
      <div className="mt-10 grid gap-5 lg:grid-cols-3">
        <Reveal>
          <Step number="1" title="다운로드 및 설치" body="다운로드한 DMG 파일을 열고 CoNo를 응용 프로그램 폴더로 끌어다 놓으세요.">
            <InstallDemo />
          </Step>
        </Reveal>
        <Reveal delay={100}>
          <Step number="2" title="권한 허용" body="처음 켜면 macOS가 물어봐요. 셋 다 허용하면 끝. 설정 › 일반 › 권한에서 언제든 다시 열 수 있어요.">
            <PermissionDemo />
          </Step>
        </Reveal>
        <Reveal delay={200}>
          <Step number="3" title="음악 틀기" body="음악 앱에서 노래를 틀면 CoNo가 알아서 시작해요. 채점 버튼을 누르면 AI 채점이 시작됩니다.">
            <AutoStartDemo />
          </Step>
        </Reveal>
      </div>
    </Screen>
  );
}

const SHORTCUTS: [string[], string][] = [
  [["Space"], "재생 · 일시정지"],
  [["Esc"], "곡 끝내기 (채점 중이면 점수)"],
  [["↑", "↓"], "키 반음씩 올리고 내리기"],
  [["K"], "내 키 (내 목소리에 맞추기)"],
  [["1", "2", "3"], "반주 · 보컬 · 원곡"],
  [["[", "]"], "가사가 늦거나 빠를 때"],
  [["→"], "간주 점프"],
  [["⌘", ","], "설정"],
];

/** 리모컨 대신 키보드 + 알아 두면 좋은 것 */
export function Shortcuts() {
  return (
    <Screen glow={{ color: "rgba(255,204,92,0.07)", x: "20%", y: "60%" }}>
      <div className="grid items-center gap-10 lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.5fr)]">
        <div>
          <SectionTitle kicker="REMOTE" title="리모컨 대신 키보드" align="left">
            노래하면서도 한 손으로. 노래방 리모컨에 있던 버튼이 다 키보드에 있어요.
          </SectionTitle>
        </div>
        <Reveal>
          <div className="grid gap-3 rounded-3xl border border-white/10 bg-white/[0.03] p-5 sm:grid-cols-2 sm:p-6">
            {SHORTCUTS.map(([keys, label]) => (
              <div key={label} className="flex items-center gap-3 rounded-2xl bg-black/20 px-4 py-3.5">
                <span className="flex shrink-0 gap-1.5">
                  {keys.map((key) => (
                    <kbd
                      key={key}
                      className="min-w-10 rounded-lg border border-white/20 border-b-4 bg-white/10 px-2 py-1.5 text-center font-sans text-base font-bold shadow-[0_2px_0_rgba(0,0,0,0.4)] transition active:translate-y-0.5 active:border-b-2"
                    >
                      {key}
                    </kbd>
                  ))}
                </span>
                <span className="text-[15px] text-ink2">{label}</span>
              </div>
            ))}
          </div>
        </Reveal>
      </div>
    </Screen>
  );
}

function Step({ number, title, body, children }: { number: string; title: string; body: string; children: ReactNode }) {
  return (
    <article className="flex h-full flex-col overflow-hidden rounded-3xl border border-white/10 bg-gradient-to-b from-white/[0.06] to-white/[0.02]">
      <div className="relative grid h-48 place-items-center overflow-hidden bg-black/25">{children}</div>
      <div className="flex-1 p-5">
        <h3 className="flex items-baseline gap-3 font-cute text-2xl">
          <span className="font-display text-3xl text-pink/80">{number}</span>
          {title}
        </h3>
        <p className="mt-2 text-[15px] leading-relaxed text-ink2">{body}</p>
      </div>
    </article>
  );
}

function InstallDemo() {
  return (
    <div className="relative flex w-[260px] items-center justify-between rounded-2xl border border-white/15 bg-[#1d1f33] px-8 py-7 shadow-xl">
      <div className="flex flex-col items-center gap-1.5">
        <Image
          src="/app-icon-dark.png"
          alt=""
          width={64}
          height={64}
          className="relative z-10 rounded-xl"
          style={{ animation: "drag-install 3.2s ease-in-out infinite", ["--dx" as string]: "128px" }}
        />
        <Image src="/app-icon-dark.png" alt="" width={64} height={64} className="absolute rounded-xl opacity-30" />
        <span className="mt-16 text-xs text-ink2">CoNo</span>
      </div>
      <span className="text-3xl text-faint">→</span>
      <div className="flex flex-col items-center gap-1.5">
        <div className="grid size-16 place-items-center rounded-xl bg-sky/25 text-3xl">📁</div>
        <span className="text-xs text-ink2">응용 프로그램</span>
      </div>
    </div>
  );
}

function PermissionDemo() {
  const rows = ["화면 및 시스템 오디오 녹음", "자동화 › 음악", "마이크"];
  return (
    <div className="w-[270px] rounded-2xl border border-white/15 bg-[#1d1f33] p-3 shadow-xl">
      <p className="px-2 pb-2 text-xs text-faint">개인정보 보호 및 보안</p>
      {rows.map((row, index) => (
        <div key={row} className="flex items-center justify-between rounded-lg px-2 py-2 odd:bg-white/5">
          <span className="flex items-center gap-2 text-sm">
            <Image src="/app-icon-dark.png" alt="" width={18} height={18} className="rounded" />
            {row}
          </span>
          <span
            className="relative h-5 w-9 rounded-full"
            style={{ animation: `toggle-on 4.5s ease ${index * 0.6}s infinite` }}
          >
            <span
              className="absolute left-0.5 top-0.5 size-4 rounded-full bg-white shadow"
              style={{ animation: `knob-on 4.5s ease ${index * 0.6}s infinite` }}
            />
          </span>
        </div>
      ))}
    </div>
  );
}

function AutoStartDemo() {
  return (
    <div className="relative flex items-center gap-4">
      <div className="rounded-2xl border border-white/15 bg-[#1d1f33] p-3 shadow-xl">
        <div className="size-16 rounded-xl bg-[conic-gradient(from_90deg,#ff8fb0,#5cc7ff,#5ee0b8,#ffcc5c,#ff8fb0)]" />
        <p className="mt-2 text-center text-xs text-ink2">▶ 재생</p>
      </div>
      <div className="flex gap-1">
        {[0, 1, 2].map((index) => (
          <span key={index} className="size-2 rounded-full bg-pink" style={{ animation: `twinkle 1.2s ease ${index * 0.2}s infinite` }} />
        ))}
      </div>
      <div className="rounded-2xl border border-mint/40 bg-[#131a2a] p-3 text-center shadow-[0_0_30px_rgba(94,224,184,0.25)]">
        <Image src="/app-icon-dark.png" alt="" width={56} height={56} className="mx-auto rounded-xl" />
        <p className="mt-2 flex items-center justify-center gap-1 text-xs font-bold text-mint">
          <span className="size-1.5 animate-pulse rounded-full bg-mint" /> LIVE
        </p>
      </div>
    </div>
  );
}

// MARK: - 영상

export function Videos() {
  return (
    <Screen glow={{ color: "rgba(92,199,255,0.08)", x: "20%", y: "60%" }}>
      <SectionTitle kicker="WATCH" title="영상으로 보기" />
      <div className="mt-10 grid gap-6 md:grid-cols-2">
        {videos.map((video, index) => (
          <Reveal key={video.id} delay={index * 120}>
            <figure className="overflow-hidden rounded-3xl border border-white/10 bg-black/40">
              <div className="relative aspect-video max-h-[52dvh] w-full">
                {video.src ? (
                  video.src.includes("youtube") ? (
                    <iframe src={video.src} title={video.title} className="absolute inset-0 size-full" allow="autoplay; encrypted-media; picture-in-picture" allowFullScreen />
                  ) : (
                    <video src={video.src} poster={video.poster} controls playsInline className="absolute inset-0 size-full object-cover" />
                  )
                ) : (
                  <ComingSoon />
                )}
              </div>
              <figcaption className="p-5">
                <p className="font-cute text-xl">{video.title}</p>
                <p className="mt-1 text-sm text-ink2">{video.caption}</p>
              </figcaption>
            </figure>
          </Reveal>
        ))}
      </div>
    </Screen>
  );
}

function ComingSoon() {
  return (
    <div className="absolute inset-0 grid place-items-center overflow-hidden bg-[radial-gradient(ellipse_at_center,#2a1147,#0b0d1a)]">
      <div className="absolute inset-0 opacity-[0.07] [background-image:repeating-linear-gradient(0deg,#fff_0_1px,transparent_1px_3px)]" />
      <div className="text-center">
        <p className="text-5xl" style={{ animation: "floaty 3s ease-in-out infinite" }}>
          🎬
        </p>
        <p className="neon neon-gold mt-3 font-display text-3xl flicker">촬영 중</p>
        <p className="mt-2 text-sm text-ink2">곧 올라와요</p>
      </div>
    </div>
  );
}

// MARK: - 챌린지 예고

export function ChallengeTeaser() {
  const rows = [
    ["🥇", "노래하는고양이", 98],
    ["🥈", "거실가왕", 96],
    ["🥉", "샤워실디바", 95],
    ["4", "퇴근후한곡", 93],
    ["5", "고음불가", 91],
  ] as const;
  return (
    <Screen glow={{ color: "rgba(255,204,92,0.09)", x: "75%", y: "50%" }}>
      <div className="grid items-center gap-10 lg:grid-cols-2">
        <SectionTitle kicker="COMING SOON" title="이번 주 챌린지 곡, 1등은 누구?" align="left">
          <p>같은 곡을 불러 점수를 겨루는 챌린지를 준비하고 있어요. 앱에서 받은 점수를 한 번에 올리고, 친구에게 도전장을 보내세요.</p>
          <a href="#feedback" className="mt-6 inline-block rounded-full bg-gold px-6 py-3 font-cute text-lg text-night shadow-[0_0_30px_rgba(255,204,92,0.6)] transition hover:scale-105">
            소식 먼저 받기 →
          </a>
        </SectionTitle>
        <Reveal className="relative">
          <div className="rounded-3xl border border-gold/30 bg-gradient-to-b from-gold/10 to-transparent p-6 shadow-[0_0_60px_rgba(255,204,92,0.15)]">
            <p className="text-center font-cute text-lg text-gold">🎤 이번 주: 〈우리 집 무대〉</p>
            <ol className="mt-5 space-y-2 blur-[3px]" aria-hidden>
              {rows.map(([rank, name, score]) => (
                <li key={name} className="flex items-center justify-between rounded-xl bg-black/30 px-4 py-3">
                  <span className="flex items-center gap-3">
                    <span className="w-6 text-center font-display">{rank}</span>
                    {name}
                  </span>
                  <span className="font-display text-xl text-gold">{score}</span>
                </li>
              ))}
            </ol>
          </div>
          <div className="absolute inset-0 grid place-items-center">
            <span className="neon neon-gold rotate-[-6deg] font-display text-4xl">곧 열려요</span>
          </div>
        </Reveal>
      </div>
    </Screen>
  );
}

// MARK: - 자주 묻는 질문

const FAQ: [string, string][] = [
  ["정말 무료인가요?", "네. CoNo는 GNU GPL v3 오픈소스예요. 광고도, 결제도 없어요."],
  ["어떤 Mac에서 되나요?", `${release.minimumMacOS}. AI 반주는 Apple Silicon(M1 이상)에서 가장 부드러워요.`],
  ["어떤 음악 앱을 쓸 수 있나요?", "Mac에서 소리를 내는 앱이면 대부분 돼요. Apple Music은 곡 정보·재생 위치까지 가장 정확하고, 브라우저의 YouTube, Spotify, 멜론도 곡 정보를 읽어 가사를 찾아요."],
  ["제 목소리나 음악이 어디로 보내지나요?", "아니요. 보컬 분리와 채점은 모두 Mac 안에서 해요. 인터넷은 가사를 찾을 때만 써요. 이 사이트의 체험도 브라우저 안에서만 음정을 재요."],
  ["가사가 안 나오거나 어긋나요", "가사를 찾지 못한 곡은 음정 바만 나와요. 조금 어긋나면 가사 위에 마우스를 올려 ± 로, 또는 [ ] 키로 맞추세요. 맞춘 값은 곡마다 기억해요."],
  ["블루투스 이어폰은요?", "돼요. 다만 블루투스는 소리가 늦게 나와서 화면이 앞서 보일 수 있어요. 설정 › 가사 › 화면 싱크를 +150~250ms로 맞추세요. 블루투스 마이크는 이어폰 음질을 떨어뜨리니 채점은 Mac 마이크로."],
  ["YouTube 광고가 나오면요?", "광고를 알아채 소리를 끄고 가사 자리에 \"광고 재생 중\"을 띄워요. 건너뛰기는 YouTube에서 직접 눌러 주세요."],
  ["Windows나 iPhone은요?", "지금은 Mac 전용이에요. 원하시면 아래 의견에 남겨 주세요 — 많이 들리면 우선순위가 올라가요."],
];

export function Faq() {
  const [open, setOpen] = useState<number | null>(0);
  return (
    <Screen id="faq" glow={{ color: "rgba(184,140,255,0.08)", x: "80%", y: "40%" }}>
      <div className="grid items-start gap-10 lg:grid-cols-[minmax(0,0.7fr)_minmax(0,1.6fr)]">
      <SectionTitle kicker="FAQ" title="자주 묻는 질문" align="left">
        <p>더 궁금한 건 아래 의견으로 남겨 주세요. 하나하나 답해 드려요.</p>
      </SectionTitle>
      <div className="space-y-2.5">
        {FAQ.map(([question, answer], index) => {
          const isOpen = open === index;
          return (
            <div key={question} className={`overflow-hidden rounded-2xl border transition-colors ${isOpen ? "border-pink/40 bg-white/[0.05]" : "border-white/10 bg-white/[0.02]"}`}>
              <button
                type="button"
                onClick={() => setOpen(isOpen ? null : index)}
                aria-expanded={isOpen}
                className="flex w-full items-center justify-between gap-4 px-5 py-3.5 text-left"
              >
                <span className="font-cute text-lg">{question}</span>
                <span className={`text-xl text-pink transition-transform duration-300 ${isOpen ? "rotate-45" : ""}`}>+</span>
              </button>
              <div className="grid transition-[grid-template-rows] duration-300" style={{ gridTemplateRows: isOpen ? "1fr" : "0fr" }}>
                <p className="overflow-hidden px-5 text-[15px] leading-relaxed text-ink2">
                  <span className="block pb-5">{answer}</span>
                </p>
              </div>
            </div>
          );
        })}
      </div>
      </div>
    </Screen>
  );
}

// MARK: - 다운로드

export function Download() {
  const [copied, setCopied] = useState(false);
  return (
    <Screen id="download" glow={{ color: "rgba(255,204,92,0.14)", x: "50%", y: "50%" }}>
      <div className="relative mx-auto max-w-3xl text-center">
        {/* 배경 없는 마이크 그림이 무대 빛에 녹아든다 */}
        <Image
          src="/logo.png"
          alt="CoNo"
          width={150}
          height={150}
          className="mx-auto drop-shadow-[0_0_36px_rgba(94,224,184,0.45)]"
          style={{ animation: "floaty 5s ease-in-out infinite" }}
        />
        <h2 className="mt-8 font-display text-[clamp(40px,8vw,72px)] leading-none">
          <span className="neon neon-gold">오늘 밤,</span> <span className="neon">우리 집이 무대</span>
        </h2>
        <p className="mt-5 text-ink2">무료 · 오픈소스 · Apple 공증 완료</p>
        <a
          href={release.downloadUrl}
          className="group relative mt-9 inline-flex items-center gap-3 rounded-full bg-gold px-10 py-5 font-cute text-2xl text-night shadow-[0_0_50px_rgba(255,204,92,0.6)] transition hover:scale-105"
        >
          Mac용 다운로드
          <span className="rounded-full bg-night/15 px-2.5 py-0.5 text-base">v{release.version}</span>
        </a>
        <p className="mt-4 text-sm text-faint">
          {release.sizeLabel} · {release.minimumMacOS} · Apple Silicon 권장
        </p>
        <SendToMac />
        <div className="mx-auto mt-8 max-w-xl rounded-2xl border border-white/10 bg-black/30 px-4 py-3 text-left">
          <p className="text-xs text-faint">SHA-256 (내려받은 파일이 온전한지 확인용)</p>
          <div className="mt-1 flex items-center gap-2">
            <code className="min-w-0 flex-1 truncate text-xs text-ink2">{release.sha256}</code>
            <button
              type="button"
              onClick={async () => {
                try {
                  await navigator.clipboard.writeText(release.sha256);
                  setCopied(true);
                  window.setTimeout(() => setCopied(false), 1600);
                } catch {
                  setCopied(false);
                }
              }}
              className="shrink-0 rounded-lg bg-white/10 px-3 py-1 text-xs transition hover:bg-white/20"
            >
              {copied ? "복사됨 ✓" : "복사"}
            </button>
          </div>
        </div>
        <p className="mt-6 text-sm text-faint">
          지난 버전·소스 코드는{" "}
          <a href={release.releasesUrl} className="text-ink2 underline underline-offset-4 hover:text-ink">
            GitHub
          </a>
          에서
        </p>
      </div>
    </Screen>
  );
}

/** 휴대폰으로 보고 있을 때: Mac 으로 이 페이지 보내기 */
function SendToMac() {
  const [note, setNote] = useState<string | null>(null);
  return (
    <div className="mt-5 sm:hidden">
      <button
        type="button"
        onClick={async () => {
          const url = `${window.location.origin}/#download`;
          try {
            if (navigator.share) {
              await navigator.share({ title: "CoNo — 집에서 나만의 노래방", text: "Mac에서 열어서 설치하기", url });
              return;
            }
            await navigator.clipboard.writeText(url);
            setNote("링크를 복사했어요. Mac으로 보내 주세요");
          } catch {
            // 공유 창을 닫은 경우
          }
        }}
        className="rounded-full border border-white/20 bg-white/5 px-6 py-3 font-cute text-lg"
      >
        📲 Mac으로 링크 보내기
      </button>
      <p className="mt-2 h-4 text-xs text-mint">{note ?? ""}</p>
    </div>
  );
}

// MARK: - 바닥글

export function Footer() {
  return (
    <footer className="snap-end border-t border-white/10 py-10 text-sm text-faint">
      <div className={`${CONTAINER} flex flex-col items-center justify-between gap-4 sm:flex-row`}>
        <div className="flex items-center gap-3">
          <Image src="/logo.png" alt="" width={28} height={28} />
          <span>
            © 2026 <a href="https://www.aib.vote" className="text-ink2 hover:text-ink">AIB Inc.</a> · GNU GPL v3
          </span>
        </div>
        <div className="flex flex-wrap items-center justify-center gap-4">
          <a href={release.repositoryUrl} className="hover:text-ink">
            GitHub
          </a>
          <a href="#feedback" className="hover:text-ink">
            의견 보내기
          </a>
          <span>효과음 드럼롤: Freesound #569113 (CC0)</span>
          <span>사이트의 노래는 모두 자작곡 · All rights reserved (GPL 대상 아님)</span>
        </div>
      </div>
    </footer>
  );
}
