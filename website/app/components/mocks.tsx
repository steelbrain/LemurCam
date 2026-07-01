import Image from "next/image";
import { CameraIcon, CheckIcon } from "./icons";

/* Small CSS-animated recreations of the app's key moments, used in the
   "how it works" steps. Server components — all motion is CSS. */

function Frame({ children }: { children: React.ReactNode }) {
  return (
    <div className="mx-auto w-full max-w-sm overflow-hidden rounded-[14px] bg-[#f4f3f7] text-[#1d1c22] shadow-[0_32px_64px_-20px_rgba(0,0,0,0.6)] ring-1 ring-white/10 [font-family:system-ui,-apple-system,sans-serif]">
      {children}
    </div>
  );
}

function TitleBar({ title }: { title: string }) {
  return (
    <div className="relative flex h-10 items-center border-b border-black/8 px-3.5">
      <span className="flex gap-1.5">
        <span className="h-2.5 w-2.5 rounded-full bg-[#ff5f57]" />
        <span className="h-2.5 w-2.5 rounded-full bg-[#febc2e]" />
        <span className="h-2.5 w-2.5 rounded-full bg-[#28c840]" />
      </span>
      <span className="absolute inset-x-0 text-center text-[12px] font-semibold">
        {title}
      </span>
    </div>
  );
}

export function WizardMock() {
  return (
    <Frame>
      <TitleBar title="Set Up LemurCam" />
      <div className="px-6 py-7 text-center">
        <Image
          src="/icon.png"
          alt=""
          width={40}
          height={40}
          className="mx-auto rounded-[10px]"
        />
        <p className="mt-2 text-[13px] font-semibold">Set Up LemurCam</p>
        <p className="text-[11px] text-black/40">Step 1 of 3</p>
        <div className="mx-auto mt-2 flex w-16 gap-1">
          <span className="h-1 flex-1 rounded-full bg-[#0a68ff]" />
          <span className="h-1 flex-1 rounded-full bg-black/10" />
          <span className="h-1 flex-1 rounded-full bg-black/10" />
        </div>

        <div className="mt-7">
          <span className="anim-pop relative mx-auto inline-flex h-16 w-16 items-center justify-center rounded-2xl bg-[#34c759] text-white shadow-lg shadow-[#34c759]/30">
            <CameraIcon className="h-8 w-8" />
            <span className="absolute -bottom-1 -right-1 inline-flex h-6 w-6 items-center justify-center rounded-full bg-white text-[#34c759] shadow">
              <CheckIcon className="h-3.5 w-3.5" strokeWidth={2.4} />
            </span>
          </span>
          <p className="mt-4 text-[14px] font-semibold">Virtual Camera</p>
          <p className="mx-auto mt-1 max-w-[220px] text-[12px] leading-relaxed text-black/50">
            Ready — other apps can now select &ldquo;LemurCam&rdquo;.
          </p>
        </div>
      </div>
      <div className="flex justify-end border-t border-black/8 px-4 py-3">
        <span className="rounded-md bg-[#0a68ff] px-3.5 py-1 text-[12px] font-medium text-white shadow-sm">
          Continue
        </span>
      </div>
    </Frame>
  );
}

export function DiscoveryMock() {
  return (
    <Frame>
      <TitleBar title="Add Camera" />
      <div className="space-y-2 p-4">
        <div className="flex items-center gap-3 rounded-lg border border-[#0a68ff]/40 bg-[#0a68ff]/6 px-3.5 py-3">
          <CameraIcon className="h-5 w-5 shrink-0 text-black/50" />
          <span className="min-w-0 flex-1">
            <span className="block text-[13px] font-medium">Backyard Cam</span>
            <span className="block truncate font-mono text-[11px] text-black/40">
              rtsp://192.168.1.115:554/stream1
            </span>
          </span>
          <span className="inline-flex items-center gap-1.5 text-[11px] text-[#1d9d43]">
            <span className="pulse-dot h-1.5 w-1.5 rounded-full bg-[#34c759]" />
            Connected
          </span>
        </div>

        <div className="flex items-center gap-3 rounded-lg border border-black/8 bg-white px-3.5 py-3">
          <CameraIcon className="h-5 w-5 shrink-0 text-black/30" />
          <span className="min-w-0 flex-1">
            <span className="block text-[13px] font-medium text-black/60">
              Front Door
            </span>
            <span className="block font-mono text-[11px] text-black/35">
              onvif://192.168.1.82 · found just now
            </span>
          </span>
          <span className="rounded-md border border-black/10 bg-white px-2 py-0.5 text-[11px] text-[#0a68ff] shadow-sm">
            Add
          </span>
        </div>

        <p className="flex items-center gap-1 px-1 pt-1 text-[11px] text-black/40">
          Scanning your network
          <span className="flex gap-0.5">
            {[0, 1, 2].map((i) => (
              <span
                key={i}
                className="pulse-dot h-[3px] w-[3px] rounded-full bg-black/40"
                style={{ animationDelay: `${i * 0.3}s`, animationDuration: "1.2s" }}
              />
            ))}
          </span>
        </p>
      </div>
    </Frame>
  );
}

export function PickerMock() {
  const others = ["FaceTime HD Camera", "iPhone Camera"];
  return (
    <Frame>
      <div className="border-b border-black/8 px-4 py-2.5 text-[11px] font-medium uppercase tracking-wide text-black/40">
        Select a camera
      </div>
      <div className="p-1.5">
        {others.map((name) => (
          <div
            key={name}
            className="flex items-center gap-2.5 rounded-md px-2.5 py-2 text-[13px] text-black/70"
          >
            <span className="w-4" />
            {name}
          </div>
        ))}
        <div className="flex items-center gap-2.5 rounded-md bg-[#0a68ff] px-2.5 py-2 text-[13px] font-medium text-white shadow-sm">
          <CheckIcon className="h-4 w-4" strokeWidth={2.2} />
          LemurCam
          <span className="ml-auto inline-flex items-center gap-1.5 font-mono text-[9px] uppercase tracking-[0.14em] text-white/80">
            <span className="pulse-dot h-1.5 w-1.5 rounded-full bg-[#5affa0]" />
            Live
          </span>
        </div>
      </div>
      <div className="border-t border-black/8 px-4 py-2.5 text-[11px] text-black/35">
        Your next call, with the lens you actually want.
      </div>
    </Frame>
  );
}
