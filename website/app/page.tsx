import Image from "next/image";
import AppWindow from "./components/AppWindow";
import { DiscoveryMock, PickerMock, WizardMock } from "./components/mocks";
import Nav from "./components/Nav";
import Reveal from "./components/Reveal";
import Tilt from "./components/Tilt";
import {
  ArrowIcon,
  BroadcastIcon,
  CameraIcon,
  CheckIcon,
  ChipIcon,
  DownloadIcon,
  GithubIcon,
  LeafIcon,
  MicIcon,
  ShieldIcon,
} from "./components/icons";

const DOWNLOAD_URL = "https://github.com/steelbrain/LemurCam/releases/latest";
const GITHUB_URL = "https://github.com/steelbrain/LemurCam";
const CHANGELOG_URL =
  "https://github.com/steelbrain/LemurCam/blob/main/CHANGELOG.md";
const LICENSE_URL =
  "https://github.com/steelbrain/LemurCam/blob/main/LICENSE.md";
const AUTHOR_URL = "https://aneesiqbal.ai/";

const WORKS_WITH = [
  "Zoom",
  "Google Meet",
  "Microsoft Teams",
  "FaceTime",
  "OBS Studio",
  "Discord",
  "Slack",
  "Webex",
  "QuickTime",
  "Photo Booth",
];

const FEATURES = [
  {
    icon: CameraIcon,
    title: "A real virtual camera",
    body: "Every Mac app sees LemurCam as an ordinary webcam — no plugins, no fiddling. Pick it in Zoom, Meet, Teams, FaceTime, OBS and anywhere else.",
  },
  {
    icon: MicIcon,
    title: "Camera audio, too",
    body: "Flip on the optional LemurCam Microphone and your camera's sound flows straight into calls — AAC, G.711 and L16 all pass through.",
  },
  {
    icon: BroadcastIcon,
    title: "RTSP & ONVIF",
    body: "Paste an RTSP URL, or let ONVIF discovery sweep your Wi-Fi and find cameras for you. No port-hunting required.",
  },
  {
    icon: LeafIcon,
    title: "Demand-driven",
    body: "Streams only when an app or the preview is actually watching, then quietly idles. Your camera and CPU get a break.",
  },
  {
    icon: ChipIcon,
    title: "Native & smooth",
    body: "A native VideoToolbox pipeline keeps video buttery at 30fps while sipping CPU — frames stay in their native format end to end.",
  },
];

const STEPS = [
  {
    n: "01",
    title: "Enable the camera",
    body: "A guided setup turns on the LemurCam system extension — and the optional microphone — in a couple of clicks.",
    mock: <WizardMock />,
  },
  {
    n: "02",
    title: "Add your camera",
    body: "Discover cameras on your network or paste an RTSP URL. LemurCam connects, decodes, and shows a live preview.",
    mock: <DiscoveryMock />,
  },
  {
    n: "03",
    title: "Pick it anywhere",
    body: "In any app's camera menu, choose LemurCam. You're live — with the lens you actually wanted to use.",
    mock: <PickerMock />,
  },
];

const CAMERAS = [
  "TP-Link Tapo",
  "Reolink",
  "Hikvision",
  "Dahua",
  "Amcrest",
  "UniFi Protect",
  "Axis",
  "Wyze (RTSP)",
  "Annke",
];

function LiveDot({ className = "" }: { className?: string }) {
  return (
    <span className={`relative inline-flex h-2 w-2 ${className}`}>
      <span className="pulse-dot absolute inline-flex h-full w-full rounded-full bg-emerald-500" />
    </span>
  );
}

export default function Home() {
  return (
    <div id="top" className="font-[family-name:var(--font-geist-sans)]">
      {/* Living background: drifting nebula layers + film grain */}
      <div aria-hidden className="ambient-a" />
      <div aria-hidden className="ambient-b" />
      <div aria-hidden className="grain" />

      <Nav />

      {/* ===================== HERO ===================== */}
      <section className="relative px-5 pt-32 pb-16 sm:px-6 sm:pt-44 sm:pb-24">
        <div
          aria-hidden
          className="dot-grid pointer-events-none absolute inset-x-0 top-0 -z-10 h-[36rem]"
        />

        <div className="mx-auto max-w-3xl text-center">
          <Reveal>
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noreferrer"
              className="group inline-flex items-center gap-2.5 rounded-full border border-border bg-card px-4 py-1.5 font-mono text-[11px] font-medium uppercase tracking-[0.14em] text-muted transition-colors hover:border-border-strong hover:text-foreground"
            >
              <LiveDot />
              Free &amp; open source · macOS 14+
              <ArrowIcon className="h-3 w-3 transition-transform duration-200 group-hover:translate-x-0.5" />
            </a>
          </Reveal>

          <Reveal delay={70}>
            <h1 className="mt-8 text-[2.7rem] font-semibold leading-[1.05] tracking-[-0.03em] sm:text-[4.25rem]">
              Ditch the cable.
              <br />
              <span className="text-gradient">Keep the camera.</span>
            </h1>
          </Reveal>

          <Reveal delay={140}>
            <p className="mx-auto mt-6 max-w-xl text-lg leading-relaxed text-muted">
              LemurCam turns any RTSP or ONVIF IP camera into a virtual webcam
              and microphone on macOS — so you show up on every call with the
              lens you actually want.
            </p>
          </Reveal>

          <Reveal delay={210}>
            <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
              <a
                href={DOWNLOAD_URL}
                className="group inline-flex items-center gap-2 rounded-full bg-foreground px-6 py-3 text-[15px] font-medium text-background shadow-[0_8px_32px_-8px_rgba(167,139,250,0.35)] transition-[transform,box-shadow] duration-200 hover:shadow-[0_10px_40px_-8px_rgba(167,139,250,0.6)] active:scale-[0.98]"
              >
                <DownloadIcon className="h-[18px] w-[18px] transition-transform duration-200 group-hover:translate-y-0.5" />
                Download for macOS
              </a>
              <a
                href={GITHUB_URL}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-2 rounded-full border border-border-strong bg-transparent px-6 py-3 text-[15px] font-medium transition-colors hover:bg-foreground/[0.04]"
              >
                <GithubIcon className="h-[18px] w-[18px]" />
                View source
              </a>
            </div>
          </Reveal>

          <Reveal delay={270}>
            <p className="mt-5 font-mono text-[11px] uppercase tracking-[0.14em] text-muted/80">
              Universal · Apple Silicon &amp; Intel · Signed &amp; notarized
            </p>
          </Reveal>
        </div>

        {/* Hero visual */}
        <Reveal delay={330} className="mx-auto mt-16 max-w-4xl sm:mt-24">
          <Tilt max={3} className="relative">
            <div
              aria-hidden
              className="absolute -inset-x-16 -top-12 -bottom-20 -z-10"
              style={{
                background:
                  "radial-gradient(50% 55% at 50% 45%, rgba(139, 107, 255, 0.22), transparent 70%)",
              }}
            />
            <AppWindow />
          </Tilt>
          <p className="mt-5 text-center font-mono text-[11px] uppercase tracking-[0.14em] text-muted/60">
            Go on, click around — it&apos;s the real interface
          </p>
        </Reveal>
      </section>

      {/* ===================== WORKS WITH (marquee) ===================== */}
      <section className="border-y border-border py-8">
        <p className="mb-5 text-center font-mono text-[11px] font-medium uppercase tracking-[0.18em] text-muted/80">
          Shows up everywhere you already are
        </p>
        <div className="relative overflow-hidden [mask-image:linear-gradient(90deg,transparent,#000_15%,#000_85%,transparent)]">
          <div className="animate-marquee flex w-max items-center">
            {[...WORKS_WITH, ...WORKS_WITH].map((name, i) => (
              <span
                key={`${name}-${i}`}
                className="flex items-center whitespace-nowrap text-[15px] font-medium text-foreground/55"
              >
                {name}
                <span
                  aria-hidden
                  className="mx-6 inline-block h-1 w-1 rounded-full bg-foreground/20"
                />
              </span>
            ))}
          </div>
        </div>
      </section>

      {/* ===================== FEATURES (bento) ===================== */}
      <section
        id="features"
        className="mx-auto max-w-6xl px-5 py-24 sm:px-6 sm:py-32"
      >
        <Reveal className="mx-auto max-w-2xl text-center">
          <p className="font-mono text-[11px] font-medium uppercase tracking-[0.18em] text-accent-ink">
            Everything in the box
          </p>
          <h2 className="mt-4 text-3xl font-semibold tracking-[-0.02em] sm:text-4xl">
            Small menu-bar app. Big camera energy.
          </h2>
          <p className="mt-4 text-lg leading-relaxed text-muted">
            LemurCam lives quietly in your menu bar and does one thing
            beautifully: makes your IP camera feel like it was built into your
            Mac.
          </p>
        </Reveal>

        <div className="mt-14 grid gap-4 md:grid-cols-6">
          {FEATURES.map((f, i) => {
            const Icon = f.icon;
            const span = i < 2 ? "md:col-span-3" : "md:col-span-2";
            return (
              <Reveal key={f.title} delay={(i % 3) * 60} className={span}>
                <article className="group flex h-full flex-col rounded-2xl border border-border bg-card p-6 transition-[border-color,transform,box-shadow] duration-300 hover:-translate-y-0.5 hover:border-border-strong hover:shadow-[0_16px_48px_-16px_rgba(139,107,255,0.25)]">
                  <div className="mb-5 inline-flex h-10 w-10 items-center justify-center rounded-xl bg-accent-soft text-accent-ink">
                    <Icon className="h-5 w-5" />
                  </div>
                  <h3 className="text-[17px] font-semibold tracking-tight">
                    {f.title}
                  </h3>
                  <p className="mt-2 text-[15px] leading-relaxed text-muted">
                    {f.body}
                  </p>

                  {/* One playful flourish, kept: the audio card breathes */}
                  {f.icon === MicIcon && (
                    <div className="mt-6 flex h-8 items-end gap-1">
                      {[0.4, 0.7, 0.3, 0.9, 0.55, 0.8, 0.35, 0.65, 0.45, 0.85, 0.4].map(
                        (s, j) => (
                          <span
                            key={j}
                            className="eq-bar w-1 flex-1 rounded-full bg-accent/60"
                            style={{
                              height: `${s * 100}%`,
                              animationDelay: `${j * 0.13}s`,
                            }}
                          />
                        )
                      )}
                    </div>
                  )}
                </article>
              </Reveal>
            );
          })}
        </div>
      </section>

      {/* ===================== HOW IT WORKS ===================== */}
      <section
        id="how"
        className="border-y border-border bg-white/[0.02] px-5 py-24 sm:px-6 sm:py-32"
      >
        <Reveal className="mx-auto max-w-2xl text-center">
          <p className="font-mono text-[11px] font-medium uppercase tracking-[0.18em] text-accent-ink">
            Up in three steps
          </p>
          <h2 className="mt-4 text-3xl font-semibold tracking-[-0.02em] sm:text-4xl">
            From IP camera to webcam in minutes
          </h2>
        </Reveal>

        <div className="mx-auto mt-16 max-w-5xl space-y-20 sm:space-y-24">
          {STEPS.map((step, i) => (
            <Reveal key={step.n}>
              <div
                className={`flex flex-col items-center gap-10 lg:gap-20 ${
                  i % 2 === 1 ? "lg:flex-row-reverse" : "lg:flex-row"
                }`}
              >
                <div className="flex-1 lg:max-w-md">
                  <span className="font-mono text-sm font-medium tracking-[0.14em] text-accent-ink">
                    {step.n}
                  </span>
                  <h3 className="mt-3 text-2xl font-semibold tracking-tight">
                    {step.title}
                  </h3>
                  <p className="mt-3 text-[17px] leading-relaxed text-muted">
                    {step.body}
                  </p>
                </div>
                <div className="w-full flex-1">{step.mock}</div>
              </div>
            </Reveal>
          ))}
        </div>
      </section>

      {/* ===================== COMPATIBLE CAMERAS ===================== */}
      <section
        id="cameras"
        className="border-y border-border bg-white/[0.02] px-5 py-24 sm:px-6 sm:py-32"
      >
        <div className="mx-auto grid max-w-5xl items-center gap-12 lg:grid-cols-2">
          <Reveal>
            <p className="font-mono text-[11px] font-medium uppercase tracking-[0.18em] text-accent-ink">
              Plays well with
            </p>
            <h2 className="mt-4 text-3xl font-semibold tracking-[-0.02em] sm:text-4xl">
              Bring the camera you already own
            </h2>
            <p className="mt-4 text-lg leading-relaxed text-muted">
              If it speaks RTSP or ONVIF, LemurCam can stream it. That covers
              most popular IP-camera lines — and microphone pass-through works
              whenever the camera sends common audio formats.
            </p>
            <ul className="mt-7 space-y-3">
              {[
                "RTSP URLs and ONVIF auto-discovery",
                "AAC, G.711 and L16 audio pass-through",
                "Credentials stored safely in your Keychain",
              ].map((item) => (
                <li key={item} className="flex items-start gap-3">
                  <CheckIcon className="mt-0.5 h-5 w-5 shrink-0 text-accent-ink" />
                  <span className="text-[15px] text-foreground/80">{item}</span>
                </li>
              ))}
            </ul>
          </Reveal>

          <Reveal delay={100}>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
              {CAMERAS.map((c) => (
                <div
                  key={c}
                  className="flex items-center justify-center rounded-xl border border-border bg-card px-3 py-5 text-center text-sm font-medium text-foreground/75 transition-colors duration-300 hover:border-border-strong hover:text-foreground"
                >
                  {c}
                </div>
              ))}
            </div>
            <p className="mt-4 text-center text-xs text-muted sm:text-right">
              …and most other RTSP / ONVIF cameras
            </p>
          </Reveal>
        </div>
      </section>

      {/* ===================== FINAL CTA ===================== */}
      <section className="px-5 py-24 sm:px-6 sm:py-32">
        <Reveal className="mx-auto max-w-4xl">
          <div className="relative overflow-hidden rounded-3xl border border-border bg-card px-6 py-16 text-center sm:py-20">
            {/* The second and last appearance of the brand gradient */}
            <div
              aria-hidden
              className="absolute inset-x-0 top-0 h-px opacity-80"
              style={{ backgroundImage: "var(--hero-gradient)" }}
            />
            <div
              aria-hidden
              className="absolute inset-0 opacity-[0.3]"
              style={{
                backgroundImage:
                  "radial-gradient(ellipse 65% 60% at 50% 0%, #7c5cf6, transparent 70%), radial-gradient(ellipse 40% 35% at 80% 100%, rgba(255,158,100,0.35), transparent 70%)",
              }}
            />
            <div className="relative">
              <Image
                src="/icon.png"
                alt="LemurCam"
                width={64}
                height={64}
                className="mx-auto rounded-2xl shadow-lg"
              />
              <h2 className="mt-7 text-3xl font-semibold tracking-[-0.02em] text-white sm:text-4xl">
                Ready to ditch the cable?
              </h2>
              <p className="mx-auto mt-3 max-w-md text-base leading-relaxed text-white/70">
                Download LemurCam, point it at your camera, and pick it in your
                next call. Free and open source.
              </p>
              <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
                <a
                  href={DOWNLOAD_URL}
                  className="group inline-flex items-center gap-2 rounded-full bg-white px-6 py-3 text-[15px] font-medium text-background shadow-[0_8px_32px_-8px_rgba(167,139,250,0.4)] transition-transform duration-200 active:scale-[0.98]"
                >
                  <DownloadIcon className="h-[18px] w-[18px] transition-transform duration-200 group-hover:translate-y-0.5" />
                  Download for macOS
                </a>
                <a
                  href={GITHUB_URL}
                  target="_blank"
                  rel="noreferrer"
                  className="inline-flex items-center gap-2 rounded-full border border-white/25 px-6 py-3 text-[15px] font-medium text-white transition-colors hover:bg-white/10"
                >
                  <GithubIcon className="h-[18px] w-[18px]" />
                  Star on GitHub
                </a>
              </div>
              <p className="mt-6 inline-flex items-center gap-1.5 font-mono text-[11px] uppercase tracking-[0.14em] text-white/50">
                <ShieldIcon className="h-4 w-4" />
                Requires macOS 14 Sonoma or later
              </p>
            </div>
          </div>
        </Reveal>
      </section>

      {/* ===================== FOOTER ===================== */}
      <footer className="border-t border-border px-5 py-10 sm:px-6">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-5 sm:flex-row">
          <div className="flex items-center gap-2.5">
            <Image
              src="/icon.png"
              alt="LemurCam"
              width={28}
              height={28}
              className="rounded-lg"
            />
            <span className="font-semibold tracking-tight">LemurCam</span>
            <span className="text-sm text-muted">· lemur.cam</span>
          </div>
          <div className="flex flex-wrap items-center justify-center gap-x-6 gap-y-2 text-sm text-muted">
            <a
              href={DOWNLOAD_URL}
              className="transition-colors hover:text-foreground"
            >
              Download
            </a>
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noreferrer"
              className="transition-colors hover:text-foreground"
            >
              GitHub
            </a>
            <a
              href={CHANGELOG_URL}
              target="_blank"
              rel="noreferrer"
              className="transition-colors hover:text-foreground"
            >
              Changelog
            </a>
            <a
              href={LICENSE_URL}
              target="_blank"
              rel="noreferrer"
              className="transition-colors hover:text-foreground"
            >
              MIT License
            </a>
          </div>
        </div>
        <p className="mx-auto mt-6 max-w-6xl text-center text-xs text-muted sm:text-left">
          Made with care by{" "}
          <a
            href={AUTHOR_URL}
            target="_blank"
            rel="noreferrer"
            className="font-medium text-foreground/70 underline-offset-2 transition-colors hover:text-foreground hover:underline"
          >
            Anees Iqbal
          </a>
          . LemurCam is free and open source.
        </p>
      </footer>
    </div>
  );
}
