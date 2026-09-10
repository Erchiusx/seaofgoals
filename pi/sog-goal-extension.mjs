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

export default function (pi) {
  pi.registerTool(endGoalTool);
}
