module Agent.SeaOfGoals.Agentic
where
import Agent.SeaOfGoals.LLM (LLMInputItem)

class Goal g
class Goal g => HistoryComposer g hc where
  compose :: hc -> g -> [LLMInputItem]
