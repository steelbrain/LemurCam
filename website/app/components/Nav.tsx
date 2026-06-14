"use client";

import Image from "next/image";
import { useEffect, useState } from "react";
import { DownloadIcon, GithubIcon } from "./icons";

const DOWNLOAD_URL =
  "https://github.com/steelbrain/LemurCam/releases/latest";
const GITHUB_URL = "https://github.com/steelbrain/LemurCam";

const links = [
  { href: "#features", label: "Features" },
  { href: "#how", label: "How it works" },
  { href: "#cameras", label: "Cameras" },
];

export default function Nav() {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 12);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header
      className={`fixed inset-x-0 top-0 z-50 transition-all duration-300 ${
        scrolled
          ? "glass border-b border-border/70 py-2.5"
          : "border-b border-transparent py-4"
      }`}
    >
      <nav className="mx-auto flex max-w-6xl items-center justify-between px-5 sm:px-6">
        <a href="#top" className="group flex items-center gap-2.5">
          <Image
            src="/icon.png"
            alt="LemurCam"
            width={34}
            height={34}
            className="rounded-[9px] shadow-sm transition-transform duration-300 group-hover:-rotate-6"
            priority
          />
          <span className="text-[17px] font-semibold tracking-tight">
            LemurCam
          </span>
        </a>

        <div className="hidden items-center gap-7 md:flex">
          {links.map((l) => (
            <a
              key={l.href}
              href={l.href}
              className="text-sm font-medium text-muted transition-colors hover:text-foreground"
            >
              {l.label}
            </a>
          ))}
        </div>

        <div className="flex items-center gap-2">
          <a
            href={GITHUB_URL}
            target="_blank"
            rel="noreferrer"
            aria-label="LemurCam on GitHub"
            className="hidden h-9 w-9 items-center justify-center rounded-full text-muted transition-colors hover:bg-foreground/5 hover:text-foreground sm:flex"
          >
            <GithubIcon className="h-5 w-5" />
          </a>
          <a
            href={DOWNLOAD_URL}
            className="btn-shine inline-flex items-center gap-1.5 rounded-full bg-foreground px-4 py-2 text-sm font-semibold text-background transition-transform duration-200 hover:scale-[1.03] active:scale-95"
          >
            <DownloadIcon className="h-4 w-4" />
            Download
          </a>
        </div>
      </nav>
    </header>
  );
}
