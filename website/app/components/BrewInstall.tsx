"use client";

import { useEffect, useState } from "react";

/* The Homebrew install command from README.md, with a button that copies it.
   The cask is steelbrain/tap/lemurcam in github.com/steelbrain/homebrew-tap. */

const COMMAND = "brew install --cask steelbrain/tap/lemurcam";

export default function BrewInstall() {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 2000);
    return () => clearTimeout(timer);
  }, [copied]);

  const copy = () => {
    navigator.clipboard
      ?.writeText(COMMAND)
      .then(() => setCopied(true))
      .catch(() => {});
  };

  return (
    <div className="mt-10">
      <h2 className="text-[15px] font-semibold">Install with Homebrew</h2>
      <div className="mt-3 flex items-start gap-3 rounded-lg border border-line bg-stage py-2 pr-2 pl-4">
        <code className="min-w-0 flex-1 py-1.5 font-mono text-sm leading-relaxed">{COMMAND}</code>
        <button
          type="button"
          onClick={copy}
          className="shrink-0 rounded-md border border-line bg-bg px-3 py-1.5 text-sm font-medium hover:brightness-95 dark:hover:brightness-125"
        >
          <span aria-live="polite">{copied ? "Copied" : "Copy"}</span>
        </button>
      </div>
    </div>
  );
}
