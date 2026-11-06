"use client";

import { createContext, useContext, useEffect, useMemo, useRef, type ReactNode } from "react";

/* In the app, some buttons open another LemurCam window: the popover's
   Settings button, Set Up LemurCam and Open Setup, Settings' Open Guided
   Setup…, and the setup window's Add Camera (which opens Settings on the
   Cameras pane). On this page they scroll to that window's recreation instead,
   and the recreation reacts as the window would. */

export type SettingsPane = "status" | "cameras" | "preview" | "general" | "logs";

type Handlers = {
  settings: ((pane?: SettingsPane) => void) | null;
  setup: (() => void) | null;
};

type BridgeValue = {
  openSettings: (pane?: SettingsPane) => void;
  openSetup: () => void;
  register: <K extends keyof Handlers>(kind: K, handler: Handlers[K]) => void;
};

const BridgeContext = createContext<BridgeValue | null>(null);

function reveal(id: string) {
  const node = document.getElementById(id);
  if (!node) return;
  const smooth = !window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  node.scrollIntoView({ behavior: smooth ? "smooth" : "auto", block: "center" });
  // Move keyboard focus to the window so the next Tab continues inside it.
  node.focus({ preventScroll: true });
}

export function BridgeProvider({ children }: { children: ReactNode }) {
  const handlers = useRef<Handlers>({ settings: null, setup: null });

  const value = useMemo<BridgeValue>(
    () => ({
      register(kind, handler) {
        handlers.current[kind] = handler;
      },
      openSettings(pane) {
        handlers.current.settings?.(pane);
        requestAnimationFrame(() => reveal("settings-window"));
      },
      openSetup() {
        handlers.current.setup?.();
        requestAnimationFrame(() => reveal("setup-window"));
      },
    }),
    []
  );

  return <BridgeContext.Provider value={value}>{children}</BridgeContext.Provider>;
}

export function useBridge() {
  const value = useContext(BridgeContext);
  if (!value) throw new Error("useBridge outside BridgeProvider");
  return value;
}

/** Registers what a window recreation does when another one opens it. */
export function useWindowHandler<K extends keyof Handlers>(kind: K, handler: NonNullable<Handlers[K]>) {
  const { register } = useBridge();
  useEffect(() => {
    register(kind, handler);
  });
  useEffect(() => () => register(kind, null), [register, kind]);
}
