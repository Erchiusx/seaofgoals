module Agent.SeaOfGoals.Scheduling.Agentic
  ( AgentBackend (..)
  , AgentRunRequest (..)
  , AgentRunResult (..)
  , GoalGraph (..)
  , GoalNode (..)
  , GoalNodeId (..)
  , GoalRunId (..)
  , GoalRunState (..)
  , GoalRunStatus (..)
  , SnapshotId (..)
  )
where

import Agent.SeaOfGoals.LLM (LLMInputItem)
import Agent.SeaOfGoals.Tools (ToolSpec)
import Agent.SeaOfGoals.Workspace.Backend (Mount)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)

newtype GoalNodeId = GoalNodeId
  { unGoalNodeId :: Text
  }
  deriving stock (Eq, Ord, Show)

newtype GoalRunId = GoalRunId
  { unGoalRunId :: Text
  }
  deriving stock (Eq, Ord, Show)

newtype SnapshotId = SnapshotId
  { unSnapshotId :: Text
  }
  deriving stock (Eq, Ord, Show)

data GoalNode = GoalNode
  { goalNodeId :: GoalNodeId
  , goalNodeName :: Text
  , goalNodePrompt :: Text
  , goalNodeSerialIndex :: Int
  }
  deriving stock (Eq, Show)

data GoalGraph = GoalGraph
  { goalGraphNodes :: Map GoalNodeId GoalNode
  , goalGraphEdges :: Set (GoalNodeId, GoalNodeId)
  }
  deriving stock (Eq, Show)

data GoalRunStatus
  = GoalPending
  | GoalRunning GoalRunId
  | GoalCompleted AgentRunResult
  | GoalInvalidated Text
  | GoalFailed Text
  deriving stock (Eq, Show)

data GoalRunState = GoalRunState
  { goalRunStateGoal :: GoalNodeId
  , goalRunStateStatus :: GoalRunStatus
  , goalRunStateBaseSnapshot :: Maybe SnapshotId
  }
  deriving stock (Eq, Show)

data AgentRunRequest = AgentRunRequest
  { agentRunGoal :: GoalNode
  , agentRunPrompt :: [LLMInputItem]
  , agentRunWorkspace :: Mount
  , agentRunTools :: [ToolSpec]
  }

data AgentRunResult = AgentRunResult
  { agentRunResultGoal :: GoalNodeId
  , agentRunResultStatus :: Text
  , agentRunResultSummaryForDependents :: Text
  , agentRunResultReads :: Set FilePath
  , agentRunResultWrites :: Set FilePath
  , agentRunResultSnapshot :: SnapshotId
  }
  deriving stock (Eq, Show)

class AgentBackend backend where
  runAgentTask :: backend -> AgentRunRequest -> IO AgentRunResult
