/* Sample cameras shared by the recreations. Names, addresses and stream
   details are made up; the formats are ones the app handles (H.264 or H.265
   video, AAC or G.711 audio). */

export type Source = {
  id: string;
  name: string;
  kind: "rtsp" | "onvif";
  /** SourceListView subtitle: the RTSP URL, or "host:port" for ONVIF. */
  subtitle: string;
  width: number;
  height: number;
  codec: "h264" | "h265";
  /** `String(describing: audio.codec) @sampleRate` as RTSPStreamPipeline logs it. */
  audio: string;
  /** PreviewStore.estimatedFPS once frames arrive. */
  fps: number;
};

export const SOURCES: Source[] = [
  {
    id: "backyard",
    name: "Backyard Cam",
    kind: "rtsp",
    subtitle: "rtsp://192.168.1.115:554/stream1",
    width: 1920,
    height: 1080,
    codec: "h264",
    audio: "aac @16000Hz",
    fps: 30,
  },
  {
    id: "front",
    name: "Front Door",
    kind: "onvif",
    subtitle: "192.168.1.82:80",
    width: 2560,
    height: 1440,
    codec: "h265",
    audio: "pcmu @8000Hz",
    fps: 25,
  },
];

// RTSPStreamPipeline.publishStreamInfo
export const CODEC_NAME = { h264: "H.264", h265: "H.265" } as const;

// ConnectionStatusHelpers.swift (the states these recreations reach)
export type ConnectionStatus = "connecting" | "connected" | "disconnected";

export const STATUS_LABEL: Record<ConnectionStatus, string> = {
  connecting: "Connecting",
  connected: "Connected",
  disconnected: "Disconnected",
};

export const STATUS_COLOR: Record<ConnectionStatus, string> = {
  connecting: "var(--mac-orange)",
  connected: "var(--mac-green)",
  disconnected: "var(--mac-red)",
};

/** How long a sample camera takes to connect: an ONVIF camera first
    re-discovers its stream URI. Short stand-ins for real network time. */
export function connectDelay(source: Source) {
  return source.kind === "onvif" ? 1200 : 700;
}
