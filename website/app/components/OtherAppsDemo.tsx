"use client";

import { useState } from "react";
import { Checkmark, TestPattern } from "./mac";

/* What another app gets from LemurCam: a camera named "LemurCam" and, with
   the microphone set up, an input named "LemurCam Microphone"
   (LemurCamConfig.virtualCameraName, Audio/Info.plist).

   While LemurCam has no video to send, the camera sends a still message frame
   instead. The messages and their drawing are recreated from the source:
   - App/RTSP/StreamCoordinator.swift and App/CameraExtension/FrameGenerator.swift
     pick the message; Extension/ExtensionDeviceSource.swift sends
     "LemurCam is not running" when the app isn't feeding frames.
   - Shared/PlaceholderRenderer.swift draws it: a 0.12 gray background, the text
     in 0.85 gray Helvetica Neue Bold (48 px, or 64 px for the extension's
     message) centred above the middle, and a mirrored copy below a 20 px gap.

   Deliberate liberties:
   - The menus are a generic app's, not any particular app's; the other device
     names are examples.
   - The frame is drawn at 1920x1080 (the 1080p setting) and scaled to fit.
   - Live video is a sample test pattern. */

type FrameState = "live" | "connecting" | "reconnecting" | "noCamera" | "notRunning";

const STATES: { id: FrameState; label: string; when: string }[] = [
  {
    id: "live",
    label: "Streaming",
    when: "Video from your active camera.",
  },
  {
    id: "connecting",
    label: "Connecting",
    when: "While LemurCam connects to the camera, including while it looks up an ONVIF camera’s stream address.",
  },
  {
    id: "reconnecting",
    label: "Reconnecting",
    when: "After a connection fails or drops, while LemurCam waits to try again.",
  },
  {
    id: "noCamera",
    label: "No camera selected",
    when: "When no camera is set as the active camera in LemurCam.",
  },
  {
    id: "notRunning",
    label: "App not running",
    when: "Sent by the camera extension itself when the LemurCam app isn’t sending frames, for example after you quit it.",
  },
];

const MESSAGE: Record<Exclude<FrameState, "live">, { text: string; size: number }> = {
  connecting: { text: "Connecting in LemurCam", size: 48 },
  reconnecting: { text: "Reconnecting in LemurCam", size: 48 },
  noCamera: { text: "No camera available in LemurCam", size: 48 },
  notRunning: { text: "LemurCam is not running", size: 64 },
};

/** PlaceholderRenderer.render at 1920x1080. */
function PlaceholderFrame({ text, size }: { text: string; size: number }) {
  // Core Graphics draws from a bottom-left origin: the first line's baseline
  // sits 10 px above the middle; the mirrored copy's baseline sits a line
  // height (ascent + descent, about 1.165 em in Helvetica Neue) below the gap.
  const lineHeight = size * 1.165;
  const font = {
    fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
    fontWeight: 700,
    fontSize: size,
    fill: "#d9d9d9",
    textAnchor: "middle" as const,
  };
  return (
    <svg viewBox="0 0 1920 1080" className="block h-full w-full" role="img" aria-label={`A gray frame reading “${text}”, with a mirrored copy below it`}>
      <rect width="1920" height="1080" fill="#1f1f1f" />
      <text x="960" y={530} {...font}>
        {text}
      </text>
      <g transform="translate(1920 0) scale(-1 1)">
        <text x="960" y={550 + lineHeight} {...font}>
          {text}
        </text>
      </g>
    </svg>
  );
}

function DeviceMenu({ title, items }: { title: string; items: { name: string; on: boolean }[] }) {
  return (
    <div className="min-w-0 flex-1">
      <p className="mb-1 text-[11px] font-semibold text-mac-secondary">{title}</p>
      <ul className="rounded-[10px] bg-mac-menu p-[5px] text-[13px] mac-shadow">
        {items.map((item) => (
          <li
            key={item.name}
            className={`flex items-center gap-1.5 rounded-[6px] px-2 py-[3px] ${
              item.on ? "font-medium" : "text-mac-label"
            }`}
          >
            <span className="inline-flex w-3.5 shrink-0 justify-center">
              {item.on && <Checkmark className="h-3 w-3" />}
            </span>
            <span className="truncate">{item.name}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

export default function OtherAppsDemo() {
  const [state, setState] = useState<FrameState>("connecting");
  const current = STATES.find((s) => s.id === state)!;

  return (
    <figure className="m-0">
      <div className="mac rounded-xl border border-stage-line bg-stage p-4 sm:p-6">
        <div className="overflow-hidden rounded-[10px] bg-black mac-shadow">
          <div className="aspect-video">
            {state === "live" ? <TestPattern fps={30} /> : <PlaceholderFrame {...MESSAGE[state]} />}
          </div>
        </div>
        <div className="mt-5 flex flex-col gap-4 sm:flex-row">
          <DeviceMenu
            title="Camera"
            items={[
              { name: "FaceTime HD Camera", on: false },
              { name: "LemurCam", on: true },
            ]}
          />
          <DeviceMenu
            title="Microphone"
            items={[
              { name: "MacBook Pro Microphone", on: false },
              { name: "LemurCam Microphone", on: true },
            ]}
          />
        </div>
      </div>

      <fieldset className="mt-4">
        <legend className="text-sm font-medium">What LemurCam is doing</legend>
        <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1.5 text-sm">
          {STATES.map((s) => (
            <label key={s.id} className="inline-flex cursor-pointer items-center gap-1.5">
              <input
                type="radio"
                name="other-apps-state"
                value={s.id}
                checked={state === s.id}
                onChange={() => setState(s.id)}
                className="accent-accent"
              />
              {s.label}
            </label>
          ))}
        </div>
        <p className="mt-2 text-sm text-muted" aria-live="polite">
          {current.when}
        </p>
      </fieldset>
      <figcaption className="mt-3 text-sm leading-relaxed text-muted">
        The frame is what the LemurCam camera sends, before any app mirrors
        your self-view. The message frames are drawn from the app’s source;
        the live picture is a sample test pattern. The menus are a generic
        app’s, not any particular one.
      </figcaption>
    </figure>
  );
}
