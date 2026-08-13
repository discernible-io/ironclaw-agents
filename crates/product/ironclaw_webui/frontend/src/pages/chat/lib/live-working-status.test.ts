import assert from "node:assert/strict";
import { test } from "vitest";

import {
  classifyToolKind,
  liveWorkingStatus,
} from "./live-working-status";

test("classifyToolKind maps common capability names onto a live verb", () => {
  assert.equal(classifyToolKind("web-access.search"), "searching");
  assert.equal(classifyToolKind("bash"), "command");
  assert.equal(classifyToolKind("fs.read"), "reading");
  assert.equal(classifyToolKind("memory_store"), "tool");
});

test("liveWorkingStatus defaults to Working before any activity arrives", () => {
  const status = liveWorkingStatus(
    [{ id: "u1", role: "user", content: "hello", turnRunId: "run-1" }],
    "run-1",
  );
  assert.equal(status.label, "Working…");
  assert.equal(status.startedAtMs, null);
});

test("liveWorkingStatus uses the running tool verb and argument", () => {
  const status = liveWorkingStatus(
    [
      {
        id: "u1",
        role: "user",
        content: "find slack",
        turnRunId: "run-1",
        timestamp: "2026-08-13T12:00:00.000Z",
      },
      {
        id: "t1",
        role: "tool_activity",
        toolName: "web-access.search",
        toolStatus: "running",
        toolDetail: "slack connector",
        turnRunId: "run-1",
      },
    ],
    "run-1",
  );
  assert.equal(status.label, "Searching · slack connector");
  assert.equal(status.startedAtMs, Date.parse("2026-08-13T12:00:00.000Z"));
});

test("liveWorkingStatus prefers the latest running nested tool call", () => {
  const status = liveWorkingStatus(
    [
      {
        id: "g1",
        role: "assistant",
        turnRunId: "run-1",
        toolCalls: [
          { id: "a", toolName: "fs.read", toolStatus: "success" },
          {
            id: "b",
            toolName: "bash",
            toolStatus: "running",
            toolDetail: "ls crates",
          },
        ],
      },
    ],
    "run-1",
  );
  assert.equal(status.label, "Running command · ls crates");
});

test("liveWorkingStatus names an unclassified running tool", () => {
  const status = liveWorkingStatus(
    [
      {
        id: "t1",
        role: "tool_activity",
        toolName: "ironclaw.memory.store",
        toolStatus: "running",
        turnRunId: "run-1",
      },
    ],
    "run-1",
  );
  assert.equal(status.label, "Using store…");
});

test("liveWorkingStatus shows Thinking while reasoning streams", () => {
  const status = liveWorkingStatus(
    [
      {
        id: "r1",
        role: "thinking",
        content: "I should inspect the catalog first.",
        turnRunId: "run-1",
      },
    ],
    "run-1",
  );
  assert.equal(status.label, "Thinking…");
});

test("liveWorkingStatus shows Writing once assistant text is streaming", () => {
  const status = liveWorkingStatus(
    [
      {
        id: "t1",
        role: "tool_activity",
        toolName: "web-access.search",
        toolStatus: "success",
        turnRunId: "run-1",
      },
      {
        id: "a1",
        role: "assistant",
        content: "Here is what I found",
        isFinalReply: false,
        turnRunId: "run-1",
      },
    ],
    "run-1",
  );
  assert.equal(status.label, "Writing…");
});

test("liveWorkingStatus returns to Thinking after a tool completes", () => {
  const status = liveWorkingStatus(
    [
      {
        id: "t1",
        role: "tool_activity",
        toolName: "web-access.search",
        toolStatus: "success",
        turnRunId: "run-1",
      },
    ],
    "run-1",
  );
  assert.equal(status.label, "Thinking…");
});

test("liveWorkingStatus ignores activity from another run", () => {
  const status = liveWorkingStatus(
    [
      {
        id: "old",
        role: "tool_activity",
        toolName: "bash",
        toolStatus: "running",
        turnRunId: "run-old",
      },
      {
        id: "r1",
        role: "thinking",
        content: "planning",
        turnRunId: "run-1",
      },
    ],
    "run-1",
  );
  assert.equal(status.label, "Thinking…");
});

test("liveWorkingStatus truncates long tool detail", () => {
  const status = liveWorkingStatus(
    [
      {
        id: "t1",
        role: "tool_activity",
        toolName: "web-access.search",
        toolStatus: "running",
        toolDetail: "a".repeat(80),
        turnRunId: "run-1",
      },
    ],
    "run-1",
  );
  assert.equal(status.label.startsWith("Searching · "), true);
  assert.equal(status.label.endsWith("…"), true);
  assert.ok(status.label.length <= "Searching · ".length + 48);
});

test("liveWorkingStatus uses the active translator", () => {
  const t = (key) => {
    if (key === "chat.statusSearching") return "Recherche…";
    return key;
  };
  const status = liveWorkingStatus(
    [
      {
        id: "t1",
        role: "tool_activity",
        toolName: "web-access.search",
        toolStatus: "running",
        toolDetail: "slack",
        turnRunId: "run-1",
      },
    ],
    "run-1",
    t,
  );
  assert.equal(status.label, "Recherche · slack");
});
