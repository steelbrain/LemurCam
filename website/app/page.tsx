import Image from "next/image";
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
  SparkleIcon,
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
    img: "/shots/setup-camera.png",
    alt: "LemurCam guided setup showing the virtual camera ready",
    w: 1184,
    h: 1288,
  },
  {
    n: "02",
    title: "Add your camera",
    body: "Discover cameras on your network or paste an RTSP URL. LemurCam connects, decodes, and shows a live preview.",
    img: "/shots/cameras.png",
    alt: "LemurCam camera list with a connected RTSP camera",
    w: 1664,
    h: 1352,
  },
  {
    n: "03",
    title: "Pick it anywhere",
    body: "In any app's camera menu, choose LemurCam. You're live — with the lens you actually wanted to use.",
    img: "/shots/general.png",
    alt: "LemurCam general settings and about screen",
    w: 1664,
    h: 1352,
  },
];

const CAMERAS = [
  "TP-Link Tapo",
  "Reolink",
  "Hikvision",
  "Dahua",
  "Amcrest",
  "UniFi Protect",
];

const GALLERY = [
  {
    img: "/shots/add-camera.png",
    alt: "LemurCam guided setup step for adding an IP camera",
    label: "Add a camera",
  },
  {
    img: "/shots/mic-ready.png",
    alt: "LemurCam virtual microphone ready and available to other apps",
    label: "Optional microphone",
  },
  {
    img: "/shots/status.png",
    alt: "Setup and status overview with device cards",
    label: "At-a-glance status",
  },
];

export default function Home() {
  return (
    <div id="top" className="font-[family-name:var(--font-geist-sans)]">
      <Nav />

      {/* ===================== HERO ===================== */}
      <section className="relative overflow-hidden px-5 pt-32 pb-20 sm:px-6 sm:pt-40 sm:pb-28">
        {/* Aurora background */}
        <div
          aria-hidden
          className="pointer-events-none absolute inset-0 -z-10 overflow-hidden"
        >
          <div className="animate-drift-a absolute -top-24 left-[8%] h-[34rem] w-[34rem] rounded-full bg-violet/30 blur-[110px]" />
          <div className="animate-drift-b absolute top-10 right-[2%] h-[30rem] w-[30rem] rounded-full bg-pink/25 blur-[120px]" />
          <div className="animate-drift-c absolute -bottom-32 left-[30%] h-[32rem] w-[32rem] rounded-full bg-blue/25 blur-[120px]" />
          <div className="absolute inset-0 bg-[radial-gradient(ellipse_at_top,transparent_40%,var(--background)_92%)]" />
        </div>

        <div className="mx-auto max-w-3xl text-center">
          <Reveal>
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noreferrer"
              className="ring-gradient group inline-flex items-center gap-2 rounded-full border border-border bg-card/70 px-3.5 py-1.5 text-xs font-medium text-muted shadow-sm backdrop-blur transition-colors hover:text-foreground"
            >
              <SparkleIcon className="h-3.5 w-3.5 text-violet" />
              Free &amp; open source · macOS 14+
              <ArrowIcon className="h-3.5 w-3.5 transition-transform group-hover:translate-x-0.5" />
            </a>
          </Reveal>

          <Reveal delay={80}>
            <h1 className="mt-7 text-[2.6rem] font-bold leading-[1.04] tracking-tight sm:text-6xl">
              Ditch the cable.
              <br />
              <span className="text-gradient">Keep the camera.</span>
            </h1>
          </Reveal>

          <Reveal delay={160}>
            <p className="mx-auto mt-6 max-w-xl text-lg leading-relaxed text-muted">
              LemurCam turns any RTSP or ONVIF IP camera into a virtual webcam
              and microphone on macOS — so you show up on every call with the
              lens you actually want.
            </p>
          </Reveal>

          <Reveal delay={240}>
            <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
              <a
                href={DOWNLOAD_URL}
                className="btn-shine inline-flex items-center gap-2 rounded-full bg-foreground px-6 py-3.5 text-base font-semibold text-background shadow-lg shadow-foreground/15 transition-transform duration-200 hover:scale-[1.03] active:scale-95"
              >
                <DownloadIcon className="h-5 w-5" />
                Download for macOS
              </a>
              <a
                href={GITHUB_URL}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-2 rounded-full border border-border bg-card px-6 py-3.5 text-base font-semibold transition-colors hover:bg-foreground/[0.04]"
              >
                <GithubIcon className="h-5 w-5" />
                View source
              </a>
            </div>
          </Reveal>

          <Reveal delay={300}>
            <p className="mt-4 text-xs text-muted">
              Universal · Apple Silicon &amp; Intel · Signed &amp; notarized
            </p>
          </Reveal>
        </div>

        {/* Hero visual */}
        <Reveal delay={360} className="mx-auto mt-16 max-w-4xl sm:mt-20">
          <Tilt className="relative">
            <div
              aria-hidden
              className="absolute -inset-6 -z-10 rounded-[2rem] brand-gradient opacity-30 blur-3xl"
            />
            <div className="animate-float">
              <Image
                src="/shots/preview.png"
                alt="LemurCam live preview showing a connected camera feed with resolution and frame-rate stats"
                width={1664}
                height={1352}
                priority
                className="h-auto w-full drop-shadow-2xl"
              />
            </div>
          </Tilt>
        </Reveal>
      </section>

      {/* ===================== WORKS WITH (marquee) ===================== */}
      <section className="border-y border-border/70 bg-card/50 py-9">
        <p className="mb-6 text-center text-xs font-semibold uppercase tracking-[0.18em] text-muted">
          Shows up everywhere you already are
        </p>
        <div className="group relative overflow-hidden [mask-image:linear-gradient(90deg,transparent,#000_12%,#000_88%,transparent)]">
          <div className="animate-marquee flex w-max gap-3 group-hover:[animation-play-state:paused]">
            {[...WORKS_WITH, ...WORKS_WITH].map((name, i) => (
              <span
                key={`${name}-${i}`}
                className="flex items-center gap-2 whitespace-nowrap rounded-full border border-border bg-background px-4 py-2 text-sm font-medium text-foreground/80"
              >
                <CameraIcon className="h-4 w-4 text-violet/80" />
                {name}
              </span>
            ))}
          </div>
        </div>
      </section>

      {/* ===================== FEATURES (bento) ===================== */}
      <section id="features" className="mx-auto max-w-6xl px-5 py-24 sm:px-6 sm:py-32">
        <Reveal className="mx-auto max-w-2xl text-center">
          <p className="text-sm font-semibold text-violet">Everything in the box</p>
          <h2 className="mt-3 text-3xl font-bold tracking-tight sm:text-4xl">
            Small menu-bar app. Big camera energy.
          </h2>
          <p className="mt-4 text-lg text-muted">
            LemurCam lives quietly in your menu bar and does one thing
            beautifully: makes your IP camera feel like it was built into your
            Mac.
          </p>
        </Reveal>

        <div className="mt-14 grid gap-4 md:grid-cols-6">
          {FEATURES.map((f, i) => {
            const Icon = f.icon;
            const span =
              i < 2 ? "md:col-span-3" : "md:col-span-2";
            return (
              <Reveal
                key={f.title}
                delay={(i % 3) * 70}
                className={span}
              >
                <article className="ring-gradient group relative flex h-full flex-col rounded-3xl border border-border bg-card p-6 shadow-[0_1px_0_rgba(0,0,0,0.02)] transition-all duration-300 hover:-translate-y-1 hover:shadow-xl hover:shadow-violet/5">
                  <div className="mb-4 inline-flex h-11 w-11 items-center justify-center rounded-xl brand-gradient text-white shadow-md shadow-violet/20 transition-transform duration-300 group-hover:scale-110 group-hover:-rotate-3">
                    <Icon className="h-5.5 w-5.5" />
                  </div>
                  <h3 className="text-lg font-semibold tracking-tight">
                    {f.title}
                  </h3>
                  <p className="mt-2 text-[15px] leading-relaxed text-muted">
                    {f.body}
                  </p>

                  {/* Joyful flourish on the audio card */}
                  {f.icon === MicIcon && (
                    <div className="mt-5 flex h-10 items-end gap-1">
                      {[0.4, 0.7, 0.3, 0.9, 0.55, 0.8, 0.35, 0.65, 0.45, 0.85, 0.4].map(
                        (s, j) => (
                          <span
                            key={j}
                            className="eq-bar w-1.5 flex-1 rounded-full brand-gradient"
                            style={{
                              height: `${s * 100}%`,
                              animationDelay: `${j * 0.11}s`,
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
        className="relative overflow-hidden border-y border-border/70 bg-card/40 px-5 py-24 sm:px-6 sm:py-32"
      >
        <div
          aria-hidden
          className="animate-drift-b pointer-events-none absolute right-[-10%] top-1/4 -z-10 h-[28rem] w-[28rem] rounded-full bg-blue/15 blur-[120px]"
        />
        <Reveal className="mx-auto max-w-2xl text-center">
          <p className="text-sm font-semibold text-violet">Up in three steps</p>
          <h2 className="mt-3 text-3xl font-bold tracking-tight sm:text-4xl">
            From IP camera to webcam in minutes
          </h2>
        </Reveal>

        <div className="mx-auto mt-16 max-w-5xl space-y-20">
          {STEPS.map((step, i) => (
            <Reveal key={step.n}>
              <div
                className={`flex flex-col items-center gap-10 lg:gap-16 ${
                  i % 2 === 1 ? "lg:flex-row-reverse" : "lg:flex-row"
                }`}
              >
                <div className="flex-1 lg:max-w-md">
                  <span className="inline-flex items-center justify-center rounded-2xl brand-gradient bg-clip-text font-mono text-5xl font-bold tracking-tight text-transparent">
                    {step.n}
                  </span>
                  <h3 className="mt-3 text-2xl font-semibold tracking-tight">
                    {step.title}
                  </h3>
                  <p className="mt-3 text-lg leading-relaxed text-muted">
                    {step.body}
                  </p>
                </div>
                <div className="relative flex-1">
                  <div
                    aria-hidden
                    className="absolute -inset-4 -z-10 rounded-[2rem] brand-gradient opacity-15 blur-2xl"
                  />
                  <Image
                    src={step.img}
                    alt={step.alt}
                    width={step.w}
                    height={step.h}
                    className="mx-auto h-auto w-full max-w-md drop-shadow-2xl"
                  />
                </div>
              </div>
            </Reveal>
          ))}
        </div>
      </section>

      {/* ===================== GALLERY ===================== */}
      <section className="mx-auto max-w-6xl px-5 py-24 sm:px-6 sm:py-32">
        <Reveal className="mx-auto max-w-2xl text-center">
          <p className="text-sm font-semibold text-violet">A closer look</p>
          <h2 className="mt-3 text-3xl font-bold tracking-tight sm:text-4xl">
            Thoughtful, native, out of the way
          </h2>
          <p className="mt-4 text-lg text-muted">
            A sidebar for settings, device cards that tell you exactly
            what&apos;s running, and a guided setup that walks you through every
            step.
          </p>
        </Reveal>

        <div className="mt-14 grid gap-5 md:grid-cols-3">
          {GALLERY.map((g, i) => (
            <Reveal key={g.img} delay={i * 90}>
              <figure className="ring-gradient group relative overflow-hidden rounded-3xl border border-border bg-gradient-to-b from-card to-background p-5 shadow-sm transition-all duration-300 hover:-translate-y-1 hover:shadow-xl">
                <div
                  aria-hidden
                  className="absolute inset-x-8 top-6 -z-10 h-24 rounded-full brand-gradient opacity-20 blur-2xl transition-opacity duration-300 group-hover:opacity-40"
                />
                <div className="relative aspect-[4/3] w-full overflow-hidden rounded-xl">
                  <Image
                    src={g.img}
                    alt={g.alt}
                    fill
                    sizes="(max-width: 768px) 100vw, 33vw"
                    className="object-contain object-center drop-shadow-lg transition-transform duration-500 group-hover:scale-[1.03]"
                  />
                </div>
                <figcaption className="mt-4 text-center text-sm font-medium text-muted">
                  {g.label}
                </figcaption>
              </figure>
            </Reveal>
          ))}
        </div>
      </section>

      {/* ===================== COMPATIBLE CAMERAS ===================== */}
      <section
        id="cameras"
        className="border-y border-border/70 bg-card/40 px-5 py-24 sm:px-6 sm:py-32"
      >
        <div className="mx-auto grid max-w-5xl items-center gap-12 lg:grid-cols-2">
          <Reveal>
            <p className="text-sm font-semibold text-violet">Plays well with</p>
            <h2 className="mt-3 text-3xl font-bold tracking-tight sm:text-4xl">
              Bring the camera you already own
            </h2>
            <p className="mt-4 text-lg leading-relaxed text-muted">
              If it speaks RTSP or ONVIF, LemurCam can stream it. That covers
              most popular IP-camera lines — and microphone pass-through works
              whenever the camera sends common audio formats.
            </p>
            <ul className="mt-6 space-y-2.5">
              {[
                "RTSP URLs and ONVIF auto-discovery",
                "AAC, G.711 and L16 audio pass-through",
                "Credentials stored safely in your Keychain",
              ].map((item) => (
                <li key={item} className="flex items-start gap-2.5">
                  <CheckIcon className="mt-0.5 h-5 w-5 shrink-0 text-violet" />
                  <span className="text-[15px] text-foreground/80">{item}</span>
                </li>
              ))}
            </ul>
          </Reveal>

          <Reveal delay={120}>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
              {CAMERAS.map((c) => (
                <div
                  key={c}
                  className="ring-gradient flex aspect-square flex-col items-center justify-center gap-2 rounded-2xl border border-border bg-card p-4 text-center shadow-sm transition-transform duration-300 hover:-translate-y-1"
                >
                  <CameraIcon className="h-6 w-6 text-violet/80" />
                  <span className="text-sm font-medium leading-tight">{c}</span>
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
          <div className="relative overflow-hidden rounded-[2.5rem] border border-border brand-gradient px-6 py-16 text-center shadow-2xl shadow-violet/20 sm:py-20">
            <div
              aria-hidden
              className="absolute inset-0 bg-[radial-gradient(ellipse_at_top,rgba(255,255,255,0.35),transparent_60%)]"
            />
            <div className="relative">
              <Image
                src="/icon.png"
                alt="LemurCam"
                width={72}
                height={72}
                className="mx-auto animate-float rounded-2xl shadow-xl"
              />
              <h2 className="mt-6 text-3xl font-bold tracking-tight text-white sm:text-4xl">
                Ready to ditch the cable?
              </h2>
              <p className="mx-auto mt-3 max-w-md text-base text-white/85">
                Download LemurCam, point it at your camera, and pick it in your
                next call. Free and open source.
              </p>
              <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
                <a
                  href={DOWNLOAD_URL}
                  className="btn-shine inline-flex items-center gap-2 rounded-full bg-white px-6 py-3.5 text-base font-semibold text-foreground shadow-lg transition-transform duration-200 hover:scale-[1.03] active:scale-95"
                >
                  <DownloadIcon className="h-5 w-5" />
                  Download for macOS
                </a>
                <a
                  href={GITHUB_URL}
                  target="_blank"
                  rel="noreferrer"
                  className="inline-flex items-center gap-2 rounded-full border border-white/40 px-6 py-3.5 text-base font-semibold text-white transition-colors hover:bg-white/10"
                >
                  <GithubIcon className="h-5 w-5" />
                  Star on GitHub
                </a>
              </div>
              <p className="mt-5 inline-flex items-center gap-1.5 text-xs text-white/75">
                <ShieldIcon className="h-4 w-4" />
                Requires macOS 14 Sonoma or later
              </p>
            </div>
          </div>
        </Reveal>
      </section>

      {/* ===================== FOOTER ===================== */}
      <footer className="border-t border-border/70 px-5 py-10 sm:px-6">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-5 sm:flex-row">
          <div className="flex items-center gap-2.5">
            <Image
              src="/icon.png"
              alt="LemurCam"
              width={30}
              height={30}
              className="rounded-lg"
            />
            <span className="font-semibold">LemurCam</span>
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
