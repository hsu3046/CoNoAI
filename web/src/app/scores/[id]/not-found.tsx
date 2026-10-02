import Link from "next/link";
export default function MissingScore() {
  return <main className="grid min-h-dvh place-items-center p-8 text-center"><div><h1 className="font-cute text-3xl">공유된 기록을 찾지 못했어요.</h1><p className="mt-4 text-ink2">삭제되었거나 공개가 해제된 기록일 수 있어요.</p><Link className="mt-6 inline-block text-mint underline" href="/#challenge">챌린지로 돌아가기</Link></div></main>;
}
