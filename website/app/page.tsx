import Image from "next/image";
import type { ReactNode } from "react";
import AppWindow from "./components/AppWindow";
import { BridgeProvider } from "./components/Bridge";
import PopoverDemo from "./components/PopoverDemo";
import SetupWindow from "./components/SetupWindow";

// The same links README.md uses.
const DOWNLOAD_URL = "https://github.com/steelbrain/LemurCam/releases/latest";
const GITHUB_URL = "https://github.com/steelbrain/LemurCam";
const CHANGELOG_URL = "https://github.com/steelbrain/LemurCam/blob/main/CHANGELOG.md";
const LICENSE_URL = "https://github.com/steelbrain/LemurCam/blob/main/LICENSE.md";
const ISSUES_URL = "https://github.com/steelbrain/LemurCam/issues/new";
const AUTHOR_URL = "https://aneesiqbal.ai/";

const container = "mx-auto w-full max-w-6xl px-4 sm:px-6";

function Section({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section id={id} aria-labelledby={`${id}-title`} className="border-t border-line py-16 sm:py-20">
      <div className={container}>
        <h2 id={`${id}-title`} className="text-2xl font-semibold tracking-tight sm:text-3xl">
          {title}
        </h2>
        {children}
      </div>
    </section>
  );
}

function Prose({ children }: { children: ReactNode }) {
  return <div className="mt-4 max-w-[38rem] space-y-4 text-[17px] leading-relaxed">{children}</div>;
}

/** A term and its description per row; the term sits above on phones. */
function Facts({ items }: { items: [string, ReactNode][] }) {
  return (
    <dl className="mt-6 max-w-[50rem] space-y-4 text-[15px] leading-relaxed">
      {items.map(([term, description]) => (
        <div key={term} className="sm:grid sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-x-10">
          <dt className="font-semibold">{term}</dt>
          <dd className="mt-1 text-muted sm:mt-0">{description}</dd>
        </div>
      ))}
    </dl>
  );
}

const SETTINGS_PANES: [string, ReactNode][] = [
  [
    "Setup & Status",
    "Whether the virtual camera and microphone are running, and the next step for either one when it isn’t. You can also remove the microphone here.",
  ],
  [
    "Cameras",
    "Your cameras, and which one is active. Add a camera by its RTSP URL or an ONVIF URL, or discover ONVIF cameras on your network. Usernames and passwords are kept in your macOS Keychain.",
  ],
  ["Preview", "The active camera’s live picture, with its resolution, codec and frame rate."],
  [
    "General",
    "Launch at Login, and the virtual camera’s resolution (720p, 1080p, 1440p or 4K) and frame rate (30 or 60 fps).",
  ],
  ["Logs", "The app’s log, with Copy All and Clear."],
];

const DETAILS: [string, ReactNode][] = [
  ["Video", "H.264 or H.265 over RTSP, decoded on your Mac with VideoToolbox."],
  [
    "Audio",
    "AAC, G.711 (µ-law and A-law) and L16, converted to 48 kHz stereo for LemurCam Microphone. Turning the microphone on or off doesn’t interrupt the video.",
  ],
  [
    "ONVIF",
    "LemurCam finds ONVIF cameras on your local network with WS-Discovery. Each time it connects to one, it asks the camera for the stream address of the profile you chose. If a camera you added through discovery moves to a new IP address on your network, LemurCam looks for it again.",
  ],
  [
    "Cameras",
    "Compatible camera lines include TP-Link Tapo, Reolink, Hikvision, Dahua, Amcrest and UniFi Protect.",
  ],
  [
    "Your Mac",
    "macOS 14 Sonoma or later, on an Apple Silicon or Intel Mac. LemurCam has to be in your Applications folder, and it needs Local Network access to reach cameras on your network.",
  ],
];

export default function Home() {
  return (
    <BridgeProvider>
      <a
        href="#main"
        className="sr-only focus:not-sr-only focus:absolute focus:top-2 focus:left-2 focus:z-50 focus:rounded focus:bg-bg focus:px-3 focus:py-2"
      >
        Skip to content
      </a>

      <header className={`${container} flex items-center justify-between gap-4 py-5`}>
        <a href="#main" className="flex items-center gap-2.5 font-semibold">
          <Image src="/icon.png" alt="" width={30} height={31} priority />
          LemurCam
        </a>
        <nav aria-label="Site" className="flex items-center gap-5 text-[15px]">
          <a href={DOWNLOAD_URL} className="text-accent hover:underline">
            Download
          </a>
          <a href={GITHUB_URL} className="text-accent hover:underline">
            GitHub
          </a>
        </nav>
      </header>

      <main id="main">
        {/* What it is, next to the menu bar popover */}
        <section aria-labelledby="hero-title" className="pt-8 pb-16 sm:pt-14 sm:pb-20">
          <div className={`${container} grid items-start gap-12 lg:grid-cols-[minmax(0,1fr)_440px] lg:gap-16`}>
            <div className="max-w-[38rem]">
              <h1 id="hero-title" className="text-4xl leading-[1.1] font-semibold tracking-tight sm:text-5xl">
                Turn your IP camera into a Mac webcam
              </h1>
              <p className="mt-6 text-lg leading-relaxed sm:text-xl">
                LemurCam turns an RTSP or ONVIF IP camera that streams H.264 or H.265 into a virtual
                webcam and microphone on macOS.
              </p>
              <p className="mt-4 text-[17px] leading-relaxed text-muted">
                It runs from the menu bar. Other apps see a camera named LemurCam, and, if you set up
                the optional microphone, an input named LemurCam Microphone. Pick them in Zoom, Google
                Meet, FaceTime, OBS or wherever you choose a webcam.
              </p>
              <div className="mt-8 flex flex-wrap gap-3">
                <a
                  href={DOWNLOAD_URL}
                  className="inline-flex items-center rounded-lg bg-accent px-5 py-2.5 text-[15px] font-medium text-accent-fg hover:brightness-110"
                >
                  Download for macOS
                </a>
                <a
                  href={GITHUB_URL}
                  className="inline-flex items-center rounded-lg border border-line px-5 py-2.5 text-[15px] font-medium hover:bg-stage"
                >
                  Source code on GitHub
                </a>
              </div>
              <p className="mt-5 text-sm leading-relaxed text-muted">
                Free and open source under the MIT License. Requires macOS 14 Sonoma or later.
                Universal app for Apple Silicon and Intel Macs.
              </p>
            </div>
            <PopoverDemo />
          </div>
        </section>

        <Section id="setup" title="Guided setup">
          <div className="grid items-start gap-10 lg:grid-cols-[minmax(0,1fr)_560px] lg:gap-16">
            <Prose>
              <p>
                When you first open LemurCam, and again after each update, a setup window walks through
                three steps: the camera, the optional microphone, and adding your IP camera.
              </p>
              <p>
                macOS asks you to approve the camera, and the microphone if you set it up, in System
                Settings → General → Login Items & Extensions. If LemurCam restarts partway through,
                setup reopens at the first step you haven’t finished.
              </p>
              <p className="text-[15px] text-muted">
                A working recreation of the setup window, built from the app’s SwiftUI source. Here,
                clicking Open System Settings stands in for approving LemurCam there, and installs
                finish on short timers. Add Camera takes you to the Cameras pane of the Settings window
                below.
              </p>
            </Prose>
            <div className="mt-2 lg:mt-4">
              <div className="rounded-xl border border-stage-line bg-stage p-4 sm:p-10">
                <SetupWindow />
              </div>
            </div>
          </div>
        </Section>

        <Section id="settings" title="Settings">
          <Prose>
            <p>Settings is a window with five panes in a sidebar.</p>
          </Prose>
          <Facts items={SETTINGS_PANES} />

          <figure className="mt-10">
            <div className="rounded-xl border border-stage-line bg-stage p-3 sm:p-10">
              <AppWindow />
            </div>
            <figcaption className="mt-3 max-w-[48rem] text-sm leading-relaxed text-muted">
              A working recreation of the Settings window, built from the app’s SwiftUI source. As
              in the app, of the Settings panes only Preview keeps the camera connected; switch panes,
              then open Logs to see it. The cameras, log lines and test-pattern video are samples.
              Open Guided Setup… takes you to the setup window above, buttons that open sheets do
              nothing, and Resolution and Frame Rate only change their menus. The windows are drawn
              in the macOS 26 style with approximate colors; on a narrow screen the sidebar becomes a
              row.
            </figcaption>
          </figure>
        </Section>

        <Section id="details" title="Cameras, formats and requirements">
          <Facts items={DETAILS} />
        </Section>

        <Section id="get-started" title="Getting started">
          <ol className="mt-6 max-w-[38rem] list-decimal space-y-3 pl-6 text-[17px] leading-relaxed marker:text-muted">
            <li>
              <a href={DOWNLOAD_URL} className="text-accent underline underline-offset-2">
                Download LemurCam
              </a>{" "}
              and move it to your Applications folder before you open it. macOS doesn’t load system
              extensions from apps outside that folder.
            </li>
            <li>Open LemurCam and enable the camera when it asks.</li>
            <li>If you want the camera’s audio, enable LemurCam Microphone.</li>
            <li>Add your camera.</li>
            <li>
              Allow Local Network access when macOS asks. LemurCam needs it to discover and connect to
              cameras on your network.
            </li>
            <li>In your video app, choose LemurCam as the camera.</li>
          </ol>
        </Section>
      </main>

      <footer className="border-t border-line py-10">
        <div className={`${container} space-y-4 text-sm text-muted`}>
          <nav aria-label="Project" className="flex flex-wrap gap-x-6 gap-y-2">
            <a href={DOWNLOAD_URL} className="text-accent hover:underline">
              Download
            </a>
            <a href={GITHUB_URL} className="text-accent hover:underline">
              GitHub
            </a>
            <a href={CHANGELOG_URL} className="text-accent hover:underline">
              Changelog
            </a>
            <a href={ISSUES_URL} className="text-accent hover:underline">
              Report an issue
            </a>
            <a href={LICENSE_URL} className="text-accent hover:underline">
              MIT License
            </a>
          </nav>
          <p>
            LemurCam is made by{" "}
            <a href={AUTHOR_URL} className="text-accent hover:underline">
              Anees Iqbal
            </a>
            .
          </p>
        </div>
      </footer>
    </BridgeProvider>
  );
}
