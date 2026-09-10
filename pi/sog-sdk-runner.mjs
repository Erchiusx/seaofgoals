import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createInterface } from "node:readline";

const piRoot = process.env.SOG_PI_ROOT || "/home/erchius/development/pi";
const { createAgentSession, ModelRuntime, SessionManager } = await import(
  `${piRoot}/packages/coding-agent/dist/index.js`,
);

const endGoalTool = {
  name: "end_goal",
  label: "End Goal",
  description: "Mark the assigned SeaOfGoals goal complete and provide its result.",
  promptSnippet: "Finish the assigned goal with a status and summary",
  parameters: {
    type: "object",
    properties: {
      status: { type: "string", enum: ["success", "failed"] },
      summary: { type: "string" },
    },
    required: ["status", "summary"],
    additionalProperties: false,
  },
  async execute(_toolCallId, params) {
    return {
      content: [{ type: "text", text: `Goal ${params.status}: ${params.summary}` }],
      details: { status: params.status, summary: params.summary },
      terminate: true,
    };
  },
};

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
  const { session } = await createAgentSession({
    cwd,
    agentDir,
    model,
    modelRuntime,
    sessionManager,
    tools: ["read", "bash", "edit", "write", "end_goal"],
    customTools: [endGoalTool],
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
