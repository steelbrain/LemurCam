"use client";

import { useEffect, useMemo, useRef, useState, type ReactNode, type SVGProps } from "react";
import { usePrefersReducedMotion } from "./usePrefersReducedMotion";

/* Shared pieces of the macOS recreations: window chrome, controls and the SF
   Symbols the SwiftUI views name, redrawn as simple SVG shapes (the real
   symbols are Apple's and are not used here). Colors come from the --mac-*
   tokens in globals.css, which follow the visitor's light or dark setting the
   way macOS does. */

type IconProps = SVGProps<SVGSVGElement>;

const stroke = {
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.7,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
  viewBox: "0 0 24 24",
  "aria-hidden": true,
};

// ---------------------------------------------------------------------------
// SF Symbols named by the app, as approximate outlines
// ---------------------------------------------------------------------------

/** video.fill */
export function VideoFill(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden {...props}>
      <rect x="2" y="6" width="14" height="12" rx="3" />
      <path d="M17.5 10.4 22 7.6v8.8l-4.5-2.8Z" />
    </svg>
  );
}

/** mic.fill */
export function MicFill(props: IconProps) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden {...props}>
      <rect x="8.5" y="2" width="7" height="12.5" rx="3.5" />
      <path
        d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3M8.5 21.5h7"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
      />
    </svg>
  );
}

/** video.badge.plus */
export function VideoBadgePlus(props: IconProps) {
  return (
    <svg {...stroke} {...props}>
      <path d="M8 6.5h6a3 3 0 0 1 3 3v5a3 3 0 0 1-3 3H9.5" />
      <path d="M17 10.4 21.5 7.6v8.8L17 13.6" />
      <circle cx="6" cy="15.5" r="4" fill="currentColor" stroke="none" />
      <path d="M6 13.4v4.2M3.9 15.5h4.2" stroke="var(--tile-ink, #fff)" />
    </svg>
  );
}

/** video.slash */
export function VideoSlash(props: IconProps) {
  return (
    <svg {...stroke} {...props}>
      <path d="M6 6.5h6.5a3 3 0 0 1 3 3v5M15.5 17.5H5.5a3 3 0 0 1-3-3v-5a3 3 0 0 1 1.6-2.7" />
      <path d="m15.5 10.2 5.5-2.9v9.4l-3-1.6" />
      <path d="M3 3.5 21 21" />
    </svg>
  );
}

/** web.camera (the menu bar item and the Cameras sidebar row) */
export function WebCamera(props: IconProps) {
  return (
    <svg {...stroke} {...props}>
      <circle cx="12" cy="10" r="6.5" />
      <circle cx="12" cy="10" r="2.4" />
      <path d="M12 16.5V20M8 20.5h8" />
    </svg>
  );
}

/** gear / gearshape */
export function Gear(props: IconProps) {
  return (
    <svg {...stroke} {...props}>
      <circle cx="12" cy="12" r="3" />
      <path d="M12 3.2 13.4 5a7.3 7.3 0 0 1 2.2.9l2.2-.4.9 1.6-1 2a7 7 0 0 1 .5 2.3l1.6 1.4-.6 1.8-2.2.4a7.2 7.2 0 0 1-1.5 1.8l.1 2.2-1.7.8-1.7-1.4a7.3 7.3 0 0 1-2.4 0l-1.7 1.4-1.7-.8.1-2.2a7.2 7.2 0 0 1-1.5-1.8l-2.2-.4-.6-1.8 1.6-1.4a7 7 0 0 1 .5-2.3l-1-2 .9-1.6 2.2.4A7.3 7.3 0 0 1 10.6 5Z" />
    </svg>
  );
}

/** checklist */
export function Checklist(props: IconProps) {
  return (
    <svg {...stroke} {...props}>
      <path d="m3 7 1.6 1.6L7.5 5.5" />
      <circle cx="5" cy="16" r="2.2" />
      <path d="M10.5 7.5H21M10.5 16H21" />
    </svg>
  );
}

/** eye */
export function Eye(props: IconProps) {
  return (
    <svg {...stroke} {...props}>
      <path d="M2.5 12S6 5.8 12 5.8 21.5 12 21.5 12 18 18.2 12 18.2 2.5 12 2.5 12Z" />
      <circle cx="12" cy="12" r="2.8" fill="currentColor" />
    </svg>
  );
}

/** doc.text */
export function DocText(props: IconProps) {
  return (
    <svg {...stroke} {...props}>
      <path d="M6.5 3h7.5l3.5 3.5V21h-11V3Z" />
      <path d="M14 3v4h3.5M9.5 12h5M9.5 15.5h5" />
    </svg>
  );
}

/** arrow.clockwise.circle */
export function ArrowClockwiseCircle(props: IconProps) {
  return (
    <svg {...stroke} {...props}>
      <circle cx="12" cy="12" r="9.5" />
      <path d="M15.8 9.6a4.5 4.5 0 1 0 .6 3.6" />
      <path d="M16.2 6.8v3.1h-3.1" />
    </svg>
  );
}

/** wrench.and.screwdriver */
export function WrenchScrewdriver(props: IconProps) {
  return (
    <svg {...stroke} {...props}>
      <path d="M14.5 4.2a4 4 0 0 0-4.8 5.1L3.6 15.4a1.6 1.6 0 0 0 2.3 2.3l6.1-6.1a4 4 0 0 0 5.1-4.8l-2.4 2.4-2.1-.4-.4-2.1Z" />
      <path d="m13.5 13.5 5 5a1.4 1.4 0 0 0 2-2l-5-5M19.5 3.5l1 1-3 3" />
    </svg>
  );
}

/** antenna.radiowaves.left.and.right */
export function Antenna(props: IconProps) {
  return (
    <svg {...stroke} {...props}>
      <circle cx="12" cy="10" r="1.6" />
      <path d="M12 11.6V21M8.5 6.5a5 5 0 0 0 0 7M15.5 6.5a5 5 0 0 1 0 7M5.6 3.6a9 9 0 0 0 0 12.8M18.4 3.6a9 9 0 0 1 0 12.8" />
    </svg>
  );
}

/** plus */
export function Plus(props: IconProps) {
  return (
    <svg {...stroke} {...props}>
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

/** sidebar.left */
export function SidebarLeft(props: IconProps) {
  return (
    <svg {...stroke} {...props}>
      <rect x="3" y="5" width="18" height="14" rx="3" />
      <path d="M9.5 5v14M5.5 8.5h1.5M5.5 11h1.5M5.5 13.5h1.5" />
    </svg>
  );
}

/** The up/down chevrons of a pop-up button. */
function Chevrons(props: IconProps) {
  return (
    <svg viewBox="0 0 10 14" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden {...props}>
      <path d="M2 5.5 5 2.5l3 3M2 8.5l3 3 3-3" />
    </svg>
  );
}

/** checkmark */
export function Checkmark(props: IconProps) {
  return (
    <svg {...stroke} strokeWidth={2.2} {...props}>
      <path d="m5 12.5 4.5 4.5L19 7" />
    </svg>
  );
}

// ---------------------------------------------------------------------------
// Status glyphs: checkmark.circle.fill, exclamationmark.circle.fill,
// xmark.circle.fill, circle, and the small ProgressView spinner
// ---------------------------------------------------------------------------

export type StepState = "inactive" | "working" | "actionNeeded" | "ready" | "failed";

export function CircleFill({
  kind,
  className,
}: {
  kind: "check" | "exclamation" | "xmark";
  className?: string;
}) {
  const fill =
    kind === "check" ? "var(--mac-green)" : kind === "exclamation" ? "var(--mac-orange)" : "var(--mac-red)";
  return (
    <svg viewBox="0 0 16 16" aria-hidden className={className}>
      <circle cx="8" cy="8" r="7.5" fill={fill} />
      {kind === "check" && (
        <path d="m4.8 8.2 2.2 2.2 4.2-4.6" fill="none" stroke="#fff" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
      )}
      {kind === "exclamation" && (
        <>
          <path d="M8 4.2v4.6" stroke="#fff" strokeWidth="1.8" strokeLinecap="round" />
          <circle cx="8" cy="11.4" r="1.05" fill="#fff" />
        </>
      )}
      {kind === "xmark" && (
        <path d="m5.4 5.4 5.2 5.2m0-5.2-5.2 5.2" stroke="#fff" strokeWidth="1.7" strokeLinecap="round" />
      )}
    </svg>
  );
}

/** ProgressView() — the macOS spinning spokes. */
export function Spinner({ className = "h-3.5 w-3.5", label }: { className?: string; label?: string }) {
  return (
    <svg
      viewBox="0 0 16 16"
      className={`mac-spinner ${className}`}
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
    >
      {Array.from({ length: 8 }, (_, i) => (
        <line
          key={i}
          x1="8"
          y1="1.6"
          x2="8"
          y2="4.6"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinecap="round"
          opacity={0.2 + (i / 7) * 0.8}
          transform={`rotate(${i * 45} 8 8)`}
        />
      ))}
    </svg>
  );
}

// ---------------------------------------------------------------------------
// Window chrome
// ---------------------------------------------------------------------------

/** Close, minimize, zoom. LemurCam's Settings and setup windows are closable
    only, so minimize and zoom are drawn disabled (gray), as macOS shows them. */
export function TrafficLights() {
  return (
    <span className="flex shrink-0 gap-[9px]" aria-hidden>
      <span className="h-[14px] w-[14px] rounded-full bg-[#ff5f57] ring-[0.5px] ring-black/10" />
      <span className="h-[14px] w-[14px] rounded-full bg-mac-control ring-[0.5px] ring-black/5" />
      <span className="h-[14px] w-[14px] rounded-full bg-mac-control ring-[0.5px] ring-black/5" />
    </span>
  );
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

export function MacButton({
  children,
  onClick,
  variant = "push",
  size = "regular",
  disabled = false,
  ariaLabel,
  title,
  className = "",
}: {
  children: ReactNode;
  onClick?: () => void;
  variant?: "push" | "prominent" | "destructive" | "borderless";
  size?: "small" | "regular" | "large";
  disabled?: boolean;
  ariaLabel?: string;
  title?: string;
  className?: string;
}) {
  const look =
    variant === "prominent"
      ? "bg-mac-accent text-white hover:brightness-105"
      : variant === "destructive"
        ? "bg-mac-control text-mac-red hover:bg-mac-control-hover"
        : variant === "borderless"
          ? "bg-transparent text-mac-secondary hover:text-mac-label"
          : "bg-mac-control text-mac-label hover:bg-mac-control-hover";
  const dims =
    size === "small"
      ? "h-[20px] rounded-[5px] px-2 text-[11px]"
      : size === "large"
        ? "h-[30px] rounded-full px-4 text-[14px]"
        : "h-[24px] rounded-[6px] px-3 text-[13px]";
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-label={ariaLabel}
      title={title}
      className={`inline-flex shrink-0 cursor-pointer items-center justify-center gap-1.5 whitespace-nowrap disabled:cursor-default disabled:opacity-45 ${look} ${dims} ${className}`}
    >
      {children}
    </button>
  );
}

/** A grouped-Form pop-up: the selected value, then chevrons in a small round well. */
export function FormPopUp<T extends string>({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: T;
  options: readonly { value: T; label: string }[];
  onChange: (value: T) => void;
}) {
  return (
    <span className="relative inline-flex items-center">
      <select
        aria-label={label}
        value={value}
        onChange={(e) => onChange(e.target.value as T)}
        className="cursor-pointer rounded-[6px] py-0.5 pr-8 pl-1.5 text-right text-[13px]"
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
      <span className="pointer-events-none absolute right-0 inline-flex h-[20px] w-[20px] items-center justify-center rounded-full bg-mac-control text-mac-label">
        <Chevrons className="h-[11px] w-[8px]" />
      </span>
    </span>
  );
}

/** A bordered pop-up button (a Picker outside a Form). */
export function PopUpButton<T extends string>({
  label,
  value,
  options,
  onChange,
  size = "regular",
  className = "",
}: {
  label: string;
  value: T;
  options: readonly { value: T; label: string }[];
  onChange: (value: T) => void;
  size?: "small" | "regular";
  className?: string;
}) {
  const dims =
    size === "small" ? "h-[20px] pl-2 pr-6 text-[11px] rounded-[5px]" : "h-[24px] pl-2.5 pr-7 text-[13px] rounded-[6px]";
  return (
    <span className={`relative inline-flex items-center ${className}`}>
      <select
        aria-label={label}
        value={value}
        onChange={(e) => onChange(e.target.value as T)}
        className={`w-full cursor-pointer bg-mac-control hover:bg-mac-control-hover ${dims}`}
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
      <Chevrons
        className={`pointer-events-none absolute text-mac-label ${
          size === "small" ? "right-1.5 h-[10px] w-[7px]" : "right-2 h-[11px] w-[8px]"
        }`}
      />
    </span>
  );
}

export function Toggle({
  on,
  onChange,
  label,
}: {
  on: boolean;
  onChange: () => void;
  label: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={label}
      onClick={onChange}
      className={`relative h-[22px] w-[40px] shrink-0 cursor-pointer rounded-full transition-colors duration-200 ${
        on ? "bg-mac-accent" : "bg-mac-switch-off"
      }`}
    >
      <span
        className={`absolute top-[2px] h-[18px] w-[24px] rounded-full bg-white shadow-[0_1px_2px_rgba(0,0,0,0.25)] transition-[left] duration-200 ${
          on ? "left-[14px]" : "left-[2px]"
        }`}
      />
    </button>
  );
}

/** A grouped-Form section: optional header above a rounded group of rows. */
export function FormSection({ header, children }: { header?: string; children: ReactNode }) {
  return (
    <section>
      {header && <h4 className="mb-2 px-2.5 text-[13px] font-bold text-mac-label">{header}</h4>}
      <div className="divide-y divide-mac-sep rounded-[12px] bg-mac-group px-2.5 text-[13px]">{children}</div>
    </section>
  );
}

export function FormRow({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex min-h-[36px] items-center justify-between gap-3 py-1.5">
      <span>{label}</span>
      {children}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Sample video: a test card with a running timecode, standing in for camera
// video. Drawn at 1920x1080 and scaled to fit its box, as the app's preview
// scales a frame (`.scaledToFit()`), leaving black bars around it.
// ---------------------------------------------------------------------------

const TOP_BARS = ["#c0c0c0", "#c0c000", "#00c0c0", "#00c000", "#c000c0", "#c00000", "#0000c0"];
const MID_BARS = ["#0000c0", "#131313", "#c000c0", "#131313", "#00c0c0", "#131313", "#c0c0c0"];

function useTimecode(fps: number) {
  const reducedMotion = usePrefersReducedMotion();
  const [tc, setTc] = useState("00:00:00:00");

  useEffect(() => {
    if (reducedMotion) return;
    const start = performance.now();
    const pad = (n: number) => String(n).padStart(2, "0");
    const id = setInterval(() => {
      const ms = performance.now() - start;
      const f = Math.floor((ms / (1000 / fps)) % fps);
      const s = Math.floor(ms / 1000);
      setTc(`${pad(Math.floor(s / 3600))}:${pad(Math.floor((s / 60) % 60))}:${pad(s % 60)}:${pad(f)}`);
    }, 100);
    return () => clearInterval(id);
  }, [reducedMotion, fps]);

  return tc;
}

export function TestPattern({ fps }: { fps: number }) {
  const tc = useTimecode(fps);
  const bar = 1920 / 7;
  return (
    <svg
      viewBox="0 0 1920 1080"
      preserveAspectRatio="xMidYMid meet"
      className="block h-full w-full"
      role="img"
      aria-label="Sample video: a test pattern with a running timecode"
    >
      {TOP_BARS.map((c, i) => (
        <rect key={`t${i}`} x={i * bar} y={0} width={bar + 1} height={720} fill={c} />
      ))}
      {MID_BARS.map((c, i) => (
        <rect key={`m${i}`} x={i * bar} y={720} width={bar + 1} height={90} fill={c} />
      ))}
      <rect x={0} y={810} width={1920} height={270} fill="#131313" />
      <rect x={0} y={810} width={343} height={270} fill="#00214c" />
      <rect x={343} y={810} width={343} height={270} fill="#ffffff" />
      <rect x={686} y={810} width={343} height={270} fill="#32006a" />
      <rect x={1380} y={890} width={480} height={120} rx={10} fill="rgba(0,0,0,0.75)" />
      <text
        x={1620}
        y={973}
        textAnchor="middle"
        fill="#ffffff"
        fontSize={68}
        fontFamily="ui-monospace, SFMono-Regular, Menlo, monospace"
      >
        {tc}
      </text>
    </svg>
  );
}

// ---------------------------------------------------------------------------
// Timers
// ---------------------------------------------------------------------------

/** setTimeout calls that are cleared together, and on unmount. */
export function useTimeouts() {
  const ids = useRef(new Set<ReturnType<typeof setTimeout>>());

  useEffect(() => {
    const pending = ids.current;
    return () => {
      pending.forEach(clearTimeout);
      pending.clear();
    };
  }, []);

  return useMemo(
    () => ({
      after(ms: number, run: () => void) {
        const id = setTimeout(() => {
          ids.current.delete(id);
          run();
        }, ms);
        ids.current.add(id);
      },
      cancelAll() {
        ids.current.forEach(clearTimeout);
        ids.current.clear();
      },
    }),
    []
  );
}
