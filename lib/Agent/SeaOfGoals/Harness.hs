module Agent.SeaOfGoals.Harness
  ( HarnessConfig (..)
  , HarnessState (..)
  , runHarness
  )
where

import Agent.SeaOfGoals.LLM
  ( LLM (runLLM)
  , LLMContentPart (TextPart)
  , LLMInputItem (MessageInput, ReasoningInput, ToolCallInput, ToolResultInput)
  , LLMMessage (..)
  , LLMRequest (..)
  , LLMResponse (..)
  , LLMRole (..)
  , LLMUsage (..)
  , ReasoningItem (..)
  , ToolCall (..)
  , ToolResult (..)
  )
import Agent.SeaOfGoals.Tools
  ( ToolSpec (..)
  , runToolHandler
  , toolSpecToOpenAITool
  )
import Agent.SeaOfGoals.Trace
  ( HarnessEvent (..)
  )
import Agent.SeaOfGoals.Workflow
  ( WorkflowNode (..)
  , WorkflowSpec (..)
  , WorkflowStatus
  , emptyWorkflowStatus
  , updateWorkflowStatus
  , workflowStatusEvent
  )
import Control.Concurrent.Async
  ( forConcurrently
  )
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as Text

data HarnessConfig provider = HarnessConfig
  { harnessProvider :: provider
  , harnessRequestTemplate :: LLMRequest
  , harnessSystemPrompt :: Text
  , harnessUserPrompt :: Text
  , harnessInitialHistorySuffix :: [LLMInputItem]
  , harnessTools :: [ToolSpec]
  , harnessMaxTurns :: Int
  , harnessEventSink :: HarnessEvent -> IO ()
  , harnessWorkflowSpec :: Maybe WorkflowSpec
  }

data HarnessState = HarnessState
  { harnessHistory :: [LLMInputItem]
  , harnessActiveSubgoal :: Maybe Text
  , harnessWorkflowStatus :: WorkflowStatus
  }
  deriving stock (Eq, Show)

runHarness :: LLM provider => HarnessConfig provider -> IO HarnessState
runHarness config = do
  harnessEventSink config (HarnessStarted (harnessUserPrompt config))
  loop
    (max 1 (harnessMaxTurns config))
    initialState
 where
  toolMap = Map.fromList [(toolName tool, tool) | tool <- harnessTools config]

  initialState =
    HarnessState
      { harnessHistory =
          [ MessageInput
              LLMMessage
                { messageRole = System
                , messageContent = [TextPart (harnessSystemPrompt config)]
                }
          , MessageInput
              LLMMessage
                { messageRole = User
                , messageContent = [TextPart (harnessUserPrompt config)]
                }
          ]
            <> harnessInitialHistorySuffix config
      , harnessActiveSubgoal = Nothing
      , harnessWorkflowStatus = emptyWorkflowStatus
      }

  loop turnsLeft state
    | turnsLeft <= 0 = do
        harnessEventSink config (HarnessFinished "max_turns_reached")
        pure state
    | otherwise = do
        result <-
          runLLM
            (harnessProvider config)
            (harnessRequestTemplate config)
              { requestInput = harnessHistory state
              , requestTools = fmap toolSpecToOpenAITool (harnessTools config)
              }
        case result of
          Left err -> do
            harnessEventSink config (HarnessFinished ("llm_error: " <> showText err))
            pure state
          Right response ->
            handleResponse turnsLeft state response

  handleResponse turnsLeft state response = do
    let assistantText = messageText (responseMessage response)
    harnessEventSink config (AssistantMessageObserved assistantText)
    mapM_ (harnessEventSink config . usageObservedEvent) (responseUsage response)
    mapM_ (harnessEventSink config . reasoningObservedEvent) $
      responseReasoningItems response
    let nextHistory = harnessHistory state <> responseOutput response
    if null (responseToolCalls response)
      then do
        harnessEventSink
          config
          (HarnessFinished (fromMaybe "assistant_finished" (responseFinishReason response)))
        pure state{harnessHistory = nextHistory}
      else do
        stateAfterTools <-
          runToolCalls state{harnessHistory = nextHistory} (responseToolCalls response)
        loop (turnsLeft - 1) stateAfterTools

  runToolCalls state [] = pure state
  runToolCalls state toolCalls =
    case span (not . isWorkflowBarrierTool) toolCalls of
      ([], barrier : rest) -> do
        stateAfterBarrier <- runToolCall state barrier
        runToolCalls stateAfterBarrier rest
      (parallelCalls, rest) -> do
        stateAfterParallel <- runParallelToolCalls state parallelCalls
        runToolCalls stateAfterParallel rest

  runParallelToolCalls state toolCalls = do
    let
      activeSubgoal = harnessActiveSubgoal state
      effectiveToolCalls =
        fmap
          (canonicalizeWorkflowToolCall (harnessWorkflowSpec config))
          toolCalls
    mapM_
      (emitToolCallObserved activeSubgoal)
      effectiveToolCalls
    outcomes <-
      forConcurrently
        effectiveToolCalls
        (runEffectiveToolCall activeSubgoal)
    let
      eventsWithActiveSubgoal =
        concatMap toolCallOutcomeEvents outcomes
      nextWorkflowStatus =
        foldl
          (updateWorkflowStatus (harnessWorkflowSpec config))
          (harnessWorkflowStatus state)
          eventsWithActiveSubgoal
    mapM_ emitToolCallOutcome outcomes
    if nextWorkflowStatus == harnessWorkflowStatus state
      then pure ()
      else harnessEventSink config (workflowStatusEvent nextWorkflowStatus)
    pure
      state
        { harnessHistory =
            harnessHistory state
              <> concatMap toolCallOutcomeHistory outcomes
        , harnessActiveSubgoal =
            updateActiveSubgoal
              (harnessActiveSubgoal state)
              eventsWithActiveSubgoal
        , harnessWorkflowStatus =
            nextWorkflowStatus
        }

  runToolCall state toolCall = do
    let
      activeSubgoal = harnessActiveSubgoal state
      effectiveToolCall =
        canonicalizeWorkflowToolCall (harnessWorkflowSpec config) toolCall
    emitToolCallObserved activeSubgoal effectiveToolCall
    outcome <- runEffectiveToolCall activeSubgoal effectiveToolCall
    let
      eventsWithActiveSubgoal = toolCallOutcomeEvents outcome
      nextWorkflowStatus =
        foldl
          (updateWorkflowStatus (harnessWorkflowSpec config))
          (harnessWorkflowStatus state)
          eventsWithActiveSubgoal
    emitToolCallOutcome outcome
    if nextWorkflowStatus == harnessWorkflowStatus state
      then pure ()
      else harnessEventSink config (workflowStatusEvent nextWorkflowStatus)
    pure
      state
        { harnessHistory =
            harnessHistory state <> toolCallOutcomeHistory outcome
        , harnessActiveSubgoal =
            updateActiveSubgoal
              (harnessActiveSubgoal state)
              eventsWithActiveSubgoal
        , harnessWorkflowStatus =
            nextWorkflowStatus
        }

  runEffectiveToolCall activeSubgoal effectiveToolCall =
    case Map.lookup (toolCallName effectiveToolCall) toolMap of
      Nothing -> do
        let result =
              unknownToolResult effectiveToolCall
        pure
          ToolCallOutcome
            { toolCallOutcomeCall = effectiveToolCall
            , toolCallOutcomeResult = result
            , toolCallOutcomeEvents = []
            , toolCallOutcomeActiveSubgoal = activeSubgoal
            }
      Just tool -> do
        (result, events) <- runToolHandler tool effectiveToolCall
        let eventsWithActiveSubgoal =
              fmap (attachActiveSubgoal activeSubgoal) events
        pure
          ToolCallOutcome
            { toolCallOutcomeCall = effectiveToolCall
            , toolCallOutcomeResult = result
            , toolCallOutcomeEvents = eventsWithActiveSubgoal
            , toolCallOutcomeActiveSubgoal = activeSubgoal
            }

  emitToolCallOutcome outcome = do
    let
      toolCall = toolCallOutcomeCall outcome
      result = toolCallOutcomeResult outcome
      activeSubgoal = toolCallOutcomeActiveSubgoal outcome
    mapM_ (harnessEventSink config) (toolCallOutcomeEvents outcome)
    harnessEventSink
      config
      ToolResultObserved
        { eventCallId = toolCallId toolCall
        , eventToolName = toolCallName toolCall
        , eventResult = messageText (LLMMessage Tool (toolResultContent result))
        , eventActiveSubgoal = activeSubgoal
        }

  emitToolCallObserved activeSubgoal toolCall =
    harnessEventSink
      config
      ToolCallObserved
        { eventCallId = toolCallId toolCall
        , eventToolName = toolCallName toolCall
        , eventArguments = toolCallArguments toolCall
        , eventActiveSubgoal = activeSubgoal
        }

responseReasoningItems :: LLMResponse -> [ReasoningItem]
responseReasoningItems response =
  [reasoningItem | ReasoningInput reasoningItem <- responseOutput response]

reasoningObservedEvent :: ReasoningItem -> HarnessEvent
reasoningObservedEvent reasoningItem =
  ReasoningObserved
    { eventReasoningId = reasoningItemId reasoningItem
    , eventEncryptedContentChars =
        Text.length (reasoningItemEncryptedContent reasoningItem)
    , eventReasoningSummaryItems = summaryItems (reasoningItemSummary reasoningItem)
    }

summaryItems :: Aeson.Value -> Int
summaryItems (Aeson.Array items) = length (toList items)
summaryItems Aeson.Null = 0
summaryItems _ = 1

usageObservedEvent :: LLMUsage -> HarnessEvent
usageObservedEvent usage =
  ModelUsageObserved
    { eventInputTokens = usagePromptTokens usage
    , eventCachedInputTokens = usageCachedTokens usage
    , eventOutputTokens = usageCompletionTokens usage
    , eventReasoningOutputTokens = usageReasoningTokens usage
    , eventTotalTokens = usageTotalTokens usage
    }

isWorkflowBarrierTool :: ToolCall -> Bool
isWorkflowBarrierTool toolCall =
  toolCallName toolCall == "begin_subgoal"
    || toolCallName toolCall == "end_subgoal"

data ToolCallOutcome = ToolCallOutcome
  { toolCallOutcomeCall :: ToolCall
  , toolCallOutcomeResult :: ToolResult
  , toolCallOutcomeEvents :: [HarnessEvent]
  , toolCallOutcomeActiveSubgoal :: Maybe Text
  }

toolCallOutcomeHistory :: ToolCallOutcome -> [LLMInputItem]
toolCallOutcomeHistory outcome =
  [ ToolCallInput (toolCallOutcomeCall outcome)
  , ToolResultInput (toolCallOutcomeResult outcome)
  ]

attachActiveSubgoal :: Maybe Text -> HarnessEvent -> HarnessEvent
attachActiveSubgoal activeSubgoal event =
  case event of
    EffectRecorded effect Nothing ->
      EffectRecorded effect activeSubgoal
    _ -> event

canonicalizeWorkflowToolCall :: Maybe WorkflowSpec -> ToolCall -> ToolCall
canonicalizeWorkflowToolCall maybeSpec toolCall
  | toolCallName toolCall /= "begin_subgoal" = toolCall
  | otherwise =
      case (maybeSpec, toolCallArguments toolCall) of
        (Just spec, Aeson.Object arguments) ->
          case AesonKeyMap.lookup (AesonKey.fromText "id") arguments of
            Just (Aeson.String subgoalId) ->
              case workflowNodeTitleFor spec subgoalId of
                Just title ->
                  toolCall
                    { toolCallArguments =
                        Aeson.Object
                          ( AesonKeyMap.insert
                              (AesonKey.fromText "name")
                              (Aeson.String title)
                              arguments
                          )
                    }
                Nothing -> toolCall
            _ -> toolCall
        _ -> toolCall

workflowNodeTitleFor :: WorkflowSpec -> Text -> Maybe Text
workflowNodeTitleFor spec subgoalId =
  foldr matchNode Nothing (workflowNodes spec)
 where
  matchNode node fallback
    | workflowNodeId node == subgoalId = Just (workflowNodeTitle node)
    | otherwise = fallback

unknownToolResult :: ToolCall -> ToolResult
unknownToolResult toolCall =
  ToolResult
    { toolResultCallId = toolCallId toolCall
    , toolResultName = Just (toolCallName toolCall)
    , toolResultContent = [TextPart "Unknown tool"]
    }

updateActiveSubgoal :: Maybe Text -> [HarnessEvent] -> Maybe Text
updateActiveSubgoal = foldl step
 where
  step _ SubgoalStarted{eventSubgoalId = subgoalId} = Just subgoalId
  step _ SubgoalEnded{} = Nothing
  step current _ = current

messageText :: LLMMessage -> Text
messageText message =
  foldMap contentPartText (messageContent message)

contentPartText :: LLMContentPart -> Text
contentPartText (TextPart text) = text
contentPartText _ = ""

showText :: Show value => value -> Text
showText = fromString . show
