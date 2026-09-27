// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import { Feedback } from "@/components/Feedback";
import { Hero, SiteHeader } from "@/components/Hero";
import { ListenSection } from "@/components/ListenSection";
import { ChallengeTeaser, Download, Faq, Features, Footer, HowTo, Shortcuts, Videos } from "@/components/Sections";
import { SectionPager } from "@/components/SectionPager";
import { StoryScroll } from "@/components/StoryScroll";
import { TryItLive } from "@/components/TryItLive";

export default function Home() {
  return (
    <>
      <SiteHeader />
      <main>
        <Hero />
        <StoryScroll />
        <ListenSection />
        <TryItLive />
        <Features />
        <HowTo />
        <Shortcuts />
        <Videos />
        <ChallengeTeaser />
        <Faq />
        <Download />
        <Feedback />
      </main>
      <Footer />
      <SectionPager />
    </>
  );
}
