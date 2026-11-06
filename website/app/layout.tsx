import type { Metadata, Viewport } from "next";
import "./globals.css";

const title = "LemurCam — Turn your IP camera into a Mac webcam";

const description =
  "LemurCam turns an RTSP or ONVIF IP camera that streams H.264 or H.265 into a virtual webcam and microphone on macOS. Pick it as the camera in Zoom, Google Meet, FaceTime, OBS or any app where you choose a webcam.";

export const metadata: Metadata = {
  metadataBase: new URL("https://lemur.cam"),
  title: {
    default: title,
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
    title,
    description,
    url: "https://lemur.cam",
    siteName: "LemurCam",
    type: "website",
    images: [{ url: "/icon.png", width: 178, height: 183, alt: "LemurCam" }],
  },
  twitter: {
    card: "summary",
    title,
    description,
    images: ["/icon.png"],
  },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#161618" },
  ],
  colorScheme: "light dark",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
