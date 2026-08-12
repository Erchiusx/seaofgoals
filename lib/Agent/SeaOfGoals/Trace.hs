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
    ToolCallObserved{} -> "tool_call"
    ToolResultObserved{} -> "tool_result"
    SubgoalStarted{} -> "subgoal_started"
    SubgoalEnded{} -> "subgoal_ended"
    EffectRecorded{} -> "effect_recorded"
    WorkflowStatusObserved{} -> "workflow_status"
    HarnessFinished{} -> "harness_finished"
