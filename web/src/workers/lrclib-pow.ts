// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { parseChallenge, solvePublishChallenge } from "../lib/lrclib-publish";
self.onmessage = async (event: MessageEvent<unknown>) => {
  try { self.postMessage({ token: await solvePublishChallenge(parseChallenge(event.data)) }); }
  catch (error) { self.postMessage({ error: error instanceof Error ? error.message : "인증 계산을 마치지 못했어요." }); }
};
