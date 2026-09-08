module Agent.SeaOfGoals.Trace
  ( EffectRecord (..)
  , HarnessEvent (..)
  , eventType
  )
where

import Data.Aeson
  ( ToJSON (..)
  , Value
  , object
  , (.=)
  )
import Data.Aeson.Types (Pair)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)

data EffectRecord = EffectRecord
  { effectKind :: Text
  , effectResource :: Text
  , effectDetail :: Maybe Text
  }
  deriving stock (Eq, Show)

instance ToJSON EffectRecord where
  toJSON effect =
    object
      [ "kind" .= effectKind effect
      , "resource" .= effectResource effect
      , "detail" .= effectDetail effect
      ]

data HarnessEvent
  = HarnessStarted
      { eventPrompt :: Text
      }
  | AssistantMessageObserved
      { eventContent :: Text
      }
  | ReasoningObserved
      { eventReasoningId :: Maybe Text
      , eventEncryptedContentChars :: Int
      , eventReasoningSummaryItems :: Int
      }
  | ModelUsageObserved
      { eventInputTokens :: Int
      , eventCachedInputTokens :: Maybe Int
      , eventOutputTokens :: Int
      , eventReasoningOutputTokens :: Maybe Int
      , eventTotalTokens :: Int
      }
  | ToolCallObserved
      { eventCallId :: Text
      , eventToolName :: Text
      , eventArguments :: Value
      , eventActiveSubgoal :: Maybe Text
      }
  | ToolResultObserved
      { eventCallId :: Text
      , eventToolName :: Text
      , eventResult :: Text
      , eventActiveSubgoal :: Maybe Text
      }
  | SubgoalStarted
      { eventSubgoalId :: Text
      , eventSubgoalName :: Text
      }
  | SubgoalEnded
      { eventSubgoalId :: Text
      , eventStatus :: Text
      , eventSummary :: Maybe Text
      }
  | EffectRecorded
      { eventEffect :: EffectRecord
      , eventActiveSubgoal :: Maybe Text
      }
  | WorkflowStatusObserved
      { eventActiveNode :: Maybe Text
      , eventLastNode :: Maybe Text
      , eventCompletedNodes :: Set Text
      , eventFailedNodes :: Set Text
      , eventSkippedNodes :: Set Text
      , eventTransitionWarnings :: [Text]
      }
  | ProcessStarted
      { eventProcessKind :: Text
      , eventGoalId :: Maybe Text
      , eventCommand :: [Text]
      , eventWorkspace :: Maybe FilePath
      }
  | ProcessFinished
      { eventProcessKind :: Text
      , eventGoalId :: Maybe Text
      , eventExitCode :: Int
      , eventTimedOut :: Bool
      , eventStdout :: Text
      , eventStderr :: Text
      }
  | CodexEventObserved
      { eventGoalId :: Maybe Text
      , eventCodexRawEvent :: Value
      }
  | DagSnapshotObserved
      { eventPhase :: Text
      , eventDagReason :: Maybe Text
      , eventDagNodes :: [Text]
      , eventDagEdges :: [(Text, Text)]
      , eventDagQueued :: Set Text
      , eventDagRunning :: Set Text
      , eventDagCompleted :: Set Text
      , eventDagStatuses :: Map Text Text
      }
  | HarnessFinished
      { eventReason :: Text
      }
  deriving stock (Eq, Show)

instance ToJSON HarnessEvent where
  toJSON event =
    case event of
      HarnessStarted prompt ->
        base "harness_started" ["prompt" .= prompt]
      AssistantMessageObserved content ->
        base "assistant_message" ["content" .= content]
      ReasoningObserved reasoningId encryptedContentChars summaryItems ->
        base
          "reasoning_observed"
          [ "reasoning_id" .= reasoningId
          , "encrypted_content_chars" .= encryptedContentChars
          , "summary_items" .= summaryItems
          ]
      ModelUsageObserved
        inputTokens
        cachedInputTokens
        outputTokens
        reasoningOutputTokens
        totalTokens ->
          base
            "model_usage"
            [ "input_tokens" .= inputTokens
            , "cached_input_tokens" .= cachedInputTokens
            , "output_tokens" .= outputTokens
            , "reasoning_output_tokens" .= reasoningOutputTokens
            , "total_tokens" .= totalTokens
            ]
      ToolCallObserved callId toolName arguments activeSubgoal ->
        base
          "tool_call"
          [ "call_id" .= callId
          , "tool_name" .= toolName
          , "arguments" .= arguments
          , "active_subgoal" .= activeSubgoal
          ]
      ToolResultObserved callId toolName result activeSubgoal ->
        base
          "tool_result"
          [ "call_id" .= callId
          , "tool_name" .= toolName
          , "result" .= result
          , "active_subgoal" .= activeSubgoal
          ]
      SubgoalStarted subgoalId subgoalName ->
        base
          "subgoal_started"
          [ "subgoal_id" .= subgoalId
          , "subgoal_name" .= subgoalName
          ]
      SubgoalEnded subgoalId status summary ->
        base
          "subgoal_ended"
          [ "subgoal_id" .= subgoalId
          , "status" .= status
          , "summary" .= summary
          ]
      EffectRecorded effect activeSubgoal ->
        base
          "effect_recorded"
          [ "effect" .= effect
          , "active_subgoal" .= activeSubgoal
          ]
      WorkflowStatusObserved activeNode lastNode completed failed skipped warnings ->
        base
          "workflow_status"
          [ "active_node" .= activeNode
          , "last_node" .= lastNode
          , "completed_nodes" .= completed
          , "failed_nodes" .= failed
          , "skipped_nodes" .= skipped
          , "transition_warnings" .= warnings
          ]
      ProcessStarted processKind goalId command workspace ->
        base
          "process_started"
          [ "process_kind" .= processKind
          , "goal_id" .= goalId
          , "command" .= command
          , "workspace" .= workspace
          ]
      ProcessFinished processKind goalId exitCode timedOut stdoutText stderrText ->
        base
          "process_finished"
          [ "process_kind" .= processKind
          , "goal_id" .= goalId
          , "exit_code" .= exitCode
          , "timed_out" .= timedOut
          , "stdout" .= stdoutText
          , "stderr" .= stderrText
          ]
      CodexEventObserved goalId rawEvent ->
        base
          "codex_event"
          [ "goal_id" .= goalId
          , "raw_event" .= rawEvent
          ]
      DagSnapshotObserved phase reason nodes edges queued running completed statuses ->
        base
          "dag_snapshot"
          [ "phase" .= phase
          , "reason" .= reason
          , "nodes" .= nodes
          , "edges" .= edges
          , "queued" .= queued
          , "running" .= running
          , "completed" .= completed
          , "statuses" .= statuses
          ]
      HarnessFinished reason ->
        base "harness_finished" ["reason" .= reason]
   where
    base :: Text -> [Pair] -> Value
    base kind fields = object (("type" .= kind) : fields)

eventType :: HarnessEvent -> Text
eventType event =
  case event of
    HarnessStarted{} -> "harness_started"
    AssistantMessageObserved{} -> "assistant_message"
    ReasoningObserved{} -> "reasoning_observed"
    ModelUsageObserved{} -> "model_usage"
    ToolCallObserved{} -> "tool_call"
    ToolResultObserved{} -> "tool_result"
    SubgoalStarted{} -> "subgoal_started"
    SubgoalEnded{} -> "subgoal_ended"
    EffectRecorded{} -> "effect_recorded"
    WorkflowStatusObserved{} -> "workflow_status"
    ProcessStarted{} -> "process_started"
    ProcessFinished{} -> "process_finished"
    CodexEventObserved{} -> "codex_event"
    DagSnapshotObserved{} -> "dag_snapshot"
    HarnessFinished{} -> "harness_finished"
