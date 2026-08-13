import React from "react";
import { NearProcessIndicator } from "./near-process-indicator";

type TypingIndicatorProps =
  | {
      state?: "working";
      durationSeconds?: never;
      label?: string;
      startedAtMs?: number | null;
    }
  | {
      state: "done";
      durationSeconds: number;
      label?: never;
      startedAtMs?: never;
    };

function formatDuration(durationSeconds: number): string {
  if (durationSeconds < 60) {
    return `${durationSeconds}s`;
  }

  const hours = Math.floor(durationSeconds / 3_600);
  const minutes = Math.floor((durationSeconds % 3_600) / 60);
  const seconds = durationSeconds % 60;

  return [hours, minutes, seconds]
    .map((part) => String(part).padStart(2, "0"))
    .join(":");
}

function formatLiveElapsed(durationSeconds: number): string {
  const minutes = Math.floor(durationSeconds / 60);
  const seconds = durationSeconds % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

function useElapsedLabel(startedAtMs: number | null | undefined): string | undefined {
  const [nowMs, setNowMs] = React.useState(() => Date.now());
  React.useEffect(() => {
    if (startedAtMs == null) return undefined;
    setNowMs(Date.now());
    const timer = window.setInterval(() => setNowMs(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, [startedAtMs]);
  if (startedAtMs == null) return undefined;
  const seconds = Math.max(0, Math.floor((nowMs - startedAtMs) / 1_000));
  return formatLiveElapsed(seconds);
}

export function TypingIndicator({
  state = "working",
  durationSeconds,
  label,
  startedAtMs,
}: TypingIndicatorProps = {}) {
  const elapsed = useElapsedLabel(state === "working" ? startedAtMs : null);
  return (
    <div className="flex flex-col items-start">
      <div className="flex min-w-0 flex-col gap-2 v2-chat-readable-width">
        <div data-testid="typing-indicator" className="w-fit">
          <NearProcessIndicator
            state={state}
            label={
              state === "done"
                ? `Worked for ${formatDuration(durationSeconds)}`
                : label || "Working…"
            }
            elapsed={elapsed}
          />
        </div>
      </div>
    </div>
  );
}
