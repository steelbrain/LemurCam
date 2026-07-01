"use client";

import { useEffect, useRef, useState } from "react";
import {
  CameraIcon,
  DocIcon,
  EyeIcon,
  GearIcon,
  ListIcon,
  MicIcon,
} from "./icons";

/* A faithful-but-alive HTML/CSS recreation of the LemurCam Settings window.
   Everything is clickable: sidebar tabs switch panes, cameras can be made
   active, toggles toggle, the preview runs a test pattern with live timecode,
   and the log view keeps writing. */

const BARS = [
  "#c8c8c8",
  "#f0e02e",
  "#2ec8c8",
  "#2ebe4e",
  "#e04ee0",
  "#e04040",
  "#3050e0",
];

const LOG_LINES = [
  "RTSP session established (tcp)",
  "Jitter buffer primed · 6 frames",
  "H.264 keyframe received",
  "Sink stream connected · 30 fps",
  "ONVIF probe answered · 1 device",
  "Audio converter ready · 48 kHz",
  "Preview demand added",
  "Frame format 1280×720 (native)",
];

const TABS = [
  { id: "status", label: "Setup & Status", icon: ListIcon },
  { id: "cameras", label: "Cameras", icon: CameraIcon },
  { id: "preview", label: "Preview", icon: EyeIcon },
  { id: "general", label: "General", icon: GearIcon },
  { id: "logs", label: "Logs", icon: DocIcon },
] as const;

type TabId = (typeof TABS)[number]["id"];

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
      className={`relative h-[22px] w-9 shrink-0 cursor-pointer rounded-full transition-colors duration-200 ${
        on ? "bg-[#34c759]" : "bg-black/15"
      }`}
    >
      <span
        className={`absolute top-[2px] h-[18px] w-[18px] rounded-full bg-white shadow transition-[left] duration-200 ${
          on ? "left-[16px]" : "left-[2px]"
        }`}
      />
    </button>
  );
}

function StatusPill({ on, onLabel = "Running" }: { on: boolean; onLabel?: string }) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-[11px] font-medium ${
        on ? "bg-[#34c759]/15 text-[#1d9d43]" : "bg-black/8 text-black/45"
      }`}
    >
      <span
        className={`h-1.5 w-1.5 rounded-full ${
          on ? "pulse-dot bg-[#34c759]" : "bg-black/30"
        }`}
      />
      {on ? onLabel : "Off"}
    </span>
  );
}

function Timecode() {
  const [tc, setTc] = useState("00:00:00:00");
  const start = useRef(0);

  useEffect(() => {
    start.current = performance.now();
    const id = setInterval(() => {
      const ms = performance.now() - start.current;
      const f = Math.floor((ms / (1000 / 30)) % 30);
      const s = Math.floor(ms / 1000);
      const pad = (n: number) => String(n).padStart(2, "0");
      setTc(
        `${pad(Math.floor(s / 3600))}:${pad(Math.floor((s / 60) % 60))}:${pad(
          s % 60
        )}:${pad(f)}`
      );
    }, 100);
    return () => clearInterval(id);
  }, []);

  return (
    <span className="rounded bg-black/60 px-1.5 py-0.5 font-mono text-[10px] tracking-wider text-white/90">
      {tc}
    </span>
  );
}

function PreviewPane() {
  return (
    <div className="flex h-full flex-col gap-4 p-4 sm:p-5">
      <div className="mx-auto w-full max-w-[440px]">
        <div className="relative overflow-hidden rounded-lg bg-black">
          <div className="flex aspect-video">
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
          <span className="absolute right-2 top-2 inline-flex items-center gap-1.5 rounded-full bg-black/60 px-2 py-1 font-mono text-[10px] font-medium uppercase tracking-[0.14em] text-white/90">
            <span className="pulse-dot h-1.5 w-1.5 rounded-full bg-[#34c759]" />
            Live
          </span>
          <span className="absolute bottom-2 right-2">
            <Timecode />
          </span>
        </div>
        <p className="mt-2 text-center text-[11px] text-black/45">
          1280×720 · H.264 · 30 fps
        </p>
      </div>
      <div className="divide-y divide-black/6 rounded-lg bg-black/[0.035] px-4 text-[13px]">
        {[
          [
            "Status",
            <span key="s" className="inline-flex items-center gap-1.5">
              <span className="pulse-dot h-1.5 w-1.5 rounded-full bg-[#34c759]" />
              Camera — Connected
            </span>,
          ],
          ["Resolution", "1280 × 720"],
          ["Codec", "H.264"],
          ["Frame Rate", "30 fps"],
        ].map(([k, v], i) => (
          <div key={i} className="flex items-center justify-between py-2.5">
            <span className="font-medium">{k}</span>
            <span className="text-black/55">{v}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function CamerasPane() {
  const [active, setActive] = useState(0);
  const cams = [
    { name: "Backyard Cam", url: "rtsp://192.168.1.115:554/stream1" },
    { name: "Front Door", url: "onvif://192.168.1.82 · discovered" },
  ];
  return (
    <div className="flex h-full flex-col p-4 sm:p-5">
      <p className="mb-3 text-[11px] font-medium uppercase tracking-wide text-black/40">
        Your cameras — click one to make it active
      </p>
      <div className="space-y-2">
        {cams.map((cam, i) => (
          <button
            key={cam.name}
            type="button"
            onClick={() => setActive(i)}
            className={`flex w-full cursor-pointer items-center gap-3 rounded-lg border px-3.5 py-3 text-left transition-colors ${
              active === i
                ? "border-[#0a68ff]/40 bg-[#0a68ff]/6"
                : "border-black/8 bg-white hover:bg-black/[0.03]"
            }`}
          >
            <CameraIcon className="h-5 w-5 shrink-0 text-black/50" />
            <span className="min-w-0 flex-1">
              <span className="block text-[13px] font-medium">{cam.name}</span>
              <span className="block truncate font-mono text-[11px] text-black/40">
                {cam.url}
              </span>
            </span>
            <span className="inline-flex items-center gap-1.5 text-[11px] text-[#1d9d43]">
              <span className="pulse-dot h-1.5 w-1.5 rounded-full bg-[#34c759]" />
              Connected
            </span>
            {active === i && (
              <span className="rounded-full bg-[#0a68ff] px-2 py-0.5 text-[10px] font-semibold text-white">
                Active
              </span>
            )}
          </button>
        ))}
      </div>
      <div className="mt-auto flex justify-end pt-4">
        <span className="rounded-md border border-black/10 bg-white px-2.5 py-1 text-[12px] text-black/50 shadow-sm">
          + Add Camera…
        </span>
      </div>
    </div>
  );
}

function StatusPane({
  micOn,
  setMicOn,
}: {
  micOn: boolean;
  setMicOn: (v: boolean) => void;
}) {
  return (
    <div className="flex h-full flex-col gap-3 p-4 sm:p-5">
      <div className="flex items-start gap-3 rounded-lg border border-black/8 bg-white p-3.5">
        <span className="mt-0.5 inline-flex h-8 w-8 items-center justify-center rounded-lg bg-[#0a68ff] text-white">
          <CameraIcon className="h-4.5 w-4.5" />
        </span>
        <div className="flex-1">
          <div className="flex items-center justify-between">
            <span className="text-[13px] font-semibold">Virtual Camera</span>
            <StatusPill on />
          </div>
          <p className="mt-1 text-[12px] leading-relaxed text-black/50">
            LemurCam appears as a camera that apps like Zoom and FaceTime can
            select.
          </p>
        </div>
      </div>

      <div className="flex items-start gap-3 rounded-lg border border-black/8 bg-white p-3.5">
        <span className="mt-0.5 inline-flex h-8 w-8 items-center justify-center rounded-lg bg-[#8f7bff] text-white">
          <MicIcon className="h-4.5 w-4.5" />
        </span>
        <div className="flex-1">
          <div className="flex items-center justify-between gap-3">
            <span className="text-[13px] font-semibold">Virtual Microphone</span>
            <span className="flex items-center gap-2.5">
              <StatusPill on={micOn} />
              <Toggle
                on={micOn}
                onChange={() => setMicOn(!micOn)}
                label="Toggle virtual microphone"
              />
            </span>
          </div>
          <p className="mt-1 text-[12px] leading-relaxed text-black/50">
            Optional — routes your camera&apos;s audio into calls as
            &ldquo;LemurCam Microphone&rdquo;.
          </p>
          {micOn && (
            <div className="mt-2.5 flex h-4 items-end gap-[3px]">
              {[0.5, 0.8, 0.35, 0.95, 0.6, 0.85, 0.4, 0.7, 0.5, 0.9, 0.45, 0.75].map(
                (s, j) => (
                  <span
                    key={j}
                    className="eq-bar w-[3px] rounded-full bg-[#8f7bff]"
                    style={{ height: `${s * 100}%`, animationDelay: `${j * 0.12}s` }}
                  />
                )
              )}
            </div>
          )}
        </div>
      </div>

      <div className="mt-auto flex justify-between pt-2">
        <span className="rounded-md border border-black/10 bg-white px-2.5 py-1 text-[12px] text-black/50 shadow-sm">
          Open Guided Setup…
        </span>
        <span className="rounded-md border border-black/10 bg-white px-2.5 py-1 text-[12px] text-black/50 shadow-sm">
          Re-check Now
        </span>
      </div>
    </div>
  );
}

function GeneralPane() {
  const [login, setLogin] = useState(true);
  const [res, setRes] = useState("1080p");
  const [fps, setFps] = useState("30 fps");
  return (
    <div className="flex h-full flex-col p-4 sm:p-5">
      <div className="divide-y divide-black/6 rounded-lg border border-black/8 bg-white px-4 text-[13px]">
        <div className="flex items-center justify-between py-3">
          <span className="font-medium">Launch at Login</span>
          <Toggle on={login} onChange={() => setLogin(!login)} label="Launch at login" />
        </div>
        <div className="flex items-center justify-between py-3">
          <span className="font-medium">Resolution</span>
          <span className="flex gap-1">
            {["720p", "1080p"].map((r) => (
              <button
                key={r}
                type="button"
                onClick={() => setRes(r)}
                className={`cursor-pointer rounded-md px-2.5 py-1 text-[12px] transition-colors ${
                  res === r
                    ? "bg-[#0a68ff] font-medium text-white"
                    : "bg-black/5 text-black/55 hover:bg-black/10"
                }`}
              >
                {r}
              </button>
            ))}
          </span>
        </div>
        <div className="flex items-center justify-between py-3">
          <span className="font-medium">Frame Rate</span>
          <span className="flex gap-1">
            {["30 fps", "60 fps"].map((f) => (
              <button
                key={f}
                type="button"
                onClick={() => setFps(f)}
                className={`cursor-pointer rounded-md px-2.5 py-1 text-[12px] transition-colors ${
                  fps === f
                    ? "bg-[#0a68ff] font-medium text-white"
                    : "bg-black/5 text-black/55 hover:bg-black/10"
                }`}
              >
                {f}
              </button>
            ))}
          </span>
        </div>
      </div>
      <p className="mt-3 text-center text-[11px] text-black/35">
        Applies after restart — LemurCam 1.4
      </p>
    </div>
  );
}

function LogsPane() {
  const [lines, setLines] = useState(() => LOG_LINES.slice(0, 4));
  const next = useRef(4);
  useEffect(() => {
    const id = setInterval(() => {
      setLines((prev) => {
        const line = LOG_LINES[next.current % LOG_LINES.length];
        next.current += 1;
        return [...prev.slice(-7), line];
      });
    }, 1600);
    return () => clearInterval(id);
  }, []);
  return (
    <div className="h-full p-4 sm:p-5">
      <div className="flex h-full flex-col justify-end overflow-hidden rounded-lg bg-[#131118] p-3.5 font-mono text-[11px] leading-6">
        {lines.map((l, i) => (
          <p key={`${l}-${i}`} className="truncate">
            <span className="text-[#8f7bff]">info</span>{" "}
            <span className="text-white/75">{l}</span>
          </p>
        ))}
        <p className="text-white/40">
          <span className="inline-block h-3 w-1.5 translate-y-0.5 animate-pulse bg-white/60" />
        </p>
      </div>
    </div>
  );
}

export default function AppWindow() {
  const [tab, setTab] = useState<TabId>("preview");
  const [micOn, setMicOn] = useState(true);

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
        <nav className="flex shrink-0 gap-1 overflow-x-auto border-b border-black/8 bg-[#ecebf1] p-2 sm:w-44 sm:flex-col sm:border-b-0 sm:border-r sm:p-2.5">
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
                  selected
                    ? "bg-[#0a68ff] font-medium text-white"
                    : "text-black/70 hover:bg-black/5"
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
          {tab === "preview" && <PreviewPane />}
          {tab === "cameras" && <CamerasPane />}
          {tab === "status" && <StatusPane micOn={micOn} setMicOn={setMicOn} />}
          {tab === "general" && <GeneralPane />}
          {tab === "logs" && <LogsPane />}
        </div>
      </div>
    </div>
  );
}
