// @ts-nocheck
import assert from "node:assert/strict";
import { test } from "vitest";
import vm from "node:vm";
import {
  componentProps,
  componentSourceForTest,
  findComponent,
} from "../../../lib/vm-component-harness";

function typingIndicatorSourceForTest() {
  return componentSourceForTest(
    new URL("./typing-indicator.tsx", import.meta.url),
    "TypingIndicator",
  );
}

function renderTypingIndicator(props = {}, { nowMs = 1_700_000_000_000 } = {}) {
  const components = {
    NearProcessIndicator() {},
  };
  const context = {
    ...components,
    Date: { now: () => nowMs },
    React: {
      useState: (initial) => [
        typeof initial === "function" ? initial() : initial,
        () => {},
      ],
      useEffect: () => {},
    },
    useT: () => (key, params) =>
      params ? `${key}:${JSON.stringify(params)}` : key,
    globalThis: {},
    window: {
      setInterval: () => 1,
      clearInterval: () => {},
    },
  };

  vm.runInNewContext(typingIndicatorSourceForTest(), context);
  const tree = context.globalThis.__testExports.TypingIndicator(props);
  return {
    props: componentProps(
      findComponent(tree, components.NearProcessIndicator),
      components.NearProcessIndicator,
    ),
  };
}

test("TypingIndicator keeps the brief action label beside the working indicator", () => {
  assert.deepEqual(renderTypingIndicator().props, {
    state: "working",
    label: "chat.processWorking",
    elapsed: undefined,
  });
});

test("TypingIndicator shows the live action and elapsed time while working", () => {
  assert.deepEqual(
    renderTypingIndicator({
      label: "Searching · slack",
      startedAtMs: 1_700_000_000_000 - 12_000,
    }).props,
    {
      state: "working",
      label: "Searching · slack",
      elapsed: "0:12",
    },
  );
});

test("TypingIndicator keeps the static mark with elapsed time after completion", () => {
  assert.deepEqual(
    renderTypingIndicator({
      state: "done",
      durationSeconds: 12,
    }).props,
    {
      state: "done",
      label: 'chat.workedFor:{"duration":"12s"}',
      elapsed: undefined,
    },
  );
});

test.each([
  [60, "Worked for 00:01:00"],
  [3_661, "Worked for 01:01:01"],
])(
  "TypingIndicator formats completed runs of %i seconds as HH:MM:SS",
  (durationSeconds, label) => {
    assert.deepEqual(
      renderTypingIndicator({
        state: "done",
        durationSeconds,
      }).props,
      {
        state: "done",
        label: `chat.workedFor:${JSON.stringify({ duration: label.replace("Worked for ", "") })}`,
        elapsed: undefined,
      },
    );
  },
);
