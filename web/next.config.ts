// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  experimental: {
    // 개발 서버 파일시스템 캐시는 계속 커지며 RSC 실패를 일으킨 적이 있어 끈다 (전역 TOOL_GOTCHAS)
    turbopackFileSystemCacheForDev: false,
  },
};

export default nextConfig;
