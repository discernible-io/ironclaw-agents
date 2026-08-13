// @ts-nocheck
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "vitest";
import vm from "node:vm";

import { messageBelongsToActiveRun } from "../lib/message-types";

function activityRunSourceForTest() {
  const source = readFileSync(new URL("./activity-run.tsx", import.meta.url), "utf8");
  const lines = [];
  let skippingImport = false;
  for (const line of source.split("\n")) {
    if (!skippingImport && line.startsWith("import ")) {
      skippingImport = !line.trimEnd().endsWith(";");
      continue;
    }
    if (skippingImport) {
      skippingImport = !line.trimEnd().endsWith(";");
      continue;
    }
    lines.push(line.replace("export function ActivityRun", "function ActivityRun"));
  }
  return `${lines.join("\n")}\nglobalThis.__testExports = { ActivityRun };`;
}

function renderActivityRun(activity, activeRunId = null, summary = {
  label: "Activity - 1 tool, running",
  hasError: false,
}) {
  const context = {
    globalThis: {},
    html: (strings, ...values) => ({ strings: Array.from(strings), values }),
    Icon() {},
    MarkdownRenderer() {},
    React: {
      useEffect: () => {},
      useMemo: (factory) => factory(),
      useState: (initial) => [typeof initial === "function" ? initial() : initial, () => {}],
    },
    messageBelongsToActiveRun,
    summarizeActivity: () => summary,
    useT: () => (key) => key,
    ToolActivity() {},
  };

  vm.runInNewContext(activityRunSourceForTest(), context);
  return context.globalThis.__testExports.ActivityRun({
    activity,
    activeRunId,
  });
}

test("ActivityRun keeps running tool activity collapsed by default", () => {
  const tree = renderActivityRun([
    {
      id: "tool-search",
      role: "tool_activity",
      toolName: "web-access.search",
      toolStatus: "running",
    },
  ]);

  assert.ok(containsScalar(tree, "false"));
  assert.equal(hasComponentNamed(tree, "ActivityItem"), false);
});

test("ActivityRun keeps declined tool activity collapsed", () => {
  const tree = renderActivityRun(
    [
      {
        id: "tool-install",
        role: "tool_activity",
        toolName: "extension_install",
        toolStatus: "declined",
      },
    ],
    null,
    {
      label: "Activity - 1 tool, 1 declined",
      hasError: false,
      hasDeclined: true,
    },
  );

  assert.ok(containsScalar(tree, "false"));
  assert.equal(hasComponentNamed(tree, "ActivityItem"), false);
});

test("ActivityRun keeps failed nested tool activity collapsed", () => {
  const tree = renderActivityRun(
    [
      {
        id: "assistant-tool-call",
        role: "assistant",
        toolCalls: [
          {
            id: "tool-search",
            toolName: "web-access.search",
            toolStatus: "error",
          },
        ],
      },
    ],
    null,
    {
      label: "Activity - 1 tool, 1 failed",
      hasError: true,
    },
  );

  assert.ok(containsScalar(tree, "false"));
  assert.equal(hasComponentNamed(tree, "ActivityItem"), false);
});

test("ActivityRun keeps reasoning activity collapsed", () => {
  const tree = renderActivityRun(
    [
      {
        id: "reasoning",
        role: "thinking",
        content: "Considering the available evidence.",
      },
    ],
    null,
    {
      label: "Activity",
      hasError: false,
    },
  );

  assert.ok(containsScalar(tree, "false"));
  assert.equal(hasComponentNamed(tree, "ActivityItem"), false);
});

test("ActivityRun expands live activity for the active run", () => {
  const tree = renderActivityRun(
    [
      {
        id: "tool-search",
        role: "tool_activity",
        toolName: "web-access.search",
        toolStatus: "running",
        turnRunId: "run-1",
      },
    ],
    "run-1",
  );

  assert.ok(containsScalar(tree, "true"));
  assert.equal(hasComponentNamed(tree, "ActivityItem"), true);
});

function hasComponentNamed(node, name) {
  if (!node || typeof node !== "object" || !Array.isArray(node.values)) return false;
  if (node.values.some((value) => typeof value === "function" && value.name === name)) {
    return true;
  }
  return node.values.some((value) => {
    if (Array.isArray(value)) return value.some((item) => hasComponentNamed(item, name));
    return hasComponentNamed(value, name);
  });
}

function containsScalar(node, expected) {
  if (node === expected) return true;
  if (Array.isArray(node)) return node.some((item) => containsScalar(item, expected));
  if (!node || typeof node !== "object" || !Array.isArray(node.values)) return false;
  return node.values.some((value) => containsScalar(value, expected));
}
