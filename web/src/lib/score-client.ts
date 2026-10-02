// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import { parseRecord, scoreText, type ScoreRecord } from "./score-record";
export type HistoryRecord = ScoreRecord & { published: boolean };
export type HistoryResponse = { nickname: string; records: HistoryRecord[] };
export type ChallengeResponse = { week: string; entries: { record: ScoreRecord; nickname: string }[] };

export async function requestJSON<T>(url: string, body?: unknown): Promise<T> {
  const response = await fetch(url, { method: body === undefined ? "GET" : "POST", cache: "no-store", headers: body === undefined ? undefined : { "Content-Type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(10_000) });
  const data = await response.json();
  if (!response.ok) throw new Error(typeof data.error === "string" ? data.error : "요청을 처리하지 못했어요.");
  return data as T;
}
export async function changeScores(body: unknown) {
  await requestJSON("/api/scores", body);
  window.dispatchEvent(new Event("cono-scores-changed"));
}
export function downloadBlob(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url; link.download = name; link.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}
export function exportScores(records: ScoreRecord[]) {
  downloadBlob(new Blob([JSON.stringify({ schemaVersion: 1, records: records.map(parseRecord) }, null, 2)], { type: "application/json" }), "cono-scores.json");
}
export async function shareRecord(record: ScoreRecord, url?: string): Promise<string> {
  const text = scoreText(record);
  if (navigator.share) {
    try { await navigator.share({ title: "CoNo 점수", text, ...(url ? { url } : {}) }); return "공유했어요."; }
    catch (error) { if (error instanceof DOMException && error.name === "AbortError") return ""; }
  }
  await navigator.clipboard.writeText(url ? `${text}\n${url}` : text);
  return "복사했어요. 친구에게 붙여넣어 주세요.";
}
export async function saveScoreImage(record: ScoreRecord) {
  await document.fonts.ready;
  const canvas = document.createElement("canvas");
  canvas.width = 1200; canvas.height = 630;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("이미지를 만들지 못했어요.");
  const gradient = ctx.createLinearGradient(0, 0, 1200, 630);
  gradient.addColorStop(0, "#0b0d1a"); gradient.addColorStop(1, "#29123e");
  ctx.fillStyle = gradient; ctx.fillRect(0, 0, 1200, 630);
  ctx.strokeStyle = "#5ee0b8"; ctx.lineWidth = 5; ctx.strokeRect(32, 32, 1136, 566);
  const font = 'system-ui, -apple-system, sans-serif';
  ctx.fillStyle = "#5ee0b8"; ctx.font = `bold 30px ${font}`; ctx.fillText("CoNo · MY STAGE", 80, 110);
  ctx.fillStyle = "#ffcc5c"; ctx.font = `bold 210px ${font}`; ctx.fillText(String(record.score), 70, 350);
  const scoreWidth = ctx.measureText(String(record.score)).width;
  ctx.font = `32px ${font}`; ctx.fillText("점", 90 + scoreWidth, 345);
  ctx.fillStyle = "#edf0ff"; ctx.font = `bold 40px ${font}`; ctx.fillText(record.title, 80, 432, 1030);
  ctx.fillStyle = "#b8bdd4"; ctx.font = `26px ${font}`; ctx.fillText(`${record.artist} · 음표 ${record.notesHit}/${record.notesTotal} · 최고 연속 ${record.bestStreak}`, 80, 487, 1030);
  ctx.font = `22px ${font}`; ctx.fillText(`${record.source === "macos" ? "Mac" : record.source === "demo" ? "데모" : "브라우저"} · ${record.difficulty === "hard" ? "어려움" : "보통"} · ${record.createdAt.slice(0, 10)} · AIB Inc.`, 80, 548);
  const blob = await new Promise<Blob>((resolve, reject) => canvas.toBlob((value) => value ? resolve(value) : reject(new Error("이미지를 저장하지 못했어요.")), "image/png"));
  downloadBlob(blob, `cono-${record.score}-${record.id.slice(0, 8)}.png`);
}
