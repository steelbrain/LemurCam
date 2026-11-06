"use client";

import Image from "next/image";
import { useState, type ReactNode } from "react";
import { useBridge, useWindowHandler } from "./Bridge";
import {
  CircleFill,
  MacButton,
  MicFill,
  Spinner,
  TrafficLights,
  VideoBadgePlus,
  VideoFill,
  useTimeouts,
  type StepState,
} from "./mac";

/* The guided setup window (480 x 500 points plus its title bar), recreated from
   App/Setup/SetupView.swift, SetupStep.swift and SetupDeviceHero.swift: the
   header with the step indicator, one device "hero" per step with its detail
   text and action, and the footer buttons SetupFooterButtons picks.

   It starts as a first launch does: LemurCam has already asked macOS to
   install the camera (SetupCoordinator.start), so step 1 waits for approval.

   Deliberate liberties:
   - Clicking Open System Settings stands in for approving LemurCam there.
   - Installs finish on short timers. In the app, a camera that does not come
     live in time asks for one restart of LemurCam first.
   - Add Camera scrolls to the Settings recreation and opens its Cameras pane,
     which has its own sample cameras.
   - Done, Set Up Later and closing the window hide it; a page button brings
     it back. */

type CameraStatus = "awaitingApproval" | "installing" | "ready";
type MicStatus = "notSetUp" | "needsApproval" | "installing" | "ready";
type Step = 0 | 1 | 2;

const STEP_COUNT = 3;

function cameraState(status: CameraStatus): StepState {
  return status === "ready" ? "ready" : status === "installing" ? "working" : "actionNeeded";
}

function micState(status: MicStatus): StepState {
  // SetupView.micStepState: Not set up counts as an action, not a neutral to-do.
  return status === "ready" ? "ready" : status === "installing" ? "working" : "actionNeeded";
}

const CAMERA_DETAIL: Record<CameraStatus, string> = {
  awaitingApproval:
    "Allow LemurCam in System Settings → General → Login Items & Extensions, then come back here.",
  installing: "Installing… this can take a few seconds.",
  ready: "Ready — other apps can now select “LemurCam”.",
};

const MIC_DETAIL: Record<MicStatus, string> = {
  notSetUp: "Optional. Adds a microphone fed by your camera’s audio. You can skip this.",
  needsApproval:
    "Approve LemurCam in System Settings → General → Login Items & Extensions, then come back.",
  installing: "Setting up… this can take a few seconds.",
  ready: "Ready — “LemurCam Microphone” is available to other apps.",
};

/** SetupDeviceHero: tinted tile, corner status indicator, title and detail. */
function DeviceHero({
  icon,
  title,
  detail,
  state,
}: {
  icon: ReactNode;
  title: string;
  detail: string;
  state: StepState;
}) {
  const color =
    state === "ready" ? "var(--mac-green)" : state === "failed" ? "var(--mac-red)" : "var(--mac-accent)";
  return (
    <div className="flex flex-col items-center gap-4">
      <div className="relative">
        {state === "working" && (
          <span
            aria-hidden
            className="setup-halo absolute inset-0 rounded-[26px]"
            style={{ background: "color-mix(in srgb, var(--mac-accent) 22%, transparent)" }}
          />
        )}
        {state === "ready" && (
          <span aria-hidden className="setup-ring absolute inset-0 rounded-[22px] border-[3px] border-mac-green" />
        )}
        <span
          className="relative inline-flex h-[88px] w-[88px] items-center justify-center rounded-[22px] text-white"
          style={{
            background: `linear-gradient(135deg, ${color}, color-mix(in srgb, ${color} 65%, transparent))`,
            boxShadow: `0 4px 22px color-mix(in srgb, ${color} 30%, transparent)`,
          }}
        >
          {icon}
        </span>
        <span className="absolute -right-[6px] -bottom-[6px]">
          {state === "working" && (
            <span className="inline-flex h-[26px] w-[26px] items-center justify-center rounded-full border border-mac-sep bg-mac-window text-mac-secondary">
              <Spinner className="h-3.5 w-3.5" />
            </span>
          )}
          {state === "actionNeeded" && (
            <span className="inline-flex rounded-full bg-white p-[2px]">
              <CircleFill kind="exclamation" className="h-[22px] w-[22px]" />
            </span>
          )}
          {state === "ready" && (
            <span className="inline-flex rounded-full bg-white p-[2px]">
              <CircleFill kind="check" className="h-[22px] w-[22px]" />
            </span>
          )}
        </span>
      </div>
      <div className="flex flex-col items-center gap-1.5 text-center">
        <p className="text-[17px] font-bold">{title}</p>
        <p className="max-w-[360px] text-[12px] text-mac-secondary" aria-live="polite">
          {detail}
        </p>
      </div>
    </div>
  );
}

export default function SetupWindow() {
  const { openSettings } = useBridge();
  const [open, setOpen] = useState(true);
  const [step, setStep] = useState<Step>(0);
  const [back, setBack] = useState(false);
  const [camera, setCamera] = useState<CameraStatus>("awaitingApproval");
  const [mic, setMic] = useState<MicStatus>("notSetUp");
  const timers = useTimeouts();

  // AppDelegate.openSetupWindow: an open window comes to the front; a closed
  // one opens again at the first step.
  const reopen = () => {
    if (open) return;
    setStep(0);
    setBack(false);
    setOpen(true);
  };
  useWindowHandler("setup", reopen);

  const startOver = () => {
    timers.cancelAll();
    setCamera("awaitingApproval");
    setMic("notSetUp");
    setStep(0);
    setBack(false);
    setOpen(true);
  };

  const go = (to: Step) => {
    setBack(to < step);
    setStep(to);
  };

  const cameraReady = camera === "ready"; // SetupCameraGate.canAdvance
  const micReady = mic === "ready";

  let hero: ReactNode;
  let control: ReactNode = null;
  if (step === 0) {
    hero = (
      <DeviceHero
        icon={<VideoFill className="h-12 w-12" />}
        title="Virtual Camera"
        detail={CAMERA_DETAIL[camera]}
        state={cameraState(camera)}
      />
    );
    if (camera === "awaitingApproval") {
      control = (
        <MacButton
          variant="prominent"
          size="large"
          onClick={() => {
            setCamera("installing");
            timers.after(1800, () => setCamera("ready"));
          }}
        >
          Open System Settings
        </MacButton>
      );
    }
  } else if (step === 1) {
    hero = (
      <DeviceHero
        icon={<MicFill className="h-12 w-12" />}
        title="Virtual Microphone"
        detail={MIC_DETAIL[mic]}
        state={micState(mic)}
      />
    );
    if (mic === "notSetUp") {
      control = (
        <MacButton variant="prominent" size="large" onClick={() => setMic("needsApproval")}>
          Enable Microphone
        </MacButton>
      );
    } else if (mic === "needsApproval") {
      control = (
        <MacButton
          variant="prominent"
          size="large"
          onClick={() => {
            setMic("installing");
            timers.after(1800, () => setMic("ready"));
          }}
        >
          Open System Settings
        </MacButton>
      );
    }
  } else {
    hero = (
      <DeviceHero
        icon={<VideoBadgePlus className="h-14 w-14 [--tile-ink:var(--mac-accent)]" />}
        title="Your Camera"
        detail="Add an IP camera (RTSP or ONVIF) so LemurCam has a feed to stream."
        state="inactive"
      />
    );
    control = (
      <MacButton
        variant="prominent"
        size="large"
        onClick={() => {
          setOpen(false);
          openSettings("cameras");
        }}
      >
        Add Camera
      </MacButton>
    );
  }

  // SetupFooterButtons.leading / .primary
  const leading =
    step > 0 ? (
      <MacButton onClick={() => go((step - 1) as Step)}>Back</MacButton>
    ) : !cameraReady ? (
      <MacButton variant="borderless" onClick={() => setOpen(false)}>
        Set Up Later
      </MacButton>
    ) : null;

  let primary: ReactNode = null;
  if (step === 0 && cameraReady) {
    primary = (
      <MacButton variant="prominent" onClick={() => go(1)}>
        Continue
      </MacButton>
    );
  } else if (step === 1) {
    primary = (
      <MacButton variant="prominent" onClick={() => go(2)}>
        {micReady ? "Continue" : "Skip for Now"}
      </MacButton>
    );
  } else if (step === 2) {
    primary = (
      <MacButton variant="prominent" onClick={() => setOpen(false)}>
        Done
      </MacButton>
    );
  }

  return (
    <div>
      {open ? (
        <div
          id="setup-window"
          tabIndex={-1}
          role="group"
          aria-label="Set Up LemurCam window recreation"
          className="mac mx-auto flex w-full max-w-[480px] flex-col overflow-hidden rounded-[20px] bg-mac-window mac-shadow outline-none"
        >
          {/* Title bar */}
          <div className="flex h-[32px] shrink-0 items-center gap-4 border-b border-mac-sep px-3">
            <TrafficLights />
            <span className="text-[13px] font-semibold text-mac-title">Set Up LemurCam</span>
          </div>

          <div className="flex h-[500px] flex-col">
            {/* Header */}
            <div className="flex flex-col items-center gap-3 px-6 pt-[18px] pb-[14px]">
              <Image src="/icon.png" alt="" width={60} height={60} />
              <p className="text-[17px] font-bold">Set Up LemurCam</p>
              <div className="flex flex-col items-center gap-2">
                <p className="text-[12px] font-medium text-mac-secondary">
                  Step {step + 1} of {STEP_COUNT}
                </p>
                <span className="flex gap-1.5" aria-hidden>
                  {Array.from({ length: STEP_COUNT }, (_, i) => (
                    <span
                      key={i}
                      className="h-[7px] rounded-full transition-[width] duration-300"
                      style={{
                        width: i === step ? 22 : 7,
                        background: i <= step ? "var(--mac-accent)" : "rgba(128,128,128,0.25)",
                      }}
                    />
                  ))}
                </span>
              </div>
            </div>
            <div className="border-t border-mac-sep" />

            {/* Step content */}
            <div className="flex flex-1 items-center justify-center overflow-hidden px-7">
              <div key={step} className={`flex flex-col items-center gap-6 ${back ? "setup-in-back" : "setup-in"}`}>
                {hero}
                {control}
              </div>
            </div>

            <div className="border-t border-mac-sep" />
            {/* Footer */}
            <div className="flex min-h-[56px] items-center p-4">
              {leading}
              <span className="flex-1" />
              {primary}
            </div>
          </div>
        </div>
      ) : (
        <div
          id="setup-window"
          tabIndex={-1}
          className="flex min-h-[200px] flex-col items-start justify-center gap-3 rounded-[20px] border border-dashed border-stage-line p-6 outline-none"
        >
          <p className="text-sm text-muted">The setup window is closed.</p>
          <button
            type="button"
            onClick={reopen}
            className="cursor-pointer rounded-md border border-line px-3 py-1.5 text-sm font-medium hover:bg-stage"
          >
            Open it again
          </button>
        </div>
      )}
      <p className="mt-4">
        <button
          type="button"
          onClick={startOver}
          className="cursor-pointer text-sm font-medium text-accent underline underline-offset-2"
        >
          Start the setup over
        </button>
      </p>
    </div>
  );
}
