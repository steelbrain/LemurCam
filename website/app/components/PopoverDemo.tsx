"use client";

import { useState, type ReactNode } from "react";
import { useBridge } from "./Bridge";
import {
  ArrowClockwiseCircle,
  Gear,
  MacButton,
  PopUpButton,
  Spinner,
  TestPattern,
  VideoSlash,
  WebCamera,
  WrenchScrewdriver,
  useTimeouts,
} from "./mac";
import { SOURCES, STATUS_COLOR, STATUS_LABEL, connectDelay, type ConnectionStatus } from "./samples";

/* The menu bar item and its popover, recreated from App/MenuBar/PopoverView.swift
   (and AppDelegate's status item). The popover is 300 points wide. While the
   camera is set up it shows the camera picker, the Settings button, a 180-point
   black preview area and a status bar; in every other camera state it shows
   that state's message and action (ExtensionState).

   Deliberate liberties:
   - Sample cameras, and a test pattern in place of camera video.
   - Connecting, Restart LemurCam and Repair finish on short timers.
   - Set Up LemurCam, Open Setup and Settings scroll to those windows'
     recreations further down the page.
   - Only the LemurCam item is drawn in the menu bar. */

type PopoverState =
  | "running"
  | "settingUp"
  | "notEnabled"
  | "needsAppRestart"
  | "needsRepair"
  | "needsReboot";

// The camera card's status words in Settings → Setup & Status, for the same
// states (StatusSettingsView.cameraStatusText).
const STATES: { id: PopoverState; label: string }[] = [
  { id: "running", label: "Running" },
  { id: "settingUp", label: "Working…" },
  { id: "notEnabled", label: "Needs approval" },
  { id: "needsAppRestart", label: "Restart app" },
  { id: "needsRepair", label: "Repair needed" },
  { id: "needsReboot", label: "Restart Mac" },
];

function EmptyState({ icon, title, subtitle }: { icon: ReactNode; title: string; subtitle: string }) {
  return (
    <div className="flex flex-col items-center gap-2 px-3 text-center">
      <span className="text-white/40">{icon}</span>
      <span className="text-[11px] font-medium text-white/70">{title}</span>
      <span className="text-[10px] whitespace-pre-line text-white/40">{subtitle}</span>
    </div>
  );
}

function MessageView({
  icon,
  title,
  message,
  action,
}: {
  icon?: ReactNode;
  title: string;
  message: string;
  action?: ReactNode;
}) {
  return (
    <div className="flex flex-col items-center gap-3 p-4 text-center">
      {icon && <span className="text-mac-secondary">{icon}</span>}
      <p className="text-[13px] font-bold">{title}</p>
      <p className="text-[11px] whitespace-pre-line text-mac-secondary">{message}</p>
      {action}
    </div>
  );
}

export default function PopoverDemo() {
  const { openSettings, openSetup } = useBridge();
  const [open, setOpen] = useState(true);
  const [state, setState] = useState<PopoverState>("running");
  const [activeId, setActiveId] = useState<string | null>("backyard");
  const [status, setStatus] = useState<ConnectionStatus>("connected");
  const timers = useTimeouts();

  const source = SOURCES.find((s) => s.id === activeId) ?? null;
  const streaming = state === "running" && open && source !== null && status === "connected";

  // StreamCoordinator.syncToActiveSource with the popover's preview demand.
  const connect = (id: string | null) => {
    timers.cancelAll();
    const next = SOURCES.find((s) => s.id === id);
    if (!next) return;
    setStatus("connecting");
    timers.after(connectDelay(next), () => setStatus("connected"));
  };

  const selectSource = (id: string | null) => {
    setActiveId(id);
    connect(id);
  };

  const setCameraState = (to: PopoverState) => {
    timers.cancelAll();
    setState(to);
    // Back to Running: the preview creates demand again and the camera reconnects.
    if (to === "running" && state !== "running") connect(activeId);
  };

  const toggle = () => {
    const next = !open;
    setOpen(next);
    // Closing the popover drops its preview demand; opening it connects again.
    if (next && state === "running") connect(activeId);
    else timers.cancelAll();
  };

  let content: ReactNode;
  switch (state) {
    case "running":
      content = (
        <>
          {/* topBar */}
          <div className="flex items-center gap-1.5 px-3 pt-2.5 pb-1.5">
            <PopUpButton
              label="Camera"
              size="small"
              value={activeId ?? ""}
              options={[{ value: "", label: "None" }, ...SOURCES.map((s) => ({ value: s.id, label: s.name }))]}
              onChange={(v) => selectSource(v || null)}
            />
            <span className="flex-1" />
            <button
              type="button"
              onClick={() => openSettings()}
              className="inline-flex cursor-pointer items-center gap-1 rounded-[4px] px-1.5 py-1 text-[10px] text-mac-secondary hover:text-mac-label"
            >
              <Gear className="h-[11px] w-[11px]" />
              Settings
            </button>
          </div>
          {/* previewArea */}
          <div className="mx-2 flex h-[180px] items-center justify-center overflow-hidden rounded-[6px] bg-black">
            {!source ? (
              <EmptyState
                icon={<VideoSlash className="h-6 w-6" />}
                title="No Camera Selected"
                subtitle={"Select a camera above to\nstart streaming."}
              />
            ) : streaming ? (
              <TestPattern key={source.id} fps={source.fps} />
            ) : (
              <div className="flex flex-col items-center gap-2 text-white">
                <Spinner className="h-3.5 w-3.5" />
                <span className="text-[10px] text-white/60">Connecting…</span>
              </div>
            )}
          </div>
          {/* statusBar */}
          <div className="flex min-h-[30px] items-center gap-3 px-3 py-2">
            {source && (
              <>
                <span className="inline-flex items-center gap-1">
                  <span
                    aria-hidden
                    className="inline-block h-[7px] w-[7px] rounded-full"
                    style={{ background: STATUS_COLOR[status] }}
                  />
                  <span className="text-[10px] text-mac-secondary">{STATUS_LABEL[status]}</span>
                </span>
                <span className="flex-1" />
                {streaming && (
                  <span className="flex gap-2 text-[10px] text-mac-tertiary">
                    <span>{`${source.width}x${source.height}`}</span>
                    <span>{`${source.fps} fps`}</span>
                  </span>
                )}
              </>
            )}
          </div>
        </>
      );
      break;
    case "settingUp":
      content = (
        <div className="flex flex-col items-center gap-3 p-4">
          <Spinner className="h-3.5 w-3.5 text-mac-secondary" />
          <p className="text-[13px] font-bold">Setting Up LemurCam…</p>
          <MacButton size="small" onClick={openSetup}>
            Open Setup
          </MacButton>
        </div>
      );
      break;
    case "needsReboot":
      content = (
        <MessageView
          title="Extension Update Pending"
          message={"Restart your Mac to complete\nthe extension update."}
        />
      );
      break;
    case "needsAppRestart":
      content = (
        <MessageView
          icon={<ArrowClockwiseCircle className="h-7 w-7" />}
          title="Almost Done"
          message={"Restart LemurCam to finish setting up\nthe camera. Only the app restarts."}
          action={
            <MacButton variant="prominent" onClick={() => setCameraState("running")}>
              Restart LemurCam
            </MacButton>
          }
        />
      );
      break;
    case "needsRepair":
      content = (
        <MessageView
          icon={<WrenchScrewdriver className="h-7 w-7" />}
          title="Repair Needed"
          message={"Multiple LemurCam camera extensions are\ninstalled. Repair to fix it."}
          action={
            <MacButton
              variant="prominent"
              onClick={() => {
                setCameraState("settingUp");
                timers.after(1600, () => setCameraState("running"));
              }}
            >
              Repair
            </MacButton>
          }
        />
      );
      break;
    case "notEnabled":
      content = (
        <MessageView
          icon={<VideoSlash className="h-7 w-7" />}
          title="LemurCam Isn’t Set Up"
          message={"Finish setting up the LemurCam camera\nto start streaming."}
          action={
            <MacButton variant="prominent" onClick={openSetup}>
              Set Up LemurCam
            </MacButton>
          }
        />
      );
      break;
  }

  return (
    <figure className="m-0">
      <div className="mac relative min-h-[320px] overflow-hidden rounded-xl border border-stage-line bg-stage">
        {/* Menu bar with LemurCam's status item */}
        <div className="relative h-[26px] bg-mac-menubar text-mac-menubar-fg">
          <button
            type="button"
            onClick={toggle}
            aria-label="LemurCam"
            aria-expanded={open}
            aria-controls="lemurcam-popover"
            className={`absolute top-[2px] left-[calc(50%-15px)] inline-flex h-[22px] w-[30px] cursor-pointer items-center justify-center rounded-[5px] ${
              open ? "bg-mac-control-hover" : "hover:bg-mac-control"
            }`}
          >
            <WebCamera className="h-[17px] w-[17px]" />
          </button>
        </div>

        {open ? (
          <div
            id="lemurcam-popover"
            role="dialog"
            aria-label="LemurCam"
            className="absolute top-[34px] left-1/2 w-[300px] max-w-[calc(100%-16px)] -translate-x-1/2 rounded-[14px] bg-mac-popover mac-shadow"
          >
            {/* Arrow pointing at the status item */}
            <span
              aria-hidden
              className="absolute -top-[6px] left-[calc(50%-6px)] h-3 w-3 rotate-45 rounded-[2px] bg-mac-popover"
            />
            <div className="relative">{content}</div>
          </div>
        ) : (
          <p className="absolute top-[60px] right-[20px] left-[20px] text-center text-[12px] text-mac-secondary">
            Popover closed. Click the camera icon in the menu bar to open it.
          </p>
        )}
      </div>

      <fieldset className="mt-4">
        <legend className="text-sm font-medium">Camera status</legend>
        <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1.5 text-sm">
          {STATES.map((s) => (
            <label key={s.id} className="inline-flex cursor-pointer items-center gap-1.5">
              <input
                type="radio"
                name="popover-state"
                value={s.id}
                checked={state === s.id}
                onChange={() => setCameraState(s.id)}
                className="accent-accent"
              />
              {s.label}
            </label>
          ))}
        </div>
      </fieldset>
      <figcaption className="mt-3 text-sm leading-relaxed text-muted">
        A working recreation of the menu bar popover, built from the app’s
        SwiftUI source. Pick a camera, close and reopen the popover from the
        menu bar, or change the camera status to see each message the popover
        can show. Settings and Set Up LemurCam take you to those windows
        further down. The cameras and the test-pattern video are samples, and
        only LemurCam’s item is drawn in the menu bar.
      </figcaption>
    </figure>
  );
}
