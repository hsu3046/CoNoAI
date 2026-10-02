// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
"use client";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { decodeLyricsFile, lyricsLines, MAX_LYRICS_BYTES, parseLyricsInput, type LyricsFormat, type LyricsInput, type LyricsRecord } from "@/lib/lyrics-record";
import { downloadLyrics, lyricsRequest } from "@/lib/lyrics-client";
import { scoreButton } from "./ScoreActions";
import { LyricsDialog } from "./LyricsDialog";
import { LyricsPublish } from "./LyricsPublish";

type Form = Omit<LyricsInput, "duration"> & { duration: string };
const empty: Form = { title: "", artist: "", album: "", duration: "", format: "plain", content: "" };
const inputClass = "mt-2 w-full rounded-xl border border-white/20 bg-black/25 px-3 py-2.5 text-base outline-none focus:border-mint disabled:opacity-60";
function formOf(record: LyricsInput): Form { return { ...record, duration: record.duration === null ? "" : String(record.duration) }; }
function message(error: unknown): string { return error instanceof Error ? error.message : "처리하지 못했어요. 입력 내용은 그대로입니다."; }

export function LyricsLibrary() {
  const [records, setRecords] = useState<LyricsRecord[] | null>(null);
  const [form, setForm] = useState<Form>(empty);
  const [baseline, setBaseline] = useState(JSON.stringify(empty));
  const [selected, setSelected] = useState<LyricsRecord | null>(null);
  const [query, setQuery] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [deleteRecord, setDeleteRecord] = useState<LyricsRecord | null>(null);
  const [switchTo, setSwitchTo] = useState<{ record: LyricsRecord | null } | null>(null);
  const [publication, setPublication] = useState<LyricsRecord | null>(null);
  const generation = useRef(0);
  const creationID = useRef<string | null>(null);
  const dirty = JSON.stringify(form) !== baseline;
  const load = useCallback(() => {
    const ticket = ++generation.current;
    return lyricsRequest<{ records: LyricsRecord[] }>("/api/lyrics").then((data) => {
      if (ticket === generation.current) { setRecords(data.records); setError(""); }
    }).catch((error: unknown) => { if (ticket === generation.current) setError(message(error)); });
  }, []);
  useEffect(() => { void load(); const ref = generation; return () => { ref.current++; }; }, [load]);
  useEffect(() => {
    if (!dirty && !busy) return;
    const prevent = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = ""; };
    window.addEventListener("beforeunload", prevent);
    return () => window.removeEventListener("beforeunload", prevent);
  }, [dirty, busy]);
  const parsed = useMemo(() => {
    if (!form.content.trim()) return { lines: [], error: "" };
    try { return { lines: lyricsLines(form.content, form.format), error: "" }; }
    catch (error) { return { lines: [], error: message(error) }; }
  }, [form.content, form.format]);
  const choose = (record: LyricsRecord | null) => {
    const next = record ? formOf(record) : { ...empty };
    setSelected(record); setForm(next); setBaseline(JSON.stringify(next)); creationID.current = null;
    setSwitchTo(null); setNotice(""); setError("");
  };
  const requestChoose = (record: LyricsRecord | null) => { if (dirty) setSwitchTo({ record }); else choose(record); };
  const input = () => parseLyricsInput({ ...form, duration: form.duration.trim() ? Number(form.duration) : null });
  const save = async () => {
    if (busy || !records) return;
    let lyrics: LyricsInput;
    try { lyrics = input(); } catch (error) { setError(message(error)); return; }
    setBusy(true); setError(""); setNotice(""); ++generation.current;
    try {
      const id = selected?.id ?? (creationID.current ??= crypto.randomUUID());
      const { record } = await lyricsRequest<{ record: LyricsRecord }>("/api/lyrics", { action: selected ? "update" : "create", id, version: selected?.version, lyrics });
      setRecords((current) => [record, ...(current ?? []).filter((item) => item.id !== record.id)]);
      choose(record); setNotice("개인 보관함에 저장했어요. LRCLIB 공개는 별도로 선택해 주세요.");
    } catch (error) { setError(message(error)); }
    finally { setBusy(false); }
  };
  const remove = async () => {
    if (!deleteRecord || busy) return;
    setBusy(true); setError(""); ++generation.current;
    try {
      await lyricsRequest("/api/lyrics", { action: "delete", id: deleteRecord.id, version: deleteRecord.version });
      setRecords((current) => current?.filter((item) => item.id !== deleteRecord.id) ?? []);
      if (selected?.id === deleteRecord.id) choose(null);
      setDeleteRecord(null); setNotice("개인 보관함에서 삭제했어요. LRCLIB에 공개한 사본은 유지됩니다.");
    } catch (error) { setError(message(error)); setDeleteRecord(null); }
    finally { setBusy(false); }
  };
  const exportCurrent = (format: LyricsFormat) => {
    try {
      // 서버가 잠시 없어도 미저장 본문을 파일로 구할 수 있다.
      downloadLyrics({ ...form, duration: form.duration.trim() ? Number(form.duration) : null }, format);
      setNotice(`${format === "plain" ? "TXT" : "LRC"}로 내보냈어요. 개인 보관함 저장은 별도입니다.`); setError("");
    } catch (error) { setError(message(error)); }
  };
  const visible = records?.filter((record) => `${record.title} ${record.artist} ${record.album}`.toLocaleLowerCase().includes(query.toLocaleLowerCase())) ?? [];
  return <div className="mt-10 grid items-start gap-7 lg:grid-cols-[19rem_minmax(0,1fr)]">
    <aside className="space-y-4 rounded-3xl border border-white/10 bg-white/[0.035] p-5" aria-label="내 가사 목록">
      <div className="flex items-center justify-between"><h2 className="font-cute text-2xl text-mint">내 보관함 <span className="text-base text-ink2">{records?.length ?? "—"}</span></h2><button className={scoreButton} disabled={busy} onClick={() => requestChoose(null)}>새 가사</button></div>
      <input aria-label="가사 제목·가수·앨범 검색" className={inputClass} placeholder="제목·가수·앨범 검색" value={query} onChange={(event) => setQuery(event.target.value)} />
      <button className="text-sm text-sky underline disabled:opacity-50" disabled={busy} onClick={() => void load()}>목록 새로고침</button>
      {records === null ? <p className="text-sm text-ink2">{error ? "보관함을 연결하지 못했어요. 새로고침으로 다시 시도할 수 있습니다." : "보관함을 읽는 중…"}</p> : !visible.length ? <p className="py-6 text-sm text-ink2">{query ? "검색 결과가 없어요." : "아직 저장한 가사가 없어요. 직접 적거나 TXT/LRC 파일을 가져와 보세요."}</p> : <ul className="max-h-[32rem] space-y-2 overflow-y-auto">
        {visible.map((record) => <li key={record.id}><button disabled={busy} aria-current={selected?.id === record.id ? "true" : undefined} onClick={() => requestChoose(record)} className={`w-full rounded-2xl border p-4 text-left transition hover:border-mint/50 disabled:opacity-50 ${selected?.id === record.id ? "border-mint/50 bg-mint/10" : "border-white/10 bg-black/20"}`}><span className="block font-cute text-xl">{record.title}</span><span className="mt-1 block text-sm text-ink2">{record.artist} · {record.format === "lrc" ? "시각 가사" : "일반 가사"}</span><span className="mt-2 block text-xs text-ink2">비공개 · {new Date(record.updatedAt).toLocaleDateString("ko-KR")}</span></button></li>)}
      </ul>}
      <p className="border-t border-white/10 pt-4 text-xs leading-relaxed text-ink2">로컬 테스트 · 이 서버의 JSON에 비공개로 저장됩니다. 쿠키를 지우거나 브라우저를 바꾸기 전에 TXT/LRC로 백업하세요.</p>
    </aside>
    <section className="min-w-0 rounded-3xl border border-white/10 bg-gradient-to-br from-white/[0.055] to-pink/[0.025] p-5 sm:p-7" aria-label="가사 편집">
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3"><h2 className="font-cute text-3xl">{selected ? "가사 편집" : "나의 가사 등록"}</h2><span className="rounded-full border border-mint/30 px-3 py-1 text-xs text-mint">{dirty ? "저장 전 초안" : selected ? "개인 보관함 저장됨" : "나만 볼 수 있어요"}</span></div>
      <form onSubmit={(event) => { event.preventDefault(); void save(); }}>
        <fieldset disabled={busy} className="space-y-5">
          <div className="grid gap-4 sm:grid-cols-2">
            <label className="text-sm text-ink2">곡 제목 <span className="text-pink">필수</span><input className={inputClass} value={form.title} required maxLength={200} onChange={(event) => setForm({ ...form, title: event.target.value })} placeholder="곡 제목" /></label>
            <label className="text-sm text-ink2">가수 <span className="text-pink">필수</span><input className={inputClass} value={form.artist} required maxLength={200} onChange={(event) => setForm({ ...form, artist: event.target.value })} placeholder="가수 이름" /></label>
            <label className="text-sm text-ink2">앨범 <span className="text-xs">선택</span><input className={inputClass} value={form.album} maxLength={200} onChange={(event) => setForm({ ...form, album: event.target.value })} placeholder="앨범 이름" /></label>
            <label className="text-sm text-ink2">실제 곡 길이(초) <span className="text-xs">선택 · 공개 시 필요</span><input className={inputClass} type="number" min="0.001" max="86400" step="0.001" inputMode="decimal" value={form.duration} onChange={(event) => setForm({ ...form, duration: event.target.value })} placeholder="예: 215.5" /></label>
          </div>
          <div className="flex flex-wrap items-center gap-4"><label className="flex items-center gap-2 text-sm"><input type="radio" className="accent-mint" name="lyrics-format" checked={form.format === "plain"} onChange={() => setForm({ ...form, format: "plain" })} />TXT 일반 가사</label><label className="flex items-center gap-2 text-sm"><input type="radio" className="accent-mint" name="lyrics-format" checked={form.format === "lrc"} onChange={() => setForm({ ...form, format: "lrc" })} />LRC 시각 가사</label>
            <label className={`${scoreButton} cursor-pointer`}>파일 가져오기<input aria-label="TXT 또는 LRC 가사 파일 가져오기" className="sr-only" type="file" accept=".txt,.lrc,text/plain" onChange={(event) => {
              const file = event.target.files?.[0]; event.target.value = "";
              if (!file || (form.content.trim() && !window.confirm("편집 중인 본문을 선택한 파일로 바꿀까요? 현재 내용을 보관하려면 취소 후 먼저 내보내 주세요."))) return;
              setBusy(true); setError("");
              void (async () => {
                try {
                  if (file.size > MAX_LYRICS_BYTES) throw new Error("파일은 1 MB까지 가져올 수 있어요.");
                  const imported = decodeLyricsFile(await file.arrayBuffer(), file.name);
                  setForm((current) => ({ ...current, ...imported })); setNotice(`${file.name}을 읽었어요. 제목·가수를 확인한 뒤 저장해 주세요.`);
                } catch (error) { setError(message(error)); }
                finally { setBusy(false); }
              })();
            }} /></label>
          </div>
          <label className="block text-sm text-ink2">가사 직접 입력·붙여넣기<textarea className={`${inputClass} min-h-72 resize-y font-mono leading-7`} value={form.content} onChange={(event) => setForm({ ...form, content: event.target.value })} placeholder={form.format === "plain" ? "한 줄씩 가사를 적어 주세요.\n아직 시각을 몰라도 저장할 수 있어요." : "[00:12.500] 첫 번째 가사\n[00:17.000] 다음 가사"} spellCheck={false} /></label>
          <p className="text-xs text-ink2">UTF-8 기준 1 MB · 4,000줄 · 한 줄 500글자까지. 일반 가사는 TXT로 Mac 앱에 가져와 시각을 맞출 수 있습니다.</p>
          {parsed.error && <p className="text-sm text-gold">{parsed.error}</p>}
          <div className="flex flex-wrap gap-3"><button className="rounded-full bg-mint px-6 py-2.5 font-cute text-lg text-night disabled:opacity-50" disabled={busy || records === null}>{busy ? "처리 중…" : selected ? "수정 저장" : "개인 보관함에 저장"}</button><button type="button" className={scoreButton} onClick={() => exportCurrent("plain")} disabled={!form.content.trim()}>TXT 내보내기</button><button type="button" className={scoreButton} onClick={() => exportCurrent("lrc")} disabled={form.format !== "lrc" || !form.content.trim()}>LRC 내보내기</button></div>
        </fieldset>
      </form>
      {error && <p role="alert" className="mt-5 text-sm text-stop">{error}</p>}
      <p role="status" className="mt-4 min-h-5 text-sm text-mint">{notice}</p>
      {selected && <div className="mt-6 flex flex-wrap gap-3 border-t border-white/10 pt-5"><button className={`${scoreButton} text-sky`} disabled={busy || dirty} onClick={() => setPublication(selected)}>LRCLIB 공개 검토…</button><button className={`${scoreButton} text-stop`} disabled={busy} onClick={() => setDeleteRecord(selected)}>개인 가사 삭제…</button>{dirty && <p className="w-full text-xs text-ink2">LRCLIB에 보낼 내용은 먼저 개인 보관함에 저장해 주세요.</p>}</div>}
      {!!parsed.lines.length && <details className="mt-6 rounded-2xl border border-white/10 p-4"><summary className="cursor-pointer font-cute text-lg">가사 미리보기 · {parsed.lines.length}줄</summary><div className="mt-4 max-h-80 space-y-2 overflow-y-auto text-sm">{parsed.lines.slice(0, 80).map((line, index) => <p key={index} className="flex gap-4"><span className="w-16 shrink-0 font-mono text-sky">{line.time === null ? "" : `${line.time.toFixed(2)}초`}</span><span className="whitespace-pre-wrap">{line.text || "(간주)"}</span></p>)}{parsed.lines.length > 80 && <p className="text-ink2">미리보기에는 처음 80줄을 표시합니다. 전체 내용은 위 편집기와 파일에 보존됩니다.</p>}</div></details>}
    </section>
    {deleteRecord && <LyricsDialog title="개인 가사를 삭제할까요?" onClose={() => setDeleteRecord(null)} locked={busy}><p className="my-5 text-ink2">‘{deleteRecord.title}’를 개인 보관함에서 삭제합니다.{dirty && " 편집 중인 미저장 내용도 사라집니다."} 필요하면 취소 후 TXT/LRC로 내보내 주세요. LRCLIB 공개본은 삭제되지 않습니다.</p><div className="flex justify-end gap-3"><button className={scoreButton} disabled={busy} onClick={() => setDeleteRecord(null)}>취소</button><button className={`${scoreButton} text-stop`} disabled={busy} onClick={() => void remove()}>삭제 확인</button></div></LyricsDialog>}
    {switchTo && <LyricsDialog title="저장 전 초안을 닫을까요?" onClose={() => setSwitchTo(null)}><p className="my-5 text-ink2">편집 중인 내용이 아직 저장되지 않았어요. 보관하려면 취소 후 저장하거나 TXT/LRC로 내보내 주세요.</p><div className="flex justify-end gap-3"><button className={scoreButton} onClick={() => setSwitchTo(null)}>계속 편집</button><button className={`${scoreButton} text-stop`} onClick={() => choose(switchTo.record)}>초안 버리고 이동</button></div></LyricsDialog>}
    {publication && <LyricsPublish record={publication} onClose={() => setPublication(null)} />}
  </div>;
}
