"use client";

import Image from "next/image";
import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
  type SVGProps,
} from "react";
import {
  BroadcastIcon,
  CameraIcon,
  DocIcon,
  EyeIcon,
  GearIcon,
  ListIcon,
} from "./icons";
import { usePrefersReducedMotion } from "./usePrefersReducedMotion";

/* An interactive HTML recreation of the LemurCam Settings window. Labels,
   options, defaults and state changes mirror the SwiftUI views in App/Settings
   (SettingsView, StatusSettingsView, StatusCard, PreviewSettingsView,
   GeneralSettingsView, LogsSettingsView) and App/Sources/SourceListView.

   Deliberate liberties:
   - The two cameras and their stream details are samples. Log messages are the
     app's real Log calls, filled in with those samples; timestamps use the
     en-US format the app shows on an English (US) Mac.
   - The preview shows a test pattern in place of camera video.
   - Connecting a camera and removing/enabling the microphone run on short
     timers instead of real network and install work.
   - Buttons that open other windows or sheets (guided setup, add/discover
     camera), Re-check Now, and Restart Now's relaunch are not simulated;
     Restart Now only clears the restart notice.
   - The About section leaves out the "Version …" line so the site never shows
     a stale version. */

// macOS system colors (light appearance). The app uses the system accent color.
const ACCENT = "#007aff";
const GREEN = "#28cd41";
const GREEN_TEXT = "#1d9d43"; // darker than systemGreen so the text stays legible
const ORANGE = "#ff9500";

const BARS = [
  "#c8c8c8",
  "#f0e02e",
  "#2ec8c8",
  "#2ebe4e",
  "#e04ee0",
  "#e04040",
  "#3050e0",
];

const TABS = [
  { id: "status", label: "Setup & Status", icon: ListIcon },
  { id: "cameras", label: "Cameras", icon: CameraIcon },
  { id: "preview", label: "Preview", icon: EyeIcon },
  { id: "general", label: "General", icon: GearIcon },
  { id: "logs", label: "Logs", icon: DocIcon },
] as const;

type TabId = (typeof TABS)[number]["id"];

// ---------------------------------------------------------------------------
// Sample data
// ---------------------------------------------------------------------------

type Source = {
  id: string;
  name: string;
  kind: "rtsp" | "onvif";
  /** SourceListView subtitle: the RTSP URL, or "host:port" for ONVIF. */
  subtitle: string;
  width: number;
  height: number;
  codec: "h264" | "h265";
  /** `String(describing: audio.codec) @sampleRate` as RTSPStreamPipeline logs it. */
  audio: string;
  fps: number;
};

const SOURCES: Source[] = [
  {
    id: "backyard",
    name: "Backyard Cam",
    kind: "rtsp",
    subtitle: "rtsp://192.168.1.115:554/stream1",
    width: 1920,
    height: 1080,
    codec: "h264",
    audio: "aac @16000Hz",
    fps: 30,
  },
  {
    id: "front",
    name: "Front Door",
    kind: "onvif",
    subtitle: "192.168.1.82:80",
    width: 2560,
    height: 1440,
    codec: "h265",
    audio: "pcmu @8000Hz",
    fps: 25,
  },
];

// RTSPStreamPipeline.publishStreamInfo
const CODEC_NAME = { h264: "H.264", h265: "H.265" } as const;

// ConnectionStatusHelpers.swift (only the states this recreation reaches)
type ConnectionStatus = "connecting" | "connected";
const STATUS_LABEL: Record<ConnectionStatus, string> = {
  connecting: "Connecting",
  connected: "Connected",
};
const STATUS_COLOR: Record<ConnectionStatus, string> = {
  connecting: ORANGE,
  connected: GREEN,
};

// LemurCamConfig.Resolution / FrameRate, with their defaults.
const RESOLUTIONS = ["720p", "1080p", "1440p", "4K"] as const;
const FRAME_RATES = [30, 60] as const;
const DEFAULT_RESOLUTION = "1080p";
const DEFAULT_FRAME_RATE = 60;

type LogCategory = "app" | "ipc" | "rtsp";
type LogEntry = {
  id: number;
  time: string;
  category: LogCategory;
  level: "INFO";
  message: string;
};

// What a launch looks like up to the stream feeding the preview: sources load,
// the coordinator starts with no demand, opening Settings adds preview demand,
// and the active camera connects.
const LAUNCH_LOG: [string, LogCategory, string][] = [
  ["9:41:00.208 AM", "app", "Loaded 2 source(s)"],
  ["9:41:00.214 AM", "rtsp", "No demand — skipping RTSP connection"],
  ["9:41:01.032 AM", "ipc", "Device discovered, waiting for consumer demand"],
  ["9:41:01.390 AM", "app", "Boot sanity check complete"],
  ["9:41:03.517 AM", "rtsp", "Demand detected — resuming RTSP pipeline"],
  ["9:41:03.518 AM", "rtsp", "Connecting to source 'Backyard Cam'"],
  ["9:41:03.906 AM", "rtsp", "Format description created: 1920x1080"],
  ["9:41:03.907 AM", "rtsp", "Audio stream: aac @16000Hz"],
  ["9:41:03.907 AM", "rtsp", "Stream connected: h264"],
  ["9:41:04.114 AM", "rtsp", "Received keyframe"],
  ["9:41:04.121 AM", "rtsp", "Created decompression session"],
];

const INITIAL_LOGS: LogEntry[] = LAUNCH_LOG.map(([time, category, message], id) => ({
  id,
  time,
  category,
  level: "INFO",
  message,
}));

// New entries continue the sample log's clock (9:41:05 AM plus time on page),
// so they always sort after the launch lines.
const LOG_CLOCK_START_MS = (9 * 3600 + 41 * 60 + 5) * 1000;

/** Time of day formatted like `.dateTime.hour().minute().second().secondFraction(.fractional(3))` in en-US. */
function formatLogTime(msOfDay: number) {
  const ms = Math.floor(msOfDay) % 86_400_000;
  const hours = Math.floor(ms / 3_600_000);
  const pad = (n: number, width = 2) => String(n).padStart(width, "0");
  return `${hours % 12 || 12}:${pad(Math.floor(ms / 60_000) % 60)}:${pad(
    Math.floor(ms / 1000) % 60
  )}.${pad(ms % 1000, 3)} ${hours < 12 ? "AM" : "PM"}`;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/** setTimeout calls that are cleared together, and on unmount. */
function useTimeouts() {
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

function MacButton({
  children,
  onClick,
  variant = "plain",
  size = "regular",
  disabled = false,
  ariaLabel,
  title,
}: {
  children: ReactNode;
  onClick?: () => void;
  variant?: "plain" | "prominent" | "destructive";
  size?: "regular" | "small";
  disabled?: boolean;
  ariaLabel?: string;
  title?: string;
}) {
  const look =
    variant === "prominent"
      ? "border-transparent bg-[#007aff] text-white"
      : variant === "destructive"
        ? "border-black/10 bg-white text-[#ff3b30]"
        : "border-black/10 bg-white text-black/85";
  const dims =
    size === "small" ? "px-2 py-px text-[11px]" : "px-2.5 py-[3px] text-[13px]";
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-label={ariaLabel}
      title={title}
      className={`inline-flex cursor-pointer items-center justify-center rounded-[5px] border shadow-[0_0.5px_1px_rgba(0,0,0,0.15)] disabled:cursor-default disabled:opacity-45 ${look} ${dims}`}
    >
      {children}
    </button>
  );
}

/** A grouped-Form section: optional header above a rounded group of rows. */
function FormSection({ header, children }: { header?: string; children: ReactNode }) {
  return (
    <section>
      {header && (
        <h3 className="mb-1.5 px-1 text-[13px] font-semibold text-black/85">{header}</h3>
      )}
      <div className="divide-y divide-black/[0.07] rounded-[10px] border border-black/[0.06] bg-white px-3 text-[13px]">
        {children}
      </div>
    </section>
  );
}

function FormRow({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex min-h-[38px] items-center justify-between gap-3 py-1.5">
      <span>{label}</span>
      {children}
    </div>
  );
}

function Toggle({
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
      className={`relative h-[22px] w-[38px] shrink-0 cursor-pointer rounded-full transition-colors duration-200 ${
        on ? "bg-[#007aff]" : "bg-black/[0.12]"
      }`}
    >
      <span
        className={`absolute top-[2px] h-[18px] w-[18px] rounded-full bg-white shadow transition-[left] duration-200 ${
          on ? "left-[18px]" : "left-[2px]"
        }`}
      />
    </button>
  );
}

/** A grouped-Form menu picker: the selected value followed by up/down chevrons. */
function PopUp<T extends string>({
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
        className="cursor-pointer appearance-none bg-transparent py-0.5 pr-5 pl-1 text-right text-[13px] text-black/85 outline-offset-2"
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
      <svg
        aria-hidden
        viewBox="0 0 10 14"
        className="pointer-events-none absolute right-0.5 h-3 w-2.5 text-black/55"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <path d="M2 5.5 5 2.5l3 3M2 8.5l3 3 3-3" />
      </svg>
    </span>
  );
}

function StatusDot({ color }: { color: string }) {
  return (
    <span
      aria-hidden
      className="inline-block h-2 w-2 shrink-0 rounded-full"
      style={{ background: color }}
    />
  );
}

// SF Symbols used by StatusCard, drawn as simple SVGs.
function VideoFillIcon(props: SVGProps<SVGSVGElement>) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" {...props}>
      <rect x="2" y="6" width="14" height="12" rx="3" />
      <path d="M17.5 10.4 22 7.6v8.8l-4.5-2.8Z" />
    </svg>
  );
}

function MicFillIcon(props: SVGProps<SVGSVGElement>) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" {...props}>
      <rect x="8.5" y="2" width="7" height="12.5" rx="3.5" />
      <path
        d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
      />
    </svg>
  );
}

function PlusIcon(props: SVGProps<SVGSVGElement>) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      {...props}
    >
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

// ---------------------------------------------------------------------------
// Setup & Status
// ---------------------------------------------------------------------------

type CardState = "ready" | "working" | "inactive";
type MicStatus = "ready" | "working" | "notSetUp";

const STATE_TINT: Record<CardState, string> = {
  ready: GREEN_TEXT,
  working: "rgba(0,0,0,0.5)",
  inactive: "rgba(0,0,0,0.5)",
};

function StatusGlyph({ state }: { state: CardState }) {
  if (state === "ready") {
    return (
      <svg aria-hidden viewBox="0 0 16 16" className="h-3.5 w-3.5">
        <circle cx="8" cy="8" r="7.5" fill={GREEN} />
        <path
          d="m4.8 8.2 2.2 2.2 4.2-4.6"
          fill="none"
          stroke="#fff"
          strokeWidth="1.7"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    );
  }
  if (state === "inactive") {
    return (
      <svg aria-hidden viewBox="0 0 16 16" className="h-3.5 w-3.5">
        <circle cx="8" cy="8" r="6.8" fill="none" stroke="currentColor" strokeWidth="1.3" />
      </svg>
    );
  }
  // ProgressView().controlSize(.small)
  return (
    <svg aria-hidden viewBox="0 0 16 16" className="h-3.5 w-3.5 animate-spin">
      {Array.from({ length: 8 }, (_, i) => (
        <line
          key={i}
          x1="8"
          y1="1.8"
          x2="8"
          y2="4.6"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinecap="round"
          opacity={0.25 + (i / 8) * 0.75}
          transform={`rotate(${i * 45} 8 8)`}
        />
      ))}
    </svg>
  );
}

function StatusCard({
  icon,
  title,
  subtitle,
  state,
  statusText,
  action,
}: {
  icon: ReactNode;
  title: string;
  subtitle: string;
  state: CardState;
  statusText: string;
  action?: ReactNode;
}) {
  return (
    <div className="rounded-[16px] border border-black/[0.06] bg-white p-4">
      <div className="flex items-start gap-3.5">
        <span
          className="inline-flex h-[52px] w-[52px] shrink-0 items-center justify-center rounded-[13px] text-white shadow-[0_2px_6px_rgba(0,122,255,0.25)]"
          style={{ background: `linear-gradient(135deg, ${ACCENT}, rgba(0,122,255,0.65))` }}
        >
          {icon}
        </span>
        <div className="min-w-0 flex-1 space-y-1">
          <div className="flex items-baseline gap-2">
            <span className="text-[13px] font-bold">{title}</span>
            <span className="flex-1" />
            <span
              className="inline-flex items-center gap-[5px] self-center text-[11px] font-medium"
              style={{ color: STATE_TINT[state] }}
            >
              <StatusGlyph state={state} />
              {statusText}
            </span>
          </div>
          <p className="text-[12px] leading-snug text-black/50">{subtitle}</p>
        </div>
      </div>
      {action && (
        <>
          <div className="mt-3.5 border-t border-black/10" />
          <div className="mt-3 flex">{action}</div>
        </>
      )}
    </div>
  );
}

function RemoveMicDialog({
  onRemove,
  onCancel,
}: {
  onRemove: () => void;
  onCancel: () => void;
}) {
  const cancelRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    cancelRef.current?.focus();
  }, []);

  return (
    <div className="absolute inset-0 z-10 flex items-start justify-center bg-black/15 px-4 pt-10">
      <div
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="remove-mic-title"
        aria-describedby="remove-mic-message"
        onKeyDown={(e) => {
          if (e.key === "Escape") onCancel();
        }}
        className="w-[260px] rounded-[12px] border border-black/10 bg-[#f2f2f2] p-4 text-center shadow-[0_20px_50px_-12px_rgba(0,0,0,0.45)]"
      >
        <Image
          src="/icon.png"
          alt=""
          width={48}
          height={48}
          className="mx-auto rounded-[11px]"
        />
        <p id="remove-mic-title" className="mt-2.5 text-[13px] font-bold">
          Remove the LemurCam microphone?
        </p>
        <p id="remove-mic-message" className="mt-1.5 text-[11px] leading-snug text-black/70">
          This uninstalls the audio component and briefly restarts audio. You can
          re-enable it anytime without approving again.
        </p>
        <div className="mt-4 flex flex-col gap-2">
          <button
            type="button"
            onClick={onRemove}
            className="cursor-pointer rounded-[6px] border border-black/10 bg-white py-1 text-[13px] text-[#ff3b30] shadow-[0_0.5px_1px_rgba(0,0,0,0.15)]"
          >
            Remove Microphone
          </button>
          <button
            ref={cancelRef}
            type="button"
            onClick={onCancel}
            className="cursor-pointer rounded-[6px] border border-black/10 bg-white py-1 text-[13px] shadow-[0_0.5px_1px_rgba(0,0,0,0.15)]"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}

function StatusPane({
  micStatus,
  onRemoveMic,
  onEnableMic,
}: {
  micStatus: MicStatus;
  onRemoveMic: () => void;
  onEnableMic: () => void;
}) {
  const [confirming, setConfirming] = useState(false);

  const micCard: { state: CardState; text: string; action?: ReactNode } =
    micStatus === "ready"
      ? {
          state: "ready",
          text: "Running",
          action: (
            <MacButton variant="destructive" onClick={() => setConfirming(true)}>
              Remove Microphone…
            </MacButton>
          ),
        }
      : micStatus === "working"
        ? { state: "working", text: "Working…" }
        : {
            state: "inactive",
            text: "Not set up",
            action: (
              <MacButton variant="prominent" onClick={onEnableMic}>
                Enable Microphone
              </MacButton>
            ),
          };

  return (
    <div className="relative min-h-full">
      <div className="mx-auto flex max-w-[560px] flex-col gap-4 p-5">
        <StatusCard
          icon={<VideoFillIcon className="h-6 w-6" />}
          title="Virtual Camera"
          subtitle="LemurCam appears as a camera that apps like Zoom and FaceTime can select."
          state="ready"
          statusText="Running"
        />
        <StatusCard
          icon={<MicFillIcon className="h-6 w-6" />}
          title="Virtual Microphone"
          subtitle="Optional — exposes your camera’s audio as a “LemurCam Microphone”."
          state={micCard.state}
          statusText={micCard.text}
          action={micCard.action}
        />
        <div className="flex justify-between px-1">
          <MacButton>Open Guided Setup…</MacButton>
          <MacButton>Re-check Now</MacButton>
        </div>
      </div>
      {confirming && (
        <RemoveMicDialog
          onCancel={() => setConfirming(false)}
          onRemove={() => {
            setConfirming(false);
            onRemoveMic();
          }}
        />
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Cameras
// ---------------------------------------------------------------------------

function CamerasPane({
  activeId,
  statuses,
  onSelect,
}: {
  activeId: string | null;
  statuses: Record<string, ConnectionStatus>;
  onSelect: (id: string | null) => void;
}) {
  return (
    <div className="flex h-full min-h-[380px] flex-col sm:min-h-0">
      <div className="flex items-center gap-2 p-2 text-[13px]">
        <span>Active Camera</span>
        <span className="relative flex flex-1">
          <select
            aria-label="Active Camera"
            value={activeId ?? ""}
            onChange={(e) => onSelect(e.target.value || null)}
            className="w-full cursor-pointer appearance-none rounded-[5px] border border-black/10 bg-white py-[2px] pr-6 pl-2 text-[13px] shadow-[0_0.5px_1px_rgba(0,0,0,0.15)]"
          >
            <option value="">None</option>
            {SOURCES.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
          <svg
            aria-hidden
            viewBox="0 0 10 14"
            className="pointer-events-none absolute top-1/2 right-2 h-3 w-2.5 -translate-y-1/2 text-black/55"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.6"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <path d="M2 5.5 5 2.5l3 3M2 8.5l3 3 3-3" />
          </svg>
        </span>
      </div>
      <div className="border-t border-black/10" />

      <div className="flex-1 overflow-y-auto bg-white">
        <ul className="divide-y divide-black/[0.06] px-2">
          {SOURCES.map((source) => {
            const active = source.id === activeId;
            const status = statuses[source.id];
            return (
              <li key={source.id}>
                <button
                  type="button"
                  onClick={() => onSelect(source.id)}
                  aria-pressed={active}
                  className="flex w-full cursor-pointer items-center gap-2 px-1.5 py-[7px] text-left"
                >
                  <span className="min-w-0 flex-1">
                    <span className={`block text-[13px] ${active ? "font-semibold" : ""}`}>
                      {source.name}
                    </span>
                    <span className="mt-0.5 block truncate text-[10px] text-black/50">
                      {source.subtitle}
                    </span>
                  </span>
                  <span className="inline-flex shrink-0 items-center gap-1 text-[10px] text-black/50">
                    <StatusDot color={STATUS_COLOR[status]} />
                    {STATUS_LABEL[status]}
                  </span>
                  {active && (
                    <span className="shrink-0 rounded-full bg-[#007aff]/15 px-1.5 py-0.5 text-[10px] font-medium text-[#007aff]">
                      Active
                    </span>
                  )}
                </button>
              </li>
            );
          })}
        </ul>
      </div>

      <div className="border-t border-black/10" />
      <div className="flex gap-2 p-2">
        <MacButton ariaLabel="Discover Cameras" title="Discover Cameras">
          <BroadcastIcon className="h-4 w-4" />
        </MacButton>
        <MacButton ariaLabel="Add Camera">
          <PlusIcon className="h-4 w-4" />
        </MacButton>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

function Timecode({ fps }: { fps: number }) {
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
      setTc(
        `${pad(Math.floor(s / 3600))}:${pad(Math.floor((s / 60) % 60))}:${pad(s % 60)}:${pad(f)}`
      );
    }, 100);
    return () => clearInterval(id);
  }, [reducedMotion, fps]);

  return (
    <span className="rounded bg-black/60 px-1.5 py-0.5 font-mono text-[10px] tracking-wider text-white/90">
      {tc}
    </span>
  );
}

/** Stand-in for a decoded camera frame: a test card with a running timecode. */
function TestPattern({ fps }: { fps: number }) {
  return (
    <div className="relative aspect-video w-[min(100%,320px)] overflow-hidden">
      <div className="flex h-full">
        {BARS.map((c) => (
          <div key={c} className="flex-1" style={{ background: c }} />
        ))}
      </div>
      <div
        className="absolute inset-x-0 bottom-0 h-1/4"
        style={{
          background:
            "linear-gradient(90deg, #101010 0%, #3a3a3a 18%, #101010 36%, #8f7bff 52%, #d565c8 68%, #ff9e64 84%, #101010 100%)",
        }}
      />
      <div aria-hidden className="tp-scan absolute inset-x-0 h-12 bg-white/8" />
      <span className="absolute right-2 bottom-2">
        <Timecode fps={fps} />
      </span>
    </div>
  );
}

function PreviewPane({
  source,
  status,
  streaming,
}: {
  source: Source | null;
  status: ConnectionStatus | null;
  streaming: boolean;
}) {
  // PreviewStore is cleared on every (re)connect; stream details return once
  // the new stream is up.
  const live = streaming ? source : null;
  const rows: [string, string][] = [
    [
      "Status",
      source && status ? `${source.name} — ${STATUS_LABEL[status]}` : "No Camera Selected",
    ],
  ];
  if (live) {
    rows.push(
      ["Resolution", `${live.width} × ${live.height}`],
      ["Codec", CODEC_NAME[live.codec]],
      ["Frame Rate", `${live.fps} fps`]
    );
  }

  return (
    <div className="flex flex-col">
      <div className="flex flex-col items-center gap-1 p-4">
        <div className="flex h-[180px] w-full items-center justify-center overflow-hidden rounded-[6px] bg-black">
          {live ? (
            <TestPattern key={live.id} fps={live.fps} />
          ) : (
            // StreamPreview / PreviewSettingsView: .white.opacity(0.6) on black.
            <span className="text-[10px] text-white/60">No Preview</span>
          )}
        </div>
        {live && (
          <p className="text-[10px] text-black/50">
            {`${live.width}x${live.height} · ${CODEC_NAME[live.codec]} · ${live.fps} fps`}
          </p>
        )}
      </div>
      <div className="px-5 pb-5">
        <FormSection>
          {rows.map(([label, value]) => (
            <FormRow key={label} label={label}>
              <span className="text-right text-black/50">{value}</span>
            </FormRow>
          ))}
        </FormSection>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// General
// ---------------------------------------------------------------------------

type VideoFormat = { resolution: string; frameRate: number };

function GeneralPane({
  launchAtLogin,
  setLaunchAtLogin,
  format,
  setFormat,
  launchedFormat,
  onRestart,
}: {
  launchAtLogin: boolean;
  setLaunchAtLogin: (on: boolean) => void;
  format: VideoFormat;
  setFormat: (format: VideoFormat) => void;
  launchedFormat: VideoFormat;
  onRestart: () => void;
}) {
  // RuntimeFlags.needsRestart
  const needsRestart =
    format.resolution !== launchedFormat.resolution ||
    format.frameRate !== launchedFormat.frameRate;

  return (
    <div className="space-y-5 p-5">
      <FormSection header="About">
        <div className="flex items-center gap-3 py-2">
          <Image src="/icon.png" alt="" width={64} height={64} className="rounded-[14px]" />
          <div className="space-y-1">
            <p className="text-[17px] font-bold">LemurCam</p>
            <p className="flex items-center gap-1 text-[10px]">
              <span className="text-black/50">by</span>
              <a
                href="https://aneesiqbal.ai"
                target="_blank"
                rel="noreferrer"
                className="text-[#007aff]"
              >
                Anees Iqbal
              </a>
              <span className="text-black/50">·</span>
              <a href="https://lemur.cam" className="text-[#007aff]">
                lemur.cam
              </a>
            </p>
          </div>
        </div>
      </FormSection>

      <FormSection>
        <FormRow label="Launch at Login">
          <Toggle
            on={launchAtLogin}
            onChange={() => setLaunchAtLogin(!launchAtLogin)}
            label="Launch at Login"
          />
        </FormRow>
      </FormSection>

      <FormSection header="Virtual Camera">
        <FormRow label="Resolution">
          <PopUp
            label="Resolution"
            value={format.resolution}
            options={RESOLUTIONS.map((r) => ({ value: r, label: r }))}
            onChange={(resolution) => setFormat({ ...format, resolution })}
          />
        </FormRow>
        <FormRow label="Frame Rate">
          <PopUp
            label="Frame Rate"
            value={String(format.frameRate)}
            options={FRAME_RATES.map((f) => ({ value: String(f), label: `${f} fps` }))}
            onChange={(rate) => setFormat({ ...format, frameRate: Number(rate) })}
          />
        </FormRow>
        {needsRestart && (
          <div className="flex min-h-[38px] items-center gap-3 py-1.5">
            <span className="flex-1 text-[10px] text-black/50">
              Restart LemurCam to apply changes.
            </span>
            <MacButton size="small" onClick={onRestart}>
              Restart Now
            </MacButton>
          </div>
        )}
      </FormSection>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Logs
// ---------------------------------------------------------------------------

function LogsPane({ entries, onClear }: { entries: LogEntry[]; onClear: () => void }) {
  const scroller = useRef<HTMLDivElement>(null);

  // LogsSettingsView scrolls to the newest entry whenever the count changes.
  useEffect(() => {
    const node = scroller.current;
    if (node) node.scrollTop = node.scrollHeight;
  }, [entries.length]);

  const text = entries
    .map(
      (e) => `${e.time}  ${e.category.padEnd(5)}  ${e.level.padEnd(5)}  ${e.message}`
    )
    .join("\n");

  const copyAll = () => {
    const formatted = entries
      .map((e) => `[${e.category}] ${e.level}: ${e.time} ${e.message}`)
      .join("\n");
    navigator.clipboard?.writeText(formatted).catch(() => {});
  };

  return (
    <div className="flex h-full min-h-[380px] flex-col sm:min-h-0">
      <div ref={scroller} className="min-h-0 flex-1 overflow-y-auto">
        <pre className="p-2 text-[10px] leading-[1.5] break-words whitespace-pre-wrap text-black/85 [font-family:ui-monospace,SFMono-Regular,Menlo,monospace]">
          {text}
        </pre>
      </div>
      <div className="border-t border-black/10" />
      <div className="flex items-center gap-2 p-2">
        <span className="flex-1 text-[10px] text-black/50">{entries.length} entries</span>
        <MacButton onClick={copyAll} disabled={entries.length === 0}>
          Copy All
        </MacButton>
        <MacButton onClick={onClear}>Clear</MacButton>
      </div>
      <p className="px-2 pb-1 text-[10px] text-black/30">
        {'Extension logs are visible in Console.app (filter by "cam.lemur.app.extension").'}
      </p>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

export default function AppWindow() {
  const [tab, setTab] = useState<TabId>("preview");

  // Cameras, preview and logs share the source manager's state, as in the app.
  const [activeId, setActiveId] = useState<string | null>("backyard");
  const [statuses, setStatuses] = useState<Record<string, ConnectionStatus>>({
    backyard: "connected",
    front: "connected", // the boot sanity check found it reachable
  });
  const [streaming, setStreaming] = useState(true);
  const [logs, setLogs] = useState<LogEntry[]>(INITIAL_LOGS);
  const nextLogId = useRef(INITIAL_LOGS.length);
  const connectTimers = useTimeouts();

  const [micStatus, setMicStatus] = useState<MicStatus>("ready");
  const micTimers = useTimeouts();

  const [launchAtLogin, setLaunchAtLogin] = useState(false);
  const launched: VideoFormat = {
    resolution: DEFAULT_RESOLUTION,
    frameRate: DEFAULT_FRAME_RATE,
  };
  const [launchedFormat, setLaunchedFormat] = useState<VideoFormat>(launched);
  const [format, setFormat] = useState<VideoFormat>(launched);

  const log = (category: LogCategory, message: string) => {
    const entry: LogEntry = {
      id: nextLogId.current++,
      time: formatLogTime(LOG_CLOCK_START_MS + performance.now()),
      category,
      level: "INFO",
      message,
    };
    setLogs((prev) => [...prev, entry]);
  };

  // StreamCoordinator.syncToActiveSource → connectToSource → RTSPStreamPipeline.
  const selectSource = (id: string | null) => {
    if (id === activeId) return;
    connectTimers.cancelAll();
    // A connection abandoned mid-way goes back to its earlier reachable status.
    setStatuses((prev) =>
      Object.fromEntries(Object.keys(prev).map((key) => [key, "connected" as const]))
    );
    setActiveId(id);
    setStreaming(false);

    const source = SOURCES.find((s) => s.id === id);
    if (!source) {
      log("rtsp", "No active source, starting fallback generator");
      return;
    }

    setStatuses((prev) => ({ ...prev, [source.id]: "connecting" }));
    let delay = 0;
    if (source.kind === "onvif") {
      log("rtsp", `Re-discovering ONVIF stream URI for '${source.name}'`);
      delay = 500;
      connectTimers.after(delay, () => log("rtsp", "Connecting with resolved URI"));
    } else {
      log("rtsp", `Connecting to source '${source.name}'`);
    }
    connectTimers.after(delay + 700, () => {
      log("rtsp", `Format description created: ${source.width}x${source.height}`);
      log("rtsp", `Audio stream: ${source.audio}`);
      log("rtsp", `Stream connected: ${source.codec}`);
      setStatuses((prev) => ({ ...prev, [source.id]: "connected" }));
      setStreaming(true);
    });
    connectTimers.after(delay + 900, () => {
      log("rtsp", "Received keyframe");
      log("rtsp", "Created decompression session");
    });
  };

  const changeMic = (to: MicStatus) => {
    micTimers.cancelAll();
    setMicStatus("working");
    micTimers.after(1200, () => setMicStatus(to));
  };

  const activeSource = SOURCES.find((s) => s.id === activeId) ?? null;

  return (
    <div className="mx-auto w-full max-w-4xl overflow-hidden rounded-[14px] bg-[#f4f3f7] text-[#1d1c22] shadow-[0_48px_100px_-24px_rgba(0,0,0,0.65)] ring-1 ring-white/10 [font-family:system-ui,-apple-system,sans-serif]">
      {/* Title bar */}
      <div className="relative flex h-11 items-center border-b border-black/8 px-4">
        <span className="flex gap-2">
          <span className="h-3 w-3 rounded-full bg-[#ff5f57]" />
          <span className="h-3 w-3 rounded-full bg-[#febc2e]" />
          <span className="h-3 w-3 rounded-full bg-[#28c840]" />
        </span>
        <span className="absolute inset-x-0 text-center text-[13px] font-semibold">
          Settings
        </span>
      </div>

      <div className="flex flex-col sm:h-[480px] sm:flex-row">
        {/* Sidebar */}
        <nav className="flex shrink-0 gap-1 overflow-x-auto border-b border-black/8 bg-[#ecebf1] p-2 sm:w-[200px] sm:flex-col sm:border-b-0 sm:border-r sm:p-2.5">
          {TABS.map((t) => {
            const Icon = t.icon;
            const selected = tab === t.id;
            return (
              <button
                key={t.id}
                type="button"
                onClick={() => setTab(t.id)}
                aria-pressed={selected}
                className={`flex shrink-0 cursor-pointer items-center gap-2 rounded-md px-2.5 py-1.5 text-[13px] transition-colors ${
                  selected ? "bg-[#007aff] font-medium text-white" : "text-black/70 hover:bg-black/5"
                }`}
              >
                <Icon className="h-4 w-4 shrink-0" />
                <span className="whitespace-nowrap">{t.label}</span>
              </button>
            );
          })}
        </nav>

        {/* Content */}
        <div className="min-h-[380px] flex-1 overflow-y-auto bg-[#fbfafc] sm:min-h-0">
          {tab === "status" && (
            <StatusPane
              micStatus={micStatus}
              onRemoveMic={() => changeMic("notSetUp")}
              onEnableMic={() => changeMic("ready")}
            />
          )}
          {tab === "cameras" && (
            <CamerasPane activeId={activeId} statuses={statuses} onSelect={selectSource} />
          )}
          {tab === "preview" && (
            <PreviewPane
              source={activeSource}
              status={activeSource ? statuses[activeSource.id] : null}
              streaming={streaming}
            />
          )}
          {tab === "general" && (
            <GeneralPane
              launchAtLogin={launchAtLogin}
              setLaunchAtLogin={setLaunchAtLogin}
              format={format}
              setFormat={setFormat}
              launchedFormat={launchedFormat}
              onRestart={() => setLaunchedFormat(format)}
            />
          )}
          {tab === "logs" && <LogsPane entries={logs} onClear={() => setLogs([])} />}
        </div>
      </div>
    </div>
  );
}
