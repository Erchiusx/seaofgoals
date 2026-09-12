import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createInterface } from "node:readline";

const piRoot = process.env.SOG_PI_ROOT || "/home/erchius/development/pi";
const { createAgentSession, ModelRuntime, SessionManager } = await import(
  `${piRoot}/packages/coding-agent/dist/index.js`,
);

function planTool(name, description, prefix) {
  return {
    name,
    label: name,
    description,
    promptSnippet: description,
    parameters: {
      type: "object",
      properties: { plan_json: { type: "string" } },
      required: ["plan_json"],
      additionalProperties: false,
    },
    async execute(_toolCallId, params) {
      let plan;
      try {
        plan = JSON.parse(params.plan_json);
      } catch {
        return {
          content: [{ type: "text", text: `${name} rejected invalid JSON.` }],
          isError: true,
        };
      }
      return {
        content: [{ type: "text", text: `${prefix}${params.plan_json}` }],
        details: { plan_json: params.plan_json },
      };
    },
  };
}

const setPreloadPlanTool = planTool(
  "set_preload_plan",
  "Publish the per-goal file preload plan to the SeaOfGoals harness.",
  "SOG_PRELOAD_PLAN:",
);
const setPredictedActionsPlanTool = planTool(
  "set_predicted_actions_plan",
  "Publish conservative read-only predicted actions to the SeaOfGoals harness.",
  "SOG_PREDICTED_ACTIONS_PLAN:",
);

function makeEntries(cwd, messages = []) {
  const header = {
    type: "session",
    version: 3,
    id: randomUUID(),
    timestamp: new Date().toISOString(),
    cwd,
  };
  let parentId = null;
  const entries = messages.map((message) => {
    const entry = {
      type: "message",
      id: randomUUID(),
      parentId,
      timestamp: new Date().toISOString(),
      message,
    };
    parentId = entry.id;
    return entry;
  });
  return [header, ...entries];
}

async function run(request) {
  const cwd = request.cwd || process.cwd();
  const agentDir = request.agentDir || `${cwd}/.pi-agent`;
  await mkdir(agentDir, { recursive: true });
  const requestedModel = request.model || process.env.SOG_PI_MODEL || "gpt-5.5";
  const useRise = Boolean(process.env.OPENAI_BASE_URL);
  const [requestedProvider = useRise ? "rise" : "openai", requestedId = requestedModel] = requestedModel.includes("/")
    ? requestedModel.split("/", 2)
    : [useRise ? "rise" : "openai", requestedModel];
  const provider = useRise ? "rise" : requestedProvider;
  const modelId = useRise && requestedProvider === "openai" ? requestedId : requestedId;
  if (useRise) {
    await writeFile(
      `${agentDir}/models.json`,
      JSON.stringify({
        providers: {
          rise: {
            baseUrl: process.env.OPENAI_BASE_URL,
            api: "openai-responses",
            apiKey: "$OPENAI_API_KEY",
            models: [{ id: modelId, reasoning: true }],
          },
        },
      }),
    );
  }
  const modelRuntime = await ModelRuntime.create({ modelsPath: `${agentDir}/models.json` });
  const model = modelRuntime.getModel(provider, modelId);
  if (!model) throw new Error(`Pi model is not available: ${provider}/${modelId}`);
  const sessionManager = SessionManager.inMemory(cwd, undefined, makeEntries(cwd, request.messages));
  const plannerTools = request.goalId === "G000" ? [setPreloadPlanTool, setPredictedActionsPlanTool] : [];
  const { session } = await createAgentSession({
    cwd,
    agentDir,
    model,
    modelRuntime,
    sessionManager,
    tools: ["read", "bash", "edit", "write", "set_preload_plan", "set_predicted_actions_plan"],
    customTools: plannerTools,
  });
  const unsubscribe = session.subscribe((event) => {
    process.stdout.write(`${JSON.stringify(event)}\n`);
  });
  try {
    await session.prompt(request.prompt || "");
  } finally {
    unsubscribe();
    session.dispose();
  }
}

if (process.argv[2]) {
  await run(JSON.parse(await readFile(process.argv[2], "utf8")));
} else {
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of input) {
    if (!line.trim()) continue;
    try {
      await run(JSON.parse(line));
    } catch (error) {
      process.stderr.write(`${error instanceof Error ? error.stack || error.message : String(error)}\n`);
      process.exitCode = 1;
    }
  }
}
