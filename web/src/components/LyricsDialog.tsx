// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
"use client";
import { useEffect, useRef, type ReactNode } from "react";
export function LyricsDialog({ title, children, onClose, locked = false }: { title: string; children: ReactNode; onClose: () => void; locked?: boolean }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => { const dialog = ref.current; dialog?.showModal(); return () => { dialog?.close(); }; }, []);
  return <dialog ref={ref} aria-label={title} onCancel={(event) => { event.preventDefault(); if (!locked) onClose(); }} className="fixed m-auto max-h-[90dvh] w-[min(94vw,48rem)] overflow-y-auto rounded-3xl border border-white/20 bg-night p-6 text-ink shadow-2xl backdrop:bg-black/75 sm:p-8">
    <h2 className="font-cute text-3xl text-mint">{title}</h2>
    {children}
  </dialog>;
}
