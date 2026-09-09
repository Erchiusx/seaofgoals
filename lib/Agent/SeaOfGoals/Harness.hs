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
  ( WorkflowSpec
  , WorkflowStatus
  , emptyWorkflowStatus
  , updateWorkflowStatus
  , workflowStatusEvent
  )
import Control.Concurrent.Async
  ( forConcurrently
  )
import Data.Aeson qualified as Aeson
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
  , harnessRequiredSubgoal :: Maybe (Text, Text)
  }

data HarnessState = HarnessState
  { harnessHistory :: [LLMInputItem]
  , harnessActiveSubgoal :: Maybe Text
  , harnessWorkflowStatus :: WorkflowStatus
  , harnessSubgoalResults :: Map.Map Text (Text, Maybe Text)
  }
  deriving stock (Eq, Show)

runHarness :: LLM provider => HarnessConfig provider -> IO HarnessState
runHarness config = do
  harnessEventSink
    config
    (HarnessStarted (harnessUserPrompt config) (harnessSystemPrompt config))
  mapM_ (harnessEventSink config) startEvents
  if null startEvents
    then pure ()
    else
      harnessEventSink
        config
        (workflowStatusEvent (harnessWorkflowStatus initialState))
  loop
    (max 1 (harnessMaxTurns config))
    initialState
 where
  toolMap = Map.fromList [(toolName tool, tool) | tool <- harnessTools config]

  requiredGoalId = fst <$> harnessRequiredSubgoal config
  startEvents =
    maybe
      []
      (\(goalId, name) -> [SubgoalStarted goalId name])
      (harnessRequiredSubgoal config)

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
      , harnessActiveSubgoal = requiredGoalId
      , harnessWorkflowStatus =
          foldl
            (updateWorkflowStatus (harnessWorkflowSpec config))
            emptyWorkflowStatus
            startEvents
      , harnessSubgoalResults = Map.empty
      }

  loop turnsLeft state
    | goalEnded state = do
        harnessEventSink config (HarnessFinished "subgoal_ended")
        pure state
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
      then case requiredGoalId of
        Just goalId -> do
          let reminder =
                "Finish goal "
                  <> goalId
                  <> " by calling end_goal with its id and status (success, failed, skipped, or blocked). Include a summary only when the current workflow requires one. A text-only reply does not complete this goal."
          harnessEventSink config (UserMessageObserved reminder)
          loop
            (turnsLeft - 1)
            state
              { harnessHistory =
                  nextHistory <> [MessageInput (LLMMessage User [TextPart reminder])]
              }
        Nothing -> do
          harnessEventSink
            config
            (HarnessFinished (fromMaybe "assistant_finished" (responseFinishReason response)))
          pure state{harnessHistory = nextHistory}
      else do
        stateAfterTools <-
          runToolCalls state{harnessHistory = nextHistory} (responseToolCalls response)
        loop (turnsLeft - 1) stateAfterTools

  runToolCalls state [] = pure state
  runToolCalls state calls | goalEnded state = do
    let results =
          [ ToolResult
              (toolCallId call)
              (Just (toolCallName call))
              [TextPart "Not executed: the required goal has ended."]
          | call <- calls
          ]
    mapM_ (emitToolCallObserved (harnessActiveSubgoal state)) calls
    mapM_
      ( \result ->
          harnessEventSink
            config
            ( ToolResultObserved
                (toolResultCallId result)
                (fromMaybe "" (toolResultName result))
                "Not executed: the required goal has ended."
                (harnessActiveSubgoal state)
            )
      )
      results
    pure
      state{harnessHistory = harnessHistory state <> fmap ToolResultInput results}
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
      effectiveToolCalls = toolCalls
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
        , harnessSubgoalResults =
            collectResults (harnessSubgoalResults state) eventsWithActiveSubgoal
        }

  runToolCall state toolCall = do
    let
      activeSubgoal = harnessActiveSubgoal state
      effectiveToolCall = toolCall
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
        , harnessSubgoalResults =
            collectResults (harnessSubgoalResults state) eventsWithActiveSubgoal
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
        let invalidEnd =
              any
                ( \case
                    SubgoalEnded goalId _ _ ->
                      maybe
                        False
                        (\required -> goalId /= required || activeSubgoal /= Just required)
                        requiredGoalId
                    _ -> False
                )
                events
        let eventsWithActiveSubgoal =
              if invalidEnd then [] else fmap (attachActiveSubgoal activeSubgoal) events
        pure
          ToolCallOutcome
            { toolCallOutcomeCall = effectiveToolCall
            , toolCallOutcomeResult =
                if invalidEnd
                  then
                    result
                      { toolResultContent =
                          [ TextPart "end_goal must use the id of the goal already started by the harness."
                          ]
                      }
                  else result
            , toolCallOutcomeEvents = eventsWithActiveSubgoal
            , toolCallOutcomeActiveSubgoal = activeSubgoal
            }

  goalEnded state =
    maybe
      False
      (`Map.member` harnessSubgoalResults state)
      requiredGoalId
  collectResults =
    foldl
      ( \results -> \case
          SubgoalEnded goalId status summary -> Map.insert goalId (status, summary) results
          _ -> results
      )

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
  toolCallName toolCall == "end_goal"

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
