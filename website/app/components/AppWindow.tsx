"use client";

import Image from "next/image";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { useBridge, useWindowHandler, type SettingsPane } from "./Bridge";
import {
  Antenna,
  Checklist,
  CircleFill,
  DocText,
  Eye,
  FormPopUp,
  FormRow,
  FormSection,
  Gear,
  MacButton,
  MicFill,
  Plus,
  PopUpButton,
  SidebarLeft,
  Spinner,
  TestPattern,
  Toggle,
  TrafficLights,
  VideoFill,
  WebCamera,
  useTimeouts,
} from "./mac";
import {
  CODEC_NAME,
  SOURCES,
  STATUS_COLOR,
  STATUS_LABEL,
  connectDelay,
  type ConnectionStatus,
  type Source,
} from "./samples";

/* An interactive recreation of the LemurCam Settings window (720 x 480 points,
   Tuning.settingsWindowWidth/Height). Labels, options, defaults and state
   changes mirror the SwiftUI views in App/Settings (SettingsView,
   StatusSettingsView, StatusCard, PreviewSettingsView, GeneralSettingsView,
   LogsSettingsView) and App/Sources/SourceListView. The chrome follows the
   macOS 26 look of the app's own screenshots: a floating sidebar, the title
   beside the window buttons, and a sidebar toggle.

   Deliberate liberties:
   - The two cameras and their stream details are samples. Log messages are the
     app's real Log calls, filled in with those samples; timestamps use the
     en-US format the app shows on an English (US) Mac.
   - No other app is using the virtual camera or microphone, and this recreation
     runs apart from the popover above it, so only the Preview pane keeps the
     stream connected.
   - The preview shows a test pattern in place of camera video.
   - Connecting a camera and removing or enabling the microphone run on short
     timers instead of real network and install work.
   - Open Guided Setup… scrolls to the setup window's recreation. Buttons that
     open sheets (add or discover a camera) and Re-check Now do nothing here.
   - Resolution and Frame Rate only change the menus here; when and how the app
     applies them is not shown.
   - The About section leaves out the "Version …" line so the site never shows
     a stale version.
   - On narrow screens the sidebar is drawn as a row above the pane. */

const TABS: { id: SettingsPane; label: string; icon: (p: { className?: string }) => ReactNode }[] = [
  { id: "status", label: "Setup & Status", icon: Checklist },
  { id: "cameras", label: "Cameras", icon: WebCamera },
  { id: "preview", label: "Preview", icon: Eye },
  { id: "general", label: "General", icon: Gear },
  { id: "logs", label: "Logs", icon: DocText },
];

// LemurCamConfig.Resolution / FrameRate, with their defaults.
const RESOLUTIONS = ["720p", "1080p", "1440p", "4K"] as const;
const FRAME_RATES = [30, 60] as const;

type LogCategory = "app" | "ipc" | "rtsp";
type LogEntry = {
  id: number;
  time: string;
  category: LogCategory;
  level: "INFO";
  message: string;
};

// What a launch looks like up to the stream feeding the preview: sources load,
// the coordinator starts with no demand, opening the Preview pane adds preview
// demand, and the active camera connects.
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

function StatusDot({ status, size = 8 }: { status: ConnectionStatus; size?: number }) {
  return (
    <span
      aria-hidden
      className="inline-block shrink-0 rounded-full"
      style={{ background: STATUS_COLOR[status], width: size, height: size }}
    />
  );
}

// ---------------------------------------------------------------------------
// Setup & Status
// ---------------------------------------------------------------------------

type CardState = "ready" | "working" | "inactive";
type MicStatus = "ready" | "working" | "notSetUp";

function StatusBadge({ state, text }: { state: CardState; text: string }) {
  // SetupStepState.statusTint: green when ready, secondary otherwise.
  return (
    <span
      className={`inline-flex items-center gap-[5px] text-[11px] font-medium ${
        state === "ready" ? "text-mac-green-text" : "text-mac-secondary"
      }`}
    >
      {state === "ready" && <CircleFill kind="check" className="h-[13px] w-[13px]" />}
      {state === "working" && <Spinner className="h-[13px] w-[13px]" />}
      {state === "inactive" && (
        <svg aria-hidden viewBox="0 0 16 16" className="h-[13px] w-[13px]">
          <circle cx="8" cy="8" r="6.8" fill="none" stroke="currentColor" strokeWidth="1.3" />
        </svg>
      )}
      {text}
    </span>
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
    <div className="rounded-[16px] border border-mac-card-line bg-mac-card p-4">
      <div className="flex items-start gap-3.5">
        <span
          className="inline-flex h-[52px] w-[52px] shrink-0 items-center justify-center rounded-[13px] text-white shadow-[0_2px_6px_color-mix(in_srgb,var(--mac-accent)_25%,transparent)]"
          style={{
            background:
              "linear-gradient(135deg, var(--mac-accent), color-mix(in srgb, var(--mac-accent) 65%, transparent))",
          }}
        >
          {icon}
        </span>
        <div className="min-w-0 flex-1 space-y-1">
          <div className="flex flex-wrap items-baseline justify-between gap-x-2">
            <span className="text-[13px] font-bold">{title}</span>
            <StatusBadge state={state} text={statusText} />
          </div>
          <p className="text-[12px] leading-snug text-mac-secondary">{subtitle}</p>
        </div>
      </div>
      {action && (
        <>
          <div className="mt-3.5 border-t border-mac-sep" />
          <div className="mt-3 flex">{action}</div>
        </>
      )}
    </div>
  );
}

/** confirmationDialog("Remove the LemurCam microphone?") as macOS draws it: an alert. */
function RemoveMicDialog({ onRemove, onCancel }: { onRemove: () => void; onCancel: () => void }) {
  const cancelRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    cancelRef.current?.focus();
  }, []);

  return (
    <div className="absolute inset-0 z-10 flex items-start justify-center bg-black/20 px-4 pt-10">
      <div
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="remove-mic-title"
        aria-describedby="remove-mic-message"
        onKeyDown={(e) => {
          if (e.key === "Escape") onCancel();
        }}
        className="w-[260px] rounded-[16px] bg-mac-popover p-4 text-center mac-shadow"
      >
        <Image src="/icon.png" alt="" width={48} height={48} className="mx-auto" />
        <p id="remove-mic-title" className="mt-2.5 text-[13px] font-bold">
          Remove the LemurCam microphone?
        </p>
        <p id="remove-mic-message" className="mt-1.5 text-[11px] leading-snug">
          This uninstalls the audio component and briefly restarts audio. You can re-enable it
          anytime without approving again.
        </p>
        <div className="mt-4 flex flex-col gap-2">
          <MacButton variant="destructive" onClick={onRemove} className="w-full">
            Remove Microphone
          </MacButton>
          <button
            ref={cancelRef}
            type="button"
            onClick={onCancel}
            className="inline-flex h-[24px] w-full cursor-pointer items-center justify-center rounded-[6px] bg-mac-control text-[13px] hover:bg-mac-control-hover"
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
  onOpenSetup,
}: {
  micStatus: MicStatus;
  onRemoveMic: () => void;
  onEnableMic: () => void;
  onOpenSetup: () => void;
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
          icon={<VideoFill className="h-8 w-8" />}
          title="Virtual Camera"
          subtitle="LemurCam appears as a camera that apps like Zoom and FaceTime can select."
          state="ready"
          statusText="Running"
        />
        <StatusCard
          icon={<MicFill className="h-8 w-8" />}
          title="Virtual Microphone"
          subtitle="Optional — exposes your camera’s audio as a “LemurCam Microphone”."
          state={micCard.state}
          statusText={micCard.text}
          action={micCard.action}
        />
        <div className="flex justify-between gap-2 px-1">
          <MacButton onClick={onOpenSetup}>Open Guided Setup…</MacButton>
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
      <div className="flex items-center justify-center gap-2 p-2 text-[13px]">
        <span>Active Camera</span>
        <PopUpButton
          label="Active Camera"
          value={activeId ?? ""}
          options={[{ value: "", label: "None" }, ...SOURCES.map((s) => ({ value: s.id, label: s.name }))]}
          onChange={(v) => onSelect(v || null)}
        />
      </div>
      <div className="border-t border-mac-sep" />

      <ul className="min-h-0 flex-1 overflow-y-auto px-3 py-1.5">
        {SOURCES.map((source) => {
          const active = source.id === activeId;
          const status = statuses[source.id];
          return (
            <li key={source.id}>
              <button
                type="button"
                onClick={() => onSelect(source.id)}
                aria-pressed={active}
                className="flex w-full cursor-pointer items-center gap-2.5 rounded-[6px] px-2 py-[7px] text-left"
              >
                <span className="min-w-0 flex-1">
                  <span className={`block text-[13px] ${active ? "font-semibold" : ""}`}>{source.name}</span>
                  <span className="mt-0.5 block truncate text-[10px] text-mac-secondary">{source.subtitle}</span>
                </span>
                <span className="inline-flex shrink-0 items-center gap-1 text-[10px] text-mac-secondary">
                  <StatusDot status={status} />
                  {STATUS_LABEL[status]}
                </span>
                {active && (
                  <span className="shrink-0 rounded-full bg-mac-accent/15 px-1.5 py-0.5 text-[10px] font-medium text-mac-accent">
                    Active
                  </span>
                )}
              </button>
            </li>
          );
        })}
      </ul>

      <div className="border-t border-mac-sep" />
      <div className="flex gap-2 p-2">
        <MacButton ariaLabel="Discover Cameras" title="Discover Cameras" className="w-[34px] px-0">
          <Antenna className="h-5 w-5" />
        </MacButton>
        <MacButton ariaLabel="Add Camera" className="w-[34px] px-0">
          <Plus className="h-5 w-5" />
        </MacButton>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

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
    ["Status", source && status ? `${source.name} — ${STATUS_LABEL[status]}` : "No Camera Selected"],
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
            <span className="text-[10px] text-white/60">No Preview</span>
          )}
        </div>
        {live && (
          <p className="text-[10px] text-mac-secondary">
            {`${live.width}x${live.height} · ${CODEC_NAME[live.codec]} · ${live.fps} fps`}
          </p>
        )}
      </div>
      <div className="px-5 pt-3 pb-5">
        <FormSection>
          {rows.map(([label, value]) => (
            <FormRow key={label} label={label}>
              <span className="text-right text-mac-secondary">{value}</span>
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

type GeneralSettings = { launchAtLogin: boolean; resolution: string; frameRate: string };

function GeneralPane({
  settings,
  onChange,
}: {
  settings: GeneralSettings;
  onChange: (settings: GeneralSettings) => void;
}) {
  const { launchAtLogin, resolution, frameRate } = settings;

  return (
    <div className="space-y-5 p-5">
      <FormSection header="About">
        <div className="flex items-center gap-3 py-2">
          <Image src="/icon.png" alt="" width={64} height={64} />
          <div className="space-y-1">
            <p className="text-[17px] font-bold">LemurCam</p>
            <p className="flex items-center gap-1 text-[10px]">
              <span className="text-mac-secondary">by</span>
              <a href="https://aneesiqbal.ai" target="_blank" rel="noreferrer" className="text-mac-accent">
                Anees Iqbal
              </a>
              <span className="text-mac-secondary">·</span>
              <a href="https://lemur.cam" className="text-mac-accent">
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
            onChange={() => onChange({ ...settings, launchAtLogin: !launchAtLogin })}
            label="Launch at Login"
          />
        </FormRow>
      </FormSection>

      <FormSection header="Virtual Camera">
        <FormRow label="Resolution">
          <FormPopUp
            label="Resolution"
            value={resolution}
            options={RESOLUTIONS.map((r) => ({ value: r, label: r }))}
            onChange={(r) => onChange({ ...settings, resolution: r })}
          />
        </FormRow>
        <FormRow label="Frame Rate">
          <FormPopUp
            label="Frame Rate"
            value={frameRate}
            options={FRAME_RATES.map((f) => ({ value: String(f), label: `${f} fps` }))}
            onChange={(f) => onChange({ ...settings, frameRate: f })}
          />
        </FormRow>
      </FormSection>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Logs
// ---------------------------------------------------------------------------

function LogsPane({ entries, onClear }: { entries: LogEntry[]; onClear: () => void }) {
  const scroller = useRef<HTMLDivElement>(null);

  // LogsSettingsView scrolls to the newest entry whenever the last entry changes.
  useEffect(() => {
    const node = scroller.current;
    if (node) node.scrollTop = node.scrollHeight;
  }, [entries.length]);

  const text = entries
    .map((e) => `${e.time}  ${e.category.padEnd(5)}  ${e.level.padEnd(5)}  ${e.message}`)
    .join("\n");

  const copyAll = () => {
    const formatted = entries.map((e) => `[${e.category}] ${e.level}: ${e.time} ${e.message}`).join("\n");
    navigator.clipboard?.writeText(formatted).catch(() => {});
  };

  return (
    <div className="flex h-full min-h-[380px] flex-col sm:min-h-0">
      <div ref={scroller} className="min-h-0 flex-1 overflow-y-auto" tabIndex={0} aria-label="Log">
        <pre className="selectable p-2 font-mono text-[10px] leading-[1.5] break-words whitespace-pre-wrap">
          {text}
        </pre>
      </div>
      <div className="border-t border-mac-sep" />
      <div className="flex items-center gap-2 p-2">
        <span className="flex-1 text-[10px] text-mac-secondary">{entries.length} entries</span>
        <MacButton onClick={copyAll} disabled={entries.length === 0}>
          Copy All
        </MacButton>
        <MacButton onClick={onClear}>Clear</MacButton>
      </div>
      <p className="px-2 pb-1 text-[10px] text-mac-tertiary">
        {'Extension logs are visible in Console.app (filter by "cam.lemur.app.extension").'}
      </p>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

function Sidebar({ tab, onSelect }: { tab: SettingsPane; onSelect: (tab: SettingsPane) => void }) {
  return (
    <nav
      aria-label="Settings panes"
      className="flex shrink-0 gap-1 overflow-x-auto border-b border-mac-sep p-2 sm:m-2 sm:w-[200px] sm:flex-col sm:gap-0.5 sm:rounded-[18px] sm:border sm:border-mac-sidebar-line sm:bg-mac-sidebar sm:p-2.5 sm:shadow-[0_1px_4px_rgba(0,0,0,0.05)]"
    >
      {TABS.map((t) => {
        const Icon = t.icon;
        const selected = tab === t.id;
        return (
          <button
            key={t.id}
            type="button"
            onClick={() => onSelect(t.id)}
            aria-current={selected ? "page" : undefined}
            className={`flex h-[32px] shrink-0 cursor-pointer items-center gap-2.5 rounded-[8px] px-2.5 text-[13px] ${
              selected ? "bg-mac-selection text-white" : "hover:bg-mac-control"
            }`}
          >
            <Icon className="h-[17px] w-[17px] shrink-0" />
            <span className="whitespace-nowrap">{t.label}</span>
          </button>
        );
      })}
    </nav>
  );
}

export default function AppWindow() {
  const { openSetup } = useBridge();
  const [tab, setTab] = useState<SettingsPane>("preview");

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

  // LemurCamConfig defaults: 1080p at 60 fps. Launch at Login starts off.
  const [general, setGeneral] = useState<GeneralSettings>({
    launchAtLogin: false,
    resolution: "1080p",
    frameRate: "60",
  });

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

  // StreamCoordinator.syncToActiveSource with demand → connectToSource →
  // RTSPStreamPipeline.
  const connect = (id: string | null) => {
    connectTimers.cancelAll();
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
    connectTimers.after(connectDelay(source), () => {
      log("rtsp", `Format description created: ${source.width}x${source.height}`);
      log("rtsp", `Audio stream: ${source.audio}`);
      log("rtsp", `Stream connected: ${source.codec}`);
      setStatuses((prev) => ({ ...prev, [source.id]: "connected" }));
      setStreaming(true);
    });
    connectTimers.after(connectDelay(source) + 200, () => {
      log("rtsp", "Received keyframe");
      log("rtsp", "Created decompression session");
    });
  };

  // PreviewDemandDecision: of the Settings panes only Preview creates demand,
  // and StreamCoordinator.reconcileDemand acts on its edges.
  const selectTab = (to: SettingsPane) => {
    if (to === tab) return;
    setTab(to);
    if (to === "preview") {
      log("rtsp", "Demand detected — resuming RTSP pipeline");
      connect(activeId);
    } else if (tab === "preview") {
      log("rtsp", "No demand — pausing RTSP pipeline");
      connectTimers.cancelAll();
      setStreaming(false);
      // StreamCoordinator.reconcileDemand → showActiveSourceIdle: the paused camera
      // shows ConnectionStatus.disconnected, "Disconnected" in red
      // (ConnectionStatusHelpers.swift).
      if (activeId) setStatuses((prev) => ({ ...prev, [activeId]: "disconnected" }));
    }
  };

  // Another recreation opened Settings: AppDelegate.presentSettings keeps an
  // open window's pane unless a pane is asked for (Add Camera asks for Cameras).
  useWindowHandler("settings", (pane) => {
    if (pane) selectTab(pane);
  });

  // Cameras is not a demand pane, so SourceManager.setActiveSource →
  // syncToActiveSource only records the new source; it connects when the
  // Preview pane brings demand back.
  const selectSource = (id: string | null) => {
    if (id === activeId) return;
    setActiveId(id);
    log("rtsp", "No demand — skipping RTSP connection");
    // showActiveSourceIdle: the newly active camera shows as disconnected until
    // the Preview pane brings demand back.
    if (id) setStatuses((prev) => ({ ...prev, [id]: "disconnected" }));
  };

  const changeMic = (to: MicStatus) => {
    micTimers.cancelAll();
    setMicStatus("working");
    micTimers.after(1200, () => setMicStatus(to));
  };

  const activeSource = SOURCES.find((s) => s.id === activeId) ?? null;

  return (
    <div
      id="settings-window"
      tabIndex={-1}
      role="group"
      aria-label="Settings window recreation"
      className="mac mx-auto w-full max-w-[720px] overflow-hidden rounded-[22px] bg-mac-window mac-shadow outline-none"
    >
      {/* Title bar */}
      {/* Title bar, laid out as in the app's macOS 26 screenshots: window
          buttons, the title at 108 points, the sidebar toggle at 264. */}
      <div className="relative flex h-[52px] items-center gap-4 border-b border-mac-sep px-[19px] sm:gap-0">
        <TrafficLights />
        <span className="text-[15px] font-semibold text-mac-title sm:absolute sm:left-[108px]">Settings</span>
        <span
          aria-hidden
          className="absolute left-[264px] hidden h-[40px] w-[40px] items-center justify-center rounded-full text-mac-title shadow-[0_1px_8px_rgba(0,0,0,0.12)] sm:inline-flex"
        >
          <SidebarLeft className="h-[19px] w-[19px]" />
        </span>
      </div>

      <div className="flex flex-col sm:h-[480px] sm:flex-row">
        <Sidebar tab={tab} onSelect={selectTab} />

        <div className="min-h-[380px] flex-1 overflow-y-auto sm:min-h-0">
          {tab === "status" && (
            <StatusPane
              micStatus={micStatus}
              onRemoveMic={() => changeMic("notSetUp")}
              onEnableMic={() => changeMic("ready")}
              onOpenSetup={openSetup}
            />
          )}
          {tab === "cameras" && <CamerasPane activeId={activeId} statuses={statuses} onSelect={selectSource} />}
          {tab === "preview" && (
            <PreviewPane
              source={activeSource}
              status={activeSource ? statuses[activeSource.id] : null}
              streaming={streaming}
            />
          )}
          {tab === "general" && <GeneralPane settings={general} onChange={setGeneral} />}
          {tab === "logs" && <LogsPane entries={logs} onClear={() => setLogs([])} />}
        </div>
      </div>
    </div>
  );
}
