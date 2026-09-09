module Agent.SeaOfGoals.Workflow
  ( WorkflowEdge (..)
  , WorkflowNode (..)
  , WorkflowSpec (..)
  , WorkflowStatus (..)
  , emptyWorkflowStatus
  , renderWorkflowPrompt
  , updateWorkflowStatus
  , validateWorkflowTransition
  , workflowStatusEvent
  )
where

import Agent.SeaOfGoals.Trace (HarnessEvent (..))
import Control.Applicative ((<|>))
import Data.Aeson
  ( FromJSON (..)
  , withObject
  , (.:)
  , (.:?)
  )
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

data WorkflowNode = WorkflowNode
  { workflowNodeId :: Text
  , workflowNodeTitle :: Text
  , workflowNodeBody :: Text
  }
  deriving stock (Eq, Show)

instance FromJSON WorkflowNode where
  parseJSON =
    withObject "WorkflowNode" $ \value ->
      WorkflowNode
        <$> value .: "id"
        <*> value .: "title"
        <*> fmap (maybe "" id) (value .:? "body")

data WorkflowEdge = WorkflowEdge
  { workflowEdgeSource :: Text
  , workflowEdgeTarget :: Text
  , workflowEdgeRationale :: Maybe Text
  }
  deriving stock (Eq, Show)

instance FromJSON WorkflowEdge where
  parseJSON =
    withObject "WorkflowEdge" $ \value -> do
      source <- value .:? "source"
      src <- value .:? "src"
      target <- value .:? "target"
      dst <- value .:? "dst"
      WorkflowEdge
        <$> maybe (fail "WorkflowEdge requires source or src") pure (source <|> src)
        <*> maybe (fail "WorkflowEdge requires target or dst") pure (target <|> dst)
        <*> value .:? "rationale"

data WorkflowSpec = WorkflowSpec
  { workflowName :: Text
  , workflowNodes :: [WorkflowNode]
  , workflowEdges :: [WorkflowEdge]
  }
  deriving stock (Eq, Show)

instance FromJSON WorkflowSpec where
  parseJSON =
    withObject "WorkflowSpec" $ \value -> do
      name <- value .:? "name"
      skillName <- value .:? "skill_name"
      nodes <- value .:? "nodes"
      instructions <- value .:? "instructions"
      WorkflowSpec
        <$> pure (maybe "workflow" id (name <|> skillName))
        <*> maybe
          (fail "WorkflowSpec requires nodes or instructions")
          pure
          (nodes <|> instructions)
        <*> value .: "edges"

data WorkflowStatus = WorkflowStatus
  { workflowActiveNode :: Maybe Text
  , workflowLastNode :: Maybe Text
  , workflowCompletedNodes :: Set Text
  , workflowFailedNodes :: Set Text
  , workflowSkippedNodes :: Set Text
  , workflowTransitionWarnings :: [Text]
  }
  deriving stock (Eq, Show)

emptyWorkflowStatus :: WorkflowStatus
emptyWorkflowStatus =
  WorkflowStatus
    { workflowActiveNode = Nothing
    , workflowLastNode = Nothing
    , workflowCompletedNodes = Set.empty
    , workflowFailedNodes = Set.empty
    , workflowSkippedNodes = Set.empty
    , workflowTransitionWarnings = []
    }

renderWorkflowPrompt :: WorkflowSpec -> Text
renderWorkflowPrompt spec =
  Text.unlines
    [ "Static workflow graph detected from the skill:"
    , "Workflow name: " <> workflowName spec
    , ""
    , "Nodes:"
    , Text.unlines (fmap renderNode (workflowNodes spec))
    , "Edges:"
    , Text.unlines (fmap renderEdge (workflowEdges spec))
    , "The harness selects and starts the current node; do not call a start tool."
    , "Use end_goal with the same node id when the node is finished."
    , "Do not echo AgentSanitizer begin/end markers; use end_goal to report completion instead."
    ]
 where
  renderNode node =
    "- "
      <> workflowNodeId node
      <> ": "
      <> workflowNodeTitle node
      <> bodySuffix (workflowNodeBody node)
  renderEdge edge =
    "- "
      <> workflowEdgeSource edge
      <> " -> "
      <> workflowEdgeTarget edge
      <> maybe "" (" (" <>) (workflowEdgeRationale edge)
      <> maybe "" (const ")") (workflowEdgeRationale edge)
  bodySuffix body
    | Text.null (Text.strip body) = ""
    | otherwise = " -- " <> Text.strip body

validateWorkflowTransition
  :: WorkflowSpec -> Maybe Text -> Text -> Either Text ()
validateWorkflowTransition spec previous next
  | next `Set.notMember` nodeIds =
      Left ("unknown workflow node id: " <> next)
  | previous == Nothing =
      Right ()
  | Just next == previous =
      Right ()
  | (maybe "" id previous, next) `Set.member` edgeSet =
      Right ()
  | otherwise =
      Left
        ( "workflow transition is not declared by CFG: "
            <> maybe "<none>" id previous
            <> " -> "
            <> next
        )
 where
  nodeIds = Set.fromList (fmap workflowNodeId (workflowNodes spec))
  edgeSet =
    Set.fromList
      [ (workflowEdgeSource edge, workflowEdgeTarget edge)
      | edge <- workflowEdges spec
      ]

updateWorkflowStatus
  :: Maybe WorkflowSpec -> WorkflowStatus -> HarnessEvent -> WorkflowStatus
updateWorkflowStatus maybeSpec status event =
  case event of
    SubgoalStarted subgoalId _ ->
      case maybeSpec of
        Nothing -> status{workflowActiveNode = Just subgoalId}
        Just spec ->
          case validateWorkflowTransition
            spec
            (workflowActiveNode status <|> workflowLastNode status)
            subgoalId of
            Right () -> status{workflowActiveNode = Just subgoalId}
            Left warning ->
              status
                { workflowActiveNode = Just subgoalId
                , workflowTransitionWarnings = workflowTransitionWarnings status <> [warning]
                }
    SubgoalEnded subgoalId eventStatus _ ->
      status
        { workflowActiveNode = Nothing
        , workflowLastNode = Just subgoalId
        , workflowCompletedNodes = addIf "success" workflowCompletedNodes
        , workflowFailedNodes = addIf "failed" workflowFailedNodes
        , workflowSkippedNodes = addIf "skipped" workflowSkippedNodes
        }
     where
      addIf expected field
        | eventStatus == expected = Set.insert subgoalId (field status)
        | otherwise = field status
    _ -> status

workflowStatusEvent :: WorkflowStatus -> HarnessEvent
workflowStatusEvent status =
  WorkflowStatusObserved
    { eventActiveNode = workflowActiveNode status
    , eventLastNode = workflowLastNode status
    , eventCompletedNodes = workflowCompletedNodes status
    , eventFailedNodes = workflowFailedNodes status
    , eventSkippedNodes = workflowSkippedNodes status
    , eventTransitionWarnings = workflowTransitionWarnings status
    }
