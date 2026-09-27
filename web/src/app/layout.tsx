// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import type { Metadata, Viewport } from "next";
import { Black_Han_Sans, Jua, Noto_Sans_KR } from "next/font/google";
import "./globals.css";

// 한글 글꼴은 크기가 커서 미리 받지 않는다 (글자가 필요할 때 조각별로)
const display = Black_Han_Sans({ weight: "400", subsets: ["latin"], variable: "--font-black-han-sans", preload: false, display: "swap" });
const cute = Jua({ weight: "400", subsets: ["latin"], variable: "--font-jua", preload: false, display: "swap" });
const body = Noto_Sans_KR({ weight: ["400", "500", "700", "900"], subsets: ["latin"], variable: "--font-noto-sans-kr", preload: false, display: "swap" });

const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? "https://cono.aib.vote";

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: "CoNo — 코인 노래방 No! 집에서 나만의 노래방",
  description:
    "듣던 노래 그대로 노래방으로. Apple Music·YouTube Music·Spotify 등 Mac 에서 나오는 노래의 목소리를 AI 로 지우고, 가사·음정 바·채점까지. 무료 macOS 앱.",
  applicationName: "CoNo",
  keywords: ["노래방", "가라오케", "Mac", "AI 반주", "보컬 제거", "음정", "채점", "CoNo"],
  openGraph: {
    title: "CoNo — 코인 노래방 No! 집에서 나만의 노래방",
    description: "듣던 노래가 그대로 노래방이 됩니다. AI 반주 · 가사 · 음정 바 · 채점과 불꽃놀이.",
    siteName: "CoNo",
    locale: "ko_KR",
    type: "website",
    images: [{ url: "/og.png", width: 1200, height: 630, alt: "코인 노래방 No! 집에서 나만의 노래방 — CoNo" }],
  },
  twitter: { card: "summary_large_image", images: ["/og.png"] },
  icons: { icon: "/app-icon-dark.png", apple: "/app-icon-dark.png" },
};

export const viewport: Viewport = {
  themeColor: "#0b0d1a",
  colorScheme: "dark",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="ko" className={`${display.variable} ${cute.variable} ${body.variable}`}>
      <body className="min-h-dvh">{children}</body>
    </html>
  );
}
