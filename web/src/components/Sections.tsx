// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 소개 섹션들: 기능 · 사용법 · 영상 · 챌린지 예고 · 자주 묻는 질문 · 다운로드 · 바닥글

"use client";

import Image from "next/image";
import { useState, type ReactNode } from "react";
import { useInView } from "@/fx/hooks";
import { release, videos } from "@/lib/release";
import { SectionTitle } from "./TryItLive";

function Reveal({ children, delay = 0, className = "" }: { children: ReactNode; delay?: number; className?: string }) {
  const [ref, inView] = useInView<HTMLDivElement>({ once: true, margin: "-60px" });
  return (
    <div ref={ref} className={`reveal ${inView ? "in" : ""} ${className}`} style={{ transitionDelay: `${delay}ms` }}>
      {children}
    </div>
  );
}

// MARK: - 기능

const FEATURES: { icon: string; title: string; body: string; tint: string }[] = [
  { icon: "🎧", title: "어떤 앱이든", body: "Apple Music, 브라우저의 YouTube Music, Spotify, 멜론… Mac 에서 소리가 나면 노래방이 됩니다.", tint: "#5cc7ff" },
  { icon: "🪄", title: "AI 반주", body: "Mac 안에서 목소리만 지워요. 인터넷으로 보내지 않고, 곡을 미리 받아 둘 필요도 없어요.", tint: "#ff8fb0" },
  { icon: "🎼", title: "글자마다 색칠되는 가사", body: "여러 가사 저장소에서 찾아 목소리에 맞춰 자동 싱크. Apple Music 계정을 연결하면 음절 단위까지.", tint: "#5ee0b8" },
  { icon: "📈", title: "3.5초 먼저 보는 음정 바", body: "소리를 조금 늦게 들려주는 대신, 다음에 부를 음을 미리 보여 줘요.", tint: "#ffcc5c" },
  { icon: "🎚️", title: "내 키 · 가이드 보컬", body: "원곡 음역을 재서 내 목소리에 맞는 키로. 헷갈리는 부분은 원곡 목소리를 살짝 섞어서.", tint: "#b88cff" },
  { icon: "🏆", title: "채점과 불꽃놀이", body: "마이크로 부르면 실시간 채점. 곡이 끝나면 드럼롤, 쾅, 팡팡. 스피커로 틀어도 반주는 걸러요.", tint: "#ff734d" },
  { icon: "🔇", title: "광고는 알아서 음소거", body: "YouTube 광고를 알아채 소리를 끄고 \"광고 재생 중\" 이라고 알려 줘요.", tint: "#5cc7ff" },
  { icon: "⏹", title: "1절만 부르고 끝내기", body: "Esc 한 번에 여기까지 채점. 재생을 누르면 다음 곡이 처음부터.", tint: "#ff8fb0" },
];

export function Features() {
  return (
    <section className="relative px-4 py-24 sm:py-32">
      <SectionTitle kicker="FEATURES" title="노래방 기계, 이제 Mac 안에" />
      <div className="mx-auto mt-14 grid max-w-6xl gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {FEATURES.map((feature, index) => (
          <Reveal key={feature.title} delay={(index % 4) * 80}>
            <article
              className="group relative h-full overflow-hidden rounded-3xl border border-white/10 bg-white/[0.035] p-6 transition duration-300 hover:-translate-y-1.5 hover:border-white/25"
              style={{ boxShadow: `inset 0 1px 0 rgba(255,255,255,0.06)` }}
            >
              <div
                className="pointer-events-none absolute -right-10 -top-10 size-40 rounded-full opacity-25 blur-3xl transition-opacity duration-500 group-hover:opacity-60"
                style={{ background: feature.tint }}
              />
              <div
                className="grid size-14 place-items-center rounded-2xl text-3xl transition-transform duration-500 group-hover:rotate-[-8deg] group-hover:scale-110"
                style={{ background: `${feature.tint}22`, boxShadow: `0 0 24px ${feature.tint}33` }}
              >
                {feature.icon}
              </div>
              <h3 className="mt-5 font-cute text-2xl">{feature.title}</h3>
              <p className="mt-2 text-[15px] leading-relaxed text-ink2">{feature.body}</p>
            </article>
          </Reveal>
        ))}
      </div>
    </section>
  );
}

// MARK: - 사용법

export function HowTo() {
  return (
    <section id="how" className="relative px-4 py-24 sm:py-32">
      <SectionTitle kicker="HOW TO" title="처음 한 번만, 3단계" />
      <p className="mx-auto mt-4 max-w-2xl text-center text-ink2">조금 낯설 수 있는 건 권한 허용뿐이에요. 한 번 해 두면 다음부턴 음악만 틀면 됩니다.</p>
      <div className="mx-auto mt-14 grid max-w-6xl gap-6 lg:grid-cols-3">
        <Reveal>
          <Step number="1" title="설치" body="내려받은 DMG 를 열고 CoNo 를 응용 프로그램 폴더로 끌어다 놓으세요. Apple 공증을 받은 앱이라 바로 열려요.">
            <InstallDemo />
          </Step>
        </Reveal>
        <Reveal delay={120}>
          <Step
            number="2"
            title="권한 허용"
            body="처음 켜면 macOS 가 물어봐요. 셋 다 허용하면 끝. 설정 › 일반 › 권한에서 언제든 다시 열 수 있어요."
          >
            <PermissionDemo />
          </Step>
        </Reveal>
        <Reveal delay={240}>
          <Step number="3" title="음악 틀기" body="음악 앱에서 노래를 틀면 CoNo 가 알아서 시작해요. 도크의 채점 버튼을 누르면 마이크 채점까지.">
            <AutoStartDemo />
          </Step>
        </Reveal>
      </div>

      <Reveal className="mx-auto mt-16 max-w-4xl">
        <div className="rounded-3xl border border-white/10 bg-white/[0.03] p-6 sm:p-8">
          <h3 className="text-center font-cute text-2xl">리모컨 대신 키보드</h3>
          <div className="mt-6 grid gap-3 sm:grid-cols-2">
            {[
              [["Space"], "재생 · 일시정지"],
              [["Esc"], "곡 끝내기 (채점 중이면 점수)"],
              [["↑", "↓"], "키 반음씩 올리고 내리기"],
              [["K"], "내 키 (내 목소리에 맞추기)"],
              [["1", "2", "3"], "반주 · 보컬 · 원곡"],
              [["[", "]"], "가사가 늦거나 빠를 때"],
              [["→"], "간주 점프"],
              [["⌘", ","], "설정"],
            ].map(([keys, label]) => (
              <div key={label as string} className="flex items-center gap-3 rounded-2xl bg-black/20 px-4 py-3">
                <span className="flex shrink-0 gap-1.5">
                  {(keys as string[]).map((key) => (
                    <kbd
                      key={key}
                      className="min-w-9 rounded-lg border border-white/20 border-b-4 bg-white/10 px-2 py-1 text-center font-sans text-sm font-bold shadow-[0_2px_0_rgba(0,0,0,0.4)] transition active:translate-y-0.5 active:border-b-2"
                    >
                      {key}
                    </kbd>
                  ))}
                </span>
                <span className="text-sm text-ink2">{label}</span>
              </div>
            ))}
          </div>
        </div>
      </Reveal>

      <Reveal className="mx-auto mt-8 grid max-w-4xl gap-3 sm:grid-cols-3">
        {[
          ["🎧 블루투스 이어폰", "화면이 소리보다 빠르면 설정 › 가사 › 화면 싱크를 +150~250ms 로"],
          ["🔈 스피커로도 OK", "채점할 땐 마이크를 입 가까이. 반주가 새는 양은 CoNo 가 재서 걸러요"],
          ["⚡️ Apple Silicon 권장", "AI 반주는 M1 이상에서 가장 부드러워요"],
        ].map(([title, body]) => (
          <div key={title} className="rounded-2xl border border-white/10 bg-white/[0.03] p-4">
            <p className="font-cute text-lg">{title}</p>
            <p className="mt-1 text-sm leading-relaxed text-ink2">{body}</p>
          </div>
        ))}
      </Reveal>
    </section>
  );
}

function Step({ number, title, body, children }: { number: string; title: string; body: string; children: ReactNode }) {
  return (
    <article className="flex h-full flex-col overflow-hidden rounded-3xl border border-white/10 bg-gradient-to-b from-white/[0.06] to-white/[0.02]">
      <div className="relative grid h-56 place-items-center overflow-hidden bg-black/25">{children}</div>
      <div className="flex-1 p-6">
        <p className="font-display text-4xl text-pink/80">{number}</p>
        <h3 className="mt-1 font-cute text-2xl">{title}</h3>
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
          src="/app-icon.png"
          alt=""
          width={64}
          height={64}
          className="relative z-10 rounded-xl"
          style={{ animation: "drag-install 3.2s ease-in-out infinite", ["--dx" as string]: "128px" }}
        />
        <Image src="/app-icon.png" alt="" width={64} height={64} className="absolute rounded-xl opacity-30" />
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
            <Image src="/app-icon.png" alt="" width={18} height={18} className="rounded" />
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
        <Image src="/app-icon.png" alt="" width={56} height={56} className="mx-auto rounded-xl" />
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
    <section className="relative px-4 py-24 sm:py-32">
      <SectionTitle kicker="WATCH" title="영상으로 보기" />
      <div className="mx-auto mt-14 grid max-w-6xl gap-6 md:grid-cols-2">
        {videos.map((video, index) => (
          <Reveal key={video.id} delay={index * 120}>
            <figure className="overflow-hidden rounded-3xl border border-white/10 bg-black/40">
              <div className="relative aspect-video">
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
    </section>
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
    <section className="relative px-4 py-24 sm:py-32">
      <SectionTitle kicker="COMING SOON" title="이번 주 챌린지 곡, 1등은 누구?" />
      <p className="mx-auto mt-4 max-w-2xl text-center text-ink2">
        같은 곡을 불러 점수를 겨루는 챌린지를 준비하고 있어요. 앱에서 받은 점수를 한 번에 올리고, 친구에게 도전장을 보내세요.
      </p>
      <Reveal className="relative mx-auto mt-12 max-w-xl">
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
          <a href="#feedback" className="rounded-full bg-gold px-6 py-3 font-cute text-lg text-night shadow-[0_0_30px_rgba(255,204,92,0.6)] transition hover:scale-105">
            소식 먼저 받기 →
          </a>
        </div>
      </Reveal>
    </section>
  );
}

// MARK: - 자주 묻는 질문

const FAQ: [string, string][] = [
  ["정말 무료인가요?", "네. CoNo 는 GNU GPL v3 오픈소스예요. 광고도, 결제도 없어요."],
  ["어떤 Mac 에서 되나요?", `${release.minimumMacOS}. AI 반주는 Apple Silicon(M1 이상)에서 가장 부드러워요.`],
  ["어떤 음악 앱을 쓸 수 있나요?", "Mac 에서 소리를 내는 앱이면 대부분 돼요. Apple Music 은 곡 정보·재생 위치까지 가장 정확하고, 브라우저의 YouTube Music·YouTube, Spotify, 멜론도 곡 정보를 읽어 가사를 찾아요."],
  ["제 목소리나 음악이 어디로 보내지나요?", "아니요. 보컬 분리와 채점은 모두 Mac 안에서 해요. 인터넷은 가사를 찾을 때만 써요. 이 사이트의 체험도 브라우저 안에서만 음정을 재요."],
  ["가사가 안 나오거나 어긋나요", "가사를 찾지 못한 곡은 음정 바만 나와요. 조금 어긋나면 가사 위에 마우스를 올려 ± 로, 또는 [ ] 키로 맞추세요. 맞춘 값은 곡마다 기억해요."],
  ["블루투스 이어폰은요?", "돼요. 다만 블루투스는 소리가 늦게 나와서 화면이 앞서 보일 수 있어요. 설정 › 가사 › 화면 싱크를 +150~250ms 로 맞추세요. 블루투스 마이크는 이어폰 음질을 떨어뜨리니 채점은 Mac 마이크로."],
  ["YouTube 광고가 나오면요?", "광고를 알아채 소리를 끄고 가사 자리에 \"광고 재생 중\" 을 띄워요. 건너뛰기는 YouTube 에서 직접 눌러 주세요."],
  ["Windows 나 iPhone 은요?", "지금은 Mac 전용이에요. 원하시면 아래 의견에 남겨 주세요 — 많이 들리면 우선순위가 올라가요."],
];

export function Faq() {
  const [open, setOpen] = useState<number | null>(0);
  return (
    <section id="faq" className="relative px-4 py-24 sm:py-32">
      <SectionTitle kicker="FAQ" title="자주 묻는 질문" />
      <div className="mx-auto mt-12 max-w-3xl space-y-3">
        {FAQ.map(([question, answer], index) => {
          const isOpen = open === index;
          return (
            <div key={question} className={`overflow-hidden rounded-2xl border transition-colors ${isOpen ? "border-pink/40 bg-white/[0.05]" : "border-white/10 bg-white/[0.02]"}`}>
              <button
                type="button"
                onClick={() => setOpen(isOpen ? null : index)}
                aria-expanded={isOpen}
                className="flex w-full items-center justify-between gap-4 px-5 py-4 text-left"
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
    </section>
  );
}

// MARK: - 다운로드

export function Download() {
  const [copied, setCopied] = useState(false);
  return (
    <section id="download" className="relative overflow-hidden px-4 py-28 sm:py-36">
      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(ellipse_at_center,rgba(255,204,92,0.14),transparent_60%)]" />
      <div className="relative mx-auto max-w-3xl text-center">
        <Image src="/app-icon.png" alt="CoNo 앱 아이콘" width={128} height={128} className="mx-auto rounded-[28px] shadow-[0_20px_60px_rgba(255,143,176,0.35)]" />
        <h2 className="mt-8 font-display text-[clamp(40px,8vw,72px)] leading-none">
          <span className="neon neon-gold">오늘 밤,</span> <span className="neon">우리 집이 무대</span>
        </h2>
        <p className="mt-5 text-ink2">무료 · 오픈소스 · Apple 공증 완료</p>
        <a
          href={release.downloadUrl}
          className="group relative mt-9 inline-flex items-center gap-3 rounded-full bg-gold px-10 py-5 font-cute text-2xl text-night shadow-[0_0_50px_rgba(255,204,92,0.6)] transition hover:scale-105"
        >
          Mac 용 다운로드
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
    </section>
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
              await navigator.share({ title: "CoNo — 집에서 나만의 노래방", text: "Mac 에서 열어서 설치하기", url });
              return;
            }
            await navigator.clipboard.writeText(url);
            setNote("링크를 복사했어요. Mac 으로 보내 주세요");
          } catch {
            // 공유 창을 닫은 경우
          }
        }}
        className="rounded-full border border-white/20 bg-white/5 px-6 py-3 font-cute text-lg"
      >
        📲 Mac 으로 링크 보내기
      </button>
      <p className="mt-2 h-4 text-xs text-mint">{note ?? ""}</p>
    </div>
  );
}

// MARK: - 바닥글

export function Footer() {
  return (
    <footer className="border-t border-white/10 px-4 py-10 text-sm text-faint">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 sm:flex-row">
        <div className="flex items-center gap-3">
          <Image src="/app-icon.png" alt="" width={28} height={28} className="rounded-lg" />
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
        </div>
      </div>
    </footer>
  );
}
