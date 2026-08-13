import { interpolateParams } from "../../../lib/i18n-format";
import { toolDisplayName } from "./history-messages";

const FALLBACK_TRANSLATIONS = {
  "chat.statusWorkingBusy": "Working…",
  "chat.statusThinking": "Thinking…",
  "chat.statusWriting": "Writing…",
  "chat.statusSearching": "Searching…",
  "chat.statusReading": "Reading…",
  "chat.statusRunningCommand": "Running command…",
  "chat.statusUsingTool": "Using {name}…",
};

const DETAIL_MAX_CHARS = 48;

export type LiveWorkingStatus = {
  label: string;
  startedAtMs: number | null;
};

function fallbackT(key, params = {}) {
  const text = FALLBACK_TRANSLATIONS[key] || key;
  return interpolateParams(text, params);
}

function translate(t, key, params = {}) {
  const text = t(key, params);
  if (!text || text === key) return fallbackT(key, params);
  return text;
}

export function classifyToolKind(toolName) {
  const name = String(toolName || "").toLowerCase();
  if (/(grep|search|find|lookup|query)/.test(name)) return "searching";
  if (/(bash|shell|exec|run|command|terminal|spawn|process)/.test(name)) {
    return "command";
  }
  if (
    /(read|file|content|cat|view|open|glob|list|ls|tree|fetch|get|inspect|diff)/
      .test(name)
  ) {
    return "reading";
  }
  return "tool";
}

export function liveWorkingStatus(
  messages,
  activeRunId = null,
  t = fallbackT,
): LiveWorkingStatus {
  const scoped = messagesForRun(messages, activeRunId);
  return {
    label: liveActionLabel(scoped, t),
    startedAtMs: startedAtMsForRun(scoped),
  };
}

function messagesForRun(messages, activeRunId) {
  if (!Array.isArray(messages) || messages.length === 0) return [];
  if (typeof activeRunId !== "string" || !activeRunId) return messages;
  const scoped = messages.filter((message) => {
    const runId = message?.turnRunId;
    return !runId || runId === activeRunId;
  });
  return scoped.length > 0 ? scoped : messages;
}

function liveActionLabel(messages, t) {
  let sawActivity = false;

  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    const runningTool = runningToolFromMessage(message);
    if (runningTool) {
      return formatActionLabel(
        toolActionLabel(runningTool, t),
        runningTool.toolDetail,
      );
    }
    if (isThinking(message)) {
      return translate(t, "chat.statusThinking");
    }
    if (isStreamingAssistantText(message)) {
      return translate(t, "chat.statusWriting");
    }
    if (isActivityMessage(message)) sawActivity = true;
  }

  return translate(t, sawActivity ? "chat.statusThinking" : "chat.statusWorkingBusy");
}

function runningToolFromMessage(message) {
  if (message?.role === "tool_activity" && message.toolStatus === "running") {
    return message;
  }
  if (!Array.isArray(message?.toolCalls)) return null;
  for (let index = message.toolCalls.length - 1; index >= 0; index -= 1) {
    const tool = message.toolCalls[index];
    if (tool?.toolStatus === "running") return tool;
  }
  return null;
}

function toolActionLabel(tool, t) {
  const kind = classifyToolKind(tool?.toolName);
  if (kind === "searching") return translate(t, "chat.statusSearching");
  if (kind === "reading") return translate(t, "chat.statusReading");
  if (kind === "command") return translate(t, "chat.statusRunningCommand");
  const name = toolDisplayName(tool?.toolName) || "tool";
  return translate(t, "chat.statusUsingTool", { name });
}

function formatActionLabel(action, detail) {
  const trimmed = truncateDetail(detail);
  if (!trimmed) return action;
  const stem = String(action).replace(/[.…]+$/u, "").trimEnd();
  return `${stem} · ${trimmed}`;
}

function truncateDetail(value) {
  const text = String(value || "").replace(/\s+/g, " ").trim();
  if (!text) return "";
  if (text.length <= DETAIL_MAX_CHARS) return text;
  return `${text.slice(0, DETAIL_MAX_CHARS - 1)}…`;
}

function isThinking(message) {
  return message?.role === "thinking";
}

function isStreamingAssistantText(message) {
  return (
    message?.role === "assistant" &&
    message?.isFinalReply === false &&
    typeof message?.content === "string" &&
    message.content.trim().length > 0 &&
    !Array.isArray(message?.toolCalls)
  );
}

function isActivityMessage(message) {
  return (
    isThinking(message) ||
    message?.role === "tool_activity" ||
    (Array.isArray(message?.toolCalls) && message.toolCalls.length > 0)
  );
}

function startedAtMsForRun(messages) {
  let earliestUser = null;
  let earliestAny = null;
  for (const message of messages) {
    const ms = timestampMs(message?.timestamp || message?.updatedAt);
    if (ms === null) continue;
    if (earliestAny === null || ms < earliestAny) earliestAny = ms;
    if (message?.role === "user" && (earliestUser === null || ms < earliestUser)) {
      earliestUser = ms;
    }
  }
  return earliestUser ?? earliestAny;
}

function timestampMs(value) {
  if (!value) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}
