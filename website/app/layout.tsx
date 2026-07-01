import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

const description =
  "LemurCam turns any RTSP or ONVIF IP camera into a virtual webcam and microphone on macOS. Works with Zoom, Teams, Google Meet, FaceTime, OBS and more.";

export const metadata: Metadata = {
  metadataBase: new URL("https://lemur.cam"),
  title: {
    default: "LemurCam — Turn any IP camera into a Mac webcam",
    template: "%s · LemurCam",
  },
  description,
  keywords: [
    "virtual webcam",
    "macOS",
    "RTSP",
    "ONVIF",
    "IP camera",
    "virtual camera",
    "Zoom",
    "OBS",
  ],
  authors: [{ name: "Anees Iqbal", url: "https://aneesiqbal.ai" }],
  icons: {
    icon: "/icon.png",
    apple: "/apple-touch-icon.png",
  },
  openGraph: {
    title: "LemurCam — Turn any IP camera into a Mac webcam",
    description,
    url: "https://lemur.cam",
    siteName: "LemurCam",
    type: "website",
    images: [{ url: "/icon.png", width: 178, height: 183, alt: "LemurCam" }],
  },
  twitter: {
    card: "summary",
    title: "LemurCam — Turn any IP camera into a Mac webcam",
    description,
    images: ["/icon.png"],
  },
};

export const viewport = {
  themeColor: "#0e0c16",
  colorScheme: "dark" as const,
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <head>
        {/* Without JS the IntersectionObserver never runs, so reveals would
            stay at opacity:0. Force them visible as a no-JS fallback. */}
        <noscript>
          <style>{`.reveal{opacity:1 !important;transform:none !important}`}</style>
        </noscript>
      </head>
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased`}
      >
        {children}
      </body>
    </html>
  );
}
