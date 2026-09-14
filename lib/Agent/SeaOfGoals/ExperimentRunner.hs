module Agent.SeaOfGoals.ExperimentRunner
  ( appendEvent
  , experimentSystemPrompt
  , experimentTools
  , loadWorkflowSpecFromEnv
  , runPrompt
  , runPromptFromArgs
  )
where

import Agent.SeaOfGoals.CodexProcess
  ( CodexProcessConfig
  , CodexProcessResult (..)
  , loadCodexProcessConfigFromEnv
  , runCodexProcessWithControlRoot
  )
import Agent.SeaOfGoals.Compile.Compiler
  ( CompiledGoalGraph (..)
  , validateCompiledGoalGraph
  )
import Agent.SeaOfGoals.Compile.PromptTemplate (embedTextFile)
import Agent.SeaOfGoals.Config
  ( ConcurrentChaseConfig (..)
  , Config
  , configConcurrentChase
  , loadConfigFromEnv
  )
import Agent.SeaOfGoals.GoalContextPreload
  ( GoalContextPreloadConfig
  , GoalContextPreloadPlan (..)
  , PreloadedGoalContext (..)
  , loadGoalContextPreloadConfigFromEnv
  , loadGoalContextPreloadPlanFromEnv
  , mergeGoalContextPreloadPlans
  , preloadGoalContextWithPlanDetailed
  , readGoalContextPreloadPlanFile
  )
import Agent.SeaOfGoals.Harness
  ( HarnessConfig (..)
  , HarnessState (..)
  , runHarness
  )
import Agent.SeaOfGoals.HistoryHandoff
  ( GoalHistories
  , historiesForGoal
  , newGoalHistories
  , ownHistoryAfterInitialItems
  , rememberGoalHistory
  )
import Agent.SeaOfGoals.LLM
  ( LLMContentPart (TextPart)
  , LLMInputItem (ToolCallInput, ToolResultInput)
  , LLMRequest (..)
  , ResponseFormat (PlainText)
  , ToolCall (..)
  , ToolResult (..)
  )
import Agent.SeaOfGoals.LLM.Backends.GPT
  ( GPTBackend (..)
  , loadGPTEndpointFromEnv
  )
import Agent.SeaOfGoals.PiProcess
  ( PiProcessConfig (..)
  , PiProcessResult (..)
  , loadPiProcessConfigFromEnv
  , runPiProcess
  , runPiSdkProcess
  )
import Agent.SeaOfGoals.PredictedActions
  ( PredictedActionsPlan (..)
  , loadPredictedActionsPlanFromEnv
  , mergePredictedActionsPlans
  , readPredictedActionsPlanFile
  , runPredictedActions
  )
import Agent.SeaOfGoals.Scheduling.Agentic
  ( AgentRunResult (..)
  , GoalGraph (..)
  , GoalNode (..)
  , GoalNodeId (..)
  , SnapshotId (..)
  )
import Agent.SeaOfGoals.Scheduling.Compiled
  ( compiledGraphToGoalGraph
  )
import Agent.SeaOfGoals.Scheduling.ConcurrentChase
  ( ConcurrentChaseConflict (..)
  , ConcurrentChaseResult (..)
  , ConcurrentChaseRunner (..)
  , runConcurrentChase
  , runConcurrentChaseWithPlanner
  )
import Agent.SeaOfGoals.Scheduling.GraphChase
  ( ChaseState (..)
  , initialChaseState
  )
import Agent.SeaOfGoals.Scheduling.PlannerResolution qualified as PlannerResolution
import Agent.SeaOfGoals.Scheduling.SerialScheduler
  ( SerialScheduler (..)
  , SerialSchedulerResult (..)
  , goalPredecessors
  , runSerialScheduler
  )
import Agent.SeaOfGoals.Tools
  ( ToolSpec
  , objectToolSpec
  , toolName
  )
import Agent.SeaOfGoals.Trace
  ( EffectRecord (..)
  , HarnessEvent (..)
  )
import Agent.SeaOfGoals.Workflow
  ( WorkflowSpec
  , renderWorkflowPrompt
  , workflowCompletedNodes
  , workflowFailedNodes
  , workflowSkippedNodes
  )
import Agent.SeaOfGoals.Workspace.Bwrap.Command qualified as BwrapCommand
import Agent.SeaOfGoals.Workspace.Bwrap.Profile qualified as BwrapProfile
import Agent.SeaOfGoals.Workspace.Bwrap.ToolBinding
  ( BwrapToolBinding (..)
  , bwrapShellTool
  )
import Agent.SeaOfGoals.Workspace.ConflictPolicy
  ( AccessSets (..)
  , ConflictMode
  , conflictingPaths
  , loadConflictModeFromEnv
  )
#ifdef SOG_FUSE
import Agent.SeaOfGoals.Workspace.Backend qualified as WorkspaceBackend
import Agent.SeaOfGoals.Workspace.Fuse.Mount
  ( mountFuseWorkspace
  , unmountFuseWorkspace
  )
import Agent.SeaOfGoals.Workspace.Fuse.Store qualified as FuseStore
#endif
import Agent.SeaOfGoals.Workspace.Sandbox
  ( SandboxRunner (..)
  )
import Agent.SeaOfGoals.Workspace.Sandbox.Bwrap
  ( BwrapSandboxRunner (..)
  , BwrapSandboxSpec (..)
  )
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar_
  , newMVar
  )
#ifdef SOG_FUSE
import Control.Exception
  ( bracket
  )
#endif
import Control.Monad
  ( filterM
  , forM
  , forM_
  , unless
  , void
  , when
  )
import Data.Aeson
  ( FromJSON (..)
  , Value
  , eitherDecode
  , encode
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (isPrefixOf, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Vector qualified as Vector
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , doesPathExist
  , getCurrentDirectory
  , listDirectory
  , removePathForcibly
  )
import System.Environment
  ( getArgs
  , lookupEnv
  , unsetEnv
  )
import System.Exit (ExitCode (..))
import System.FilePath
  ( addTrailingPathSeparator
  , isAbsolute
  , normalise
  , splitDirectories
  , takeDirectory
  , (</>)
  )
import System.Process
  ( cwd
  , proc
  , readCreateProcessWithExitCode
  )

data ExperimentContext = ExperimentContext
  { experimentBackend :: GPTBackend
  , experimentRequestTemplate :: LLMRequest
  , experimentTracePath :: FilePath
  , experimentControlRoot :: FilePath
  , experimentSystemPromptText :: Text
  , experimentUserPromptText :: Text
  , experimentConfig :: Config
  , experimentAgentRunner :: AgentRunnerMode
  , experimentCodexProcessConfig :: CodexProcessConfig
  , experimentPiProcessConfig :: PiProcessConfig
  , experimentToolsForRun :: [ToolSpec]
  , experimentEventSink :: HarnessEvent -> IO ()
  , experimentWorkflowSpec :: Maybe WorkflowSpec
  , experimentCodexHistoryHandoff :: Bool
  , experimentHarnessHistoryHandoff :: Bool
  , experimentPiHistoryHandoff :: Bool
  , experimentConcurrentWorkspaceMode :: ConcurrentWorkspaceMode
  , experimentConflictMode :: ConflictMode
  , experimentGoalContextPreloadConfig :: GoalContextPreloadConfig
  , experimentGoalContextPreloadPlan :: GoalContextPreloadPlan
  , experimentDynamicGoalContextPreloadPlan :: IORef GoalContextPreloadPlan
  , experimentPlannerResolutions
      :: IORef (Map GoalNodeId PlannerResolution.Resolution)
  , experimentPredictedActionsPlan :: PredictedActionsPlan
  , experimentHarnessLifecycle :: Bool
  }

data AgentRunnerMode
  = HarnessAgentRunner
  | CodexAgentRunner
  | PiAgentRunner
  deriving stock (Eq, Show)

data ConcurrentWorkspaceMode
  = CopyTreeWorkspace
  | FuseEventWorkspace
  deriving stock (Eq, Show)

data AcceptedEffects = AcceptedEffects
  { acceptedEffectsGoal :: GoalNodeId
  , acceptedEffectsGeneration :: Int
  , acceptedEffectsReads :: Set FilePath
  , acceptedEffectsWrites :: Set FilePath
  , acceptedEffectsRegularFileWrites :: Set FilePath
  }
  deriving stock (Eq, Show)

runPromptFromArgs :: IO ()
runPromptFromArgs = do
  apiKey <- lookupEnv "OPENAI_API_KEY"
  agentRunner <- loadAgentRunnerMode
  case (agentRunner, apiKey) of
    (HarnessAgentRunner, Nothing) ->
      putStrLn "OPENAI_API_KEY is not set."
    (_, maybeKey) -> do
      args <- getArgs
      let prompt = Text.pack (unwords args)
      if Text.null prompt
        then putStrLn "Usage: SeaOfGoals-agent-runner <prompt>"
        else runPrompt (fromMaybe "" maybeKey) prompt

runPrompt :: String -> Text -> IO ()
runPrompt apiKey prompt = do
  context <- loadExperimentContext apiKey prompt
  scheduler <- fromMaybe "serial" <$> lookupEnv "SOG_SCHEDULER"
  maybeSerialGoalsText <- lookupEnv "SOG_SERIAL_GOALS_TEXT"
  maybeSerialGoals <- lookupEnv "SOG_SERIAL_GOALS"
  case maybeSerialGoalsText of
    Just goalsText | not (null goalsText) -> do
      unsetEnv "SOG_SERIAL_GOALS_TEXT"
      compiledGraph <- parseCompiledGoalGraphText goalsText
      runPromptWithGraph scheduler context compiledGraph
    _ ->
      case maybeSerialGoals of
        Just path | not (null path) -> do
          unsetEnv "SOG_SERIAL_GOALS"
          loadCompiledGoalGraph path >>= runPromptWithGraph scheduler context
        _ -> runSinglePrompt context

runPromptWithGraph :: String -> ExperimentContext -> CompiledGoalGraph -> IO ()
runPromptWithGraph scheduler context graph =
  case scheduler of
    "concurrent" -> runConcurrentPromptWithGraph context graph
    "serial" -> runSerialPromptWithGraph context graph
    "" -> runSerialPromptWithGraph context graph
    other -> fail ("unknown SOG_SCHEDULER: " <> other)

loadExperimentContext :: String -> Text -> IO ExperimentContext
loadExperimentContext apiKey prompt = do
  workspaceRoot <- normalise <$> getCurrentDirectory
  controlRoot <-
    maybe
      (pure (defaultExperimentControlRoot workspaceRoot))
      (pure . normalise)
      =<< lookupEnv "SOG_CONTROL_ROOT"
  tracePath <-
    maybe
      (pure (controlRoot </> "sog-trace.jsonl"))
      (pure . normalise)
      =<< lookupEnv "SOG_TRACE_PATH"
  model <- Text.pack . fromMaybe "gpt-5.5" <$> lookupEnv "SOG_MODEL"
  promptCacheKey <- fmap Text.pack <$> lookupNonEmptyEnv "SOG_PROMPT_CACHE_KEY"
  promptCacheRetention <-
    fmap Text.pack <$> lookupNonEmptyEnv "SOG_PROMPT_CACHE_RETENTION"
  config <- loadConfigFromEnv
  agentRunner <- loadAgentRunnerMode
  codexProcessConfig <- loadCodexProcessConfigFromEnv
  piProcessConfig <- loadPiProcessConfigFromEnv
  workflowSpec <- loadWorkflowSpecFromEnv
  codexHistoryHandoff <- loadCodexHistoryHandoff
  harnessHistoryHandoff <- loadHarnessHistoryHandoff
  piHistoryHandoff <- loadPiHistoryHandoff
  concurrentWorkspaceMode <- loadConcurrentWorkspaceMode
  conflictMode <- loadConflictModeFromEnv
  goalContextPreloadConfig <- loadGoalContextPreloadConfigFromEnv
  goalContextPreloadPlan <- loadGoalContextPreloadPlanFromEnv
  predictedActionsPlan <- loadPredictedActionsPlanFromEnv
  harnessLifecycle <- loadHarnessLifecycleMode
  dynamicGoalContextPreloadPlan <- newIORef (GoalContextPreloadPlan Map.empty)
  plannerResolutions <- newIORef Map.empty
  createDirectoryIfMissing True controlRoot
  tools <-
    loadExperimentToolsWithControlRoot
      controlRoot
      dynamicGoalContextPreloadPlan
      harnessLifecycle
  skillContext <- loadSkillContextFromEnv
  createDirectoryIfMissing True (takeDirectory tracePath)
  traceLock <- newMVar ()
  endpoint <- loadGPTEndpointFromEnv
  let
    backend =
      GPTBackend
        { gptApiKey = apiKey
        , gptEndpoint = endpoint
        }
    requestTemplate =
      LLMRequest
        { requestModel = model
        , requestInput = []
        , requestTemperature =
            if "gpt-5" `Text.isPrefixOf` model
              then Nothing
              else Just 0.2
        , requestMaxTokens = Nothing
        , requestStopSequences = []
        , requestResponseFormat = PlainText
        , requestTools = []
        , requestConfig = Nothing
        , requestPromptCacheKey = promptCacheKey
        , requestPromptCacheRetention = promptCacheRetention
        }
    workflowPrompt = maybe "" renderWorkflowPrompt workflowSpec
    baseSystemPrompt =
      if harnessLifecycle
        then experimentSystemPrompt
        else experimentSystemPromptNoLifecycle
    effectiveBaseSystemPrompt =
      if agentRunner == HarnessAgentRunner && harnessHistoryHandoff
        then
          Text.replace
            "When the step is complete, call end_goal with its id, status, and a substantive summary for successor goals. Include prepared plans, exact commands, results, and limitations they need. For an assigned compiled goal, this ends execution immediately."
            "When the step is complete, call end_goal with its id and status. In history-handoff mode, do not generate a summary; successor goals receive the complete goal history. For an assigned compiled goal, this ends execution immediately."
            baseSystemPrompt
        else baseSystemPrompt
    systemPrompt =
      Text.intercalate
        "\n\n"
        ( filter
            (not . Text.null)
            [ effectiveBaseSystemPrompt
            , "In one model response, you may return multiple independent tool calls. The harness executes tool calls from the same response in parallel. Return independent reads or writes together when they do not depend on each other; use separate responses when one operation depends on the result of another."
            , skillContext
            , workflowPrompt
            ]
        )
  pure
    ExperimentContext
      { experimentBackend = backend
      , experimentRequestTemplate = requestTemplate
      , experimentTracePath = tracePath
      , experimentControlRoot = controlRoot
      , experimentSystemPromptText = systemPrompt
      , experimentUserPromptText = prompt
      , experimentConfig = config
      , experimentAgentRunner = agentRunner
      , experimentCodexProcessConfig = codexProcessConfig
      , experimentPiProcessConfig = piProcessConfig
      , experimentToolsForRun = tools
      , experimentEventSink = lockedAppendEvent traceLock tracePath
      , experimentWorkflowSpec = workflowSpec
      , experimentCodexHistoryHandoff = codexHistoryHandoff
      , experimentHarnessHistoryHandoff = harnessHistoryHandoff
      , experimentPiHistoryHandoff = piHistoryHandoff
      , experimentConcurrentWorkspaceMode = concurrentWorkspaceMode
      , experimentConflictMode = conflictMode
      , experimentGoalContextPreloadConfig = goalContextPreloadConfig
      , experimentGoalContextPreloadPlan = goalContextPreloadPlan
      , experimentDynamicGoalContextPreloadPlan = dynamicGoalContextPreloadPlan
      , experimentPlannerResolutions = plannerResolutions
      , experimentPredictedActionsPlan = predictedActionsPlan
      , experimentHarnessLifecycle = harnessLifecycle
      }

defaultExperimentControlRoot :: FilePath -> FilePath
defaultExperimentControlRoot workspaceRoot =
  workspaceRoot <> ".sog"

runSinglePrompt :: ExperimentContext -> IO ()
runSinglePrompt context = do
  case experimentAgentRunner context of
    HarnessAgentRunner ->
      void $
        runHarness
          HarnessConfig
            { harnessProvider = experimentBackend context
            , harnessRequestTemplate = experimentRequestTemplate context
            , harnessSystemPrompt = experimentSystemPromptText context
            , harnessUserPrompt = experimentUserPromptText context
            , harnessInitialHistorySuffix = workspaceContextHistory
            , harnessTools =
                filter ((/= "set_preload_plan") . toolName) (experimentToolsForRun context)
            , harnessMaxTurns = 64
            , harnessEventSink = experimentEventSink context
            , harnessWorkflowSpec = experimentWorkflowSpec context
            , harnessRequiredSubgoal = Nothing
            }
    CodexAgentRunner -> do
      workspaceRoot <- normalise <$> getCurrentDirectory
      preloaded <-
        preloadGoalContextForWorkspace
          context
          Nothing
          workspaceRoot
          (experimentUserPromptText context)
      let promptWithPreload =
            preloadTextPrompt preloaded (experimentUserPromptText context)
      result <-
        runCodexProcessWithControlRoot
          (experimentCodexProcessConfig context)
          (experimentEventSink context)
          Nothing
          workspaceRoot
          (experimentControlRoot context </> "single")
          (codexPrompt context promptWithPreload)
      when (codexProcessExitCode result /= 0) $
        fail
          ("codex process failed with exit code " <> show (codexProcessExitCode result))
    PiAgentRunner -> do
      workspaceRoot <- normalise <$> getCurrentDirectory
      let piConfig =
            (experimentPiProcessConfig context)
              { piProcessModel =
                  Just (requestModel (experimentRequestTemplate context))
              }
      result <-
        runPiSdkProcess
          piConfig
          (experimentEventSink context)
          Nothing
          workspaceRoot
          (experimentControlRoot context </> "single")
          (experimentUserPromptText context)
          []
      when (piProcessExitCode result /= 0) $
        fail ("pi process failed with exit code " <> show (piProcessExitCode result))
  putStrLn ("Trace written to " <> experimentTracePath context)

runSerialPromptWithGraph :: ExperimentContext -> CompiledGoalGraph -> IO ()
runSerialPromptWithGraph context compiledGraph = do
  let goalGraph = compiledGraphToGoalGraph compiledGraph
  summariesRef <- newSummaries
  historiesRef <- newCodexHistories
  harnessHistoriesRef <- newGoalHistories
  result <-
    runSerialScheduler
      SerialScheduler
        { serialSchedulerRunGoal =
            runSerialGoal
              context
              goalGraph
              summariesRef
              historiesRef
              harnessHistoriesRef
        }
      goalGraph
  case result of
    Left err -> fail ("serial scheduler failed: " <> Text.unpack err)
    Right schedulerResult -> do
      putStrLn
        ( "Serial goals completed: "
            <> show
              ( fmap
                  (Text.unpack . unGoalNodeId)
                  (serialSchedulerRunOrder schedulerResult)
              )
        )
      putStrLn ("Trace written to " <> experimentTracePath context)

runConcurrentPromptWithGraph :: ExperimentContext -> CompiledGoalGraph -> IO ()
runConcurrentPromptWithGraph context compiledGraph = do
  requireConcurrentWorkspaceRemap
  incrementalPlanner <- loadIncrementalPlanner
  let
    originalGoalGraph = compiledGraphToGoalGraph compiledGraph
    goalGraph =
      if incrementalPlanner
        then detachPlannerEdges "G000" originalGoalGraph
        else originalGoalGraph
    chaseConfig = configConcurrentChase (experimentConfig context)
  workspaceRoot <- normalise <$> getCurrentDirectory
  recordDagSnapshot
    context
    "concurrent_initial"
    (Just "compiled goal graph before scheduling")
    (initialChaseState goalGraph)
  summariesRef <- newSummaries
  acceptedHistoriesRef <- newCodexHistories
  pendingHistoriesRef <- newCodexHistories
  harnessHistoriesRef <- newGoalHistories
  runsRef <- newIORef Map.empty
  acceptedEffectsRef <- newIORef []
  acceptedGenerationRef <- newIORef 0
  runBaseGenerationsRef <- newIORef Map.empty
  result <-
    ( if incrementalPlanner
        then
          runConcurrentChaseWithPlanner
            ConcurrentChaseRunner
              { concurrentChaseMaxParallelism = concurrentChaseConfigMaxParallelism chaseConfig
              , concurrentChaseMaxReplans = concurrentChaseConfigMaxReplans chaseConfig
              , concurrentChaseRunGoal =
                  runConcurrentGoal
                    context
                    goalGraph
                    workspaceRoot
                    summariesRef
                    acceptedHistoriesRef
                    pendingHistoriesRef
                    harnessHistoriesRef
                    acceptedGenerationRef
                    runBaseGenerationsRef
                    runsRef
              , concurrentChaseMergeGoal =
                  mergeConcurrentGoal
                    context
                    goalGraph
                    workspaceRoot
                    summariesRef
                    acceptedHistoriesRef
                    pendingHistoriesRef
                    acceptedEffectsRef
                    acceptedGenerationRef
                    runBaseGenerationsRef
              }
            goalGraph
            (GoalNodeId "G000")
            (goalPlanReady context)
            (resolveGoalFromPlanner context summariesRef runsRef)
        else
          runConcurrentChase
            ConcurrentChaseRunner
              { concurrentChaseMaxParallelism =
                  concurrentChaseConfigMaxParallelism chaseConfig
              , concurrentChaseMaxReplans =
                  concurrentChaseConfigMaxReplans chaseConfig
              , concurrentChaseRunGoal =
                  runConcurrentGoal
                    context
                    goalGraph
                    workspaceRoot
                    summariesRef
                    acceptedHistoriesRef
                    pendingHistoriesRef
                    harnessHistoriesRef
                    acceptedGenerationRef
                    runBaseGenerationsRef
                    runsRef
              , concurrentChaseMergeGoal =
                  mergeConcurrentGoal
                    context
                    goalGraph
                    workspaceRoot
                    summariesRef
                    acceptedHistoriesRef
                    pendingHistoriesRef
                    acceptedEffectsRef
                    acceptedGenerationRef
                    runBaseGenerationsRef
              }
            goalGraph
    )
  case result of
    Left err -> fail ("concurrent scheduler failed: " <> Text.unpack err)
    Right schedulerResult -> do
      putStrLn
        ( "Concurrent goals completed: "
            <> show
              ( fmap
                  (Text.unpack . unGoalNodeId)
                  (Map.keys (concurrentChaseCompleted schedulerResult))
              )
        )
      putStrLn ("Trace written to " <> experimentTracePath context)

loadIncrementalPlanner :: IO Bool
loadIncrementalPlanner = do
  value <- lookupEnv "SOG_INCREMENTAL_PLANNER"
  pure (value `elem` [Just "1", Just "true", Just "yes"])

detachPlannerEdges :: Text -> GoalGraph -> GoalGraph
detachPlannerEdges plannerId graph =
  graph
    { goalGraphEdges =
        Set.filter
          (\(from, _to) -> unGoalNodeId from /= plannerId)
          (goalGraphEdges graph)
    }

goalPlanReady :: ExperimentContext -> GoalNodeId -> IO Bool
goalPlanReady context goalId
  | unGoalNodeId goalId == "G000" = pure True
  | otherwise = do
      dynamicPlan <- readIORef (experimentDynamicGoalContextPreloadPlan context)
      let planPath = experimentControlRoot context </> "predicted-actions-plan.json"
      predictedReady <-
        planContainsGoal planPath (experimentPredictedActionsPlan context) goalId
      preloadReady <- goalPreloadPlanContainsGoal context goalId
      let dynamicReady =
            case dynamicPlan of
              GoalContextPreloadPlan goals -> Map.member (unGoalNodeId goalId) goals
      pure (predictedReady || preloadReady || dynamicReady)

planContainsGoal :: FilePath -> PredictedActionsPlan -> GoalNodeId -> IO Bool
planContainsGoal path fallback goalId = do
  exists <- doesFileExist path
  plan <-
    if exists
      then either (const (pure fallback)) pure =<< readPredictedActionsPlanFile path
      else pure fallback
  pure (Map.member (unGoalNodeId goalId) (predictedActionsPlanGoals plan))

goalPreloadPlanContainsGoal :: ExperimentContext -> GoalNodeId -> IO Bool
goalPreloadPlanContainsGoal context goalId = do
  let path = experimentControlRoot context </> "preload-plan.json"
  exists <- doesFileExist path
  if not exists
    then pure False
    else do
      result <- readGoalContextPreloadPlanFile path
      pure $ case result of
        Left _ -> False
        Right (GoalContextPreloadPlan goals) ->
          Map.member (unGoalNodeId goalId) goals

requireConcurrentWorkspaceRemap :: IO ()
requireConcurrentWorkspaceRemap = do
  maybeSandbox <- lookupEnv "SOG_SANDBOX"
  maybeBwrap <- lookupEnv "SOG_BWRAP"
  maybeAgentRunner <- lookupEnv "SOG_AGENT_RUNNER"
  let
    hasBwrap = maybeSandbox == Just "bwrap" || maybe False (not . null) maybeBwrap
    usesCodexRunner = maybeAgentRunner == Just "codex"
  unless hasBwrap $
    unless usesCodexRunner $
      fail
        "concurrent scheduler requires SOG_SANDBOX=bwrap, SOG_BWRAP, or SOG_AGENT_RUNNER=codex so each goal workspace can be remapped to /workspace"

loadCompiledGoalGraph :: FilePath -> IO CompiledGoalGraph
loadCompiledGoalGraph path = do
  decoded <- eitherDecode <$> LazyByteString.readFile path
  case decoded of
    Left err -> fail ("could not parse SOG_SERIAL_GOALS: " <> err)
    Right graph -> validateLoadedCompiledGoalGraph "SOG_SERIAL_GOALS" graph

parseCompiledGoalGraphText :: String -> IO CompiledGoalGraph
parseCompiledGoalGraphText text =
  case eitherDecode
    (LazyByteString.fromStrict (TextEncoding.encodeUtf8 (Text.pack text))) of
    Left err -> fail ("could not parse SOG_SERIAL_GOALS_TEXT: " <> err)
    Right graph -> validateLoadedCompiledGoalGraph "SOG_SERIAL_GOALS_TEXT" graph

validateLoadedCompiledGoalGraph
  :: String -> CompiledGoalGraph -> IO CompiledGoalGraph
validateLoadedCompiledGoalGraph source graph =
  case validateLoadedCompiledGoalGraphPure graph of
    [] -> pure graph
    errors ->
      fail
        ( "invalid "
            <> source
            <> ": "
            <> Text.unpack (Text.intercalate "; " errors)
        )

validateLoadedCompiledGoalGraphPure :: CompiledGoalGraph -> [Text]
validateLoadedCompiledGoalGraphPure = validateCompiledGoalGraph

loadAgentRunnerMode :: IO AgentRunnerMode
loadAgentRunnerMode = do
  maybeRunner <- lookupEnv "SOG_AGENT_RUNNER"
  case fmap Text.toLower (Text.pack <$> maybeRunner) of
    Nothing -> pure HarnessAgentRunner
    Just "" -> pure HarnessAgentRunner
    Just "harness" -> pure HarnessAgentRunner
    Just "api" -> pure HarnessAgentRunner
    Just "codex" -> pure CodexAgentRunner
    Just "pi" -> pure PiAgentRunner
    Just other -> fail ("unknown SOG_AGENT_RUNNER: " <> Text.unpack other)

runSerialGoal
  :: ExperimentContext
  -> GoalGraph
  -> Summaries
  -> CodexHistories
  -> GoalHistories
  -> GoalNode
  -> IO (Either Text AgentRunResult)
runSerialGoal context goalGraph summaries histories harnessHistories node = do
  recordGraphSnapshot
    context
    "serial_goal_enter"
    (Just ("enter " <> unGoalNodeId (goalNodeId node)))
    goalGraph
  predecessorSummaries <-
    summariesFor summaries (goalPredecessors goalGraph (goalNodeId node))
  predecessorHistories <-
    historiesFor context goalGraph histories (goalNodeId node)
  predecessorHarnessHistory <-
    harnessHistoryFor context goalGraph harnessHistories (goalNodeId node)
  let prompt =
        serialGoalPrompt
          (experimentUserPromptText context)
          goalGraph
          (experimentHarnessHistoryHandoff context)
          predecessorSummaries
          predecessorHistories
          node
  case experimentAgentRunner context of
    HarnessAgentRunner ->
      runSerialHarnessGoal context goalGraph summaries harnessHistories node prompt
    CodexAgentRunner ->
      runSerialCodexGoal context summaries histories node prompt
    PiAgentRunner ->
      runSerialPiGoal context summaries node prompt predecessorHarnessHistory

runSerialPiGoal
  :: ExperimentContext
  -> Summaries
  -> GoalNode
  -> Text
  -> [LLMInputItem]
  -> IO (Either Text AgentRunResult)
runSerialPiGoal context summaries node prompt predecessorHistories = do
  workspaceRoot <- normalise <$> getCurrentDirectory
  preloaded <-
    preloadGoalContextForWorkspace
      context
      (Just (goalNodeId node))
      workspaceRoot
      prompt
  let
    initialHistory = predecessorHistories <> preloadedGoalContextHistory preloaded
    controlRoot =
      experimentControlRoot context
        </> "serial"
        </> Text.unpack (unGoalNodeId (goalNodeId node))
        </> "pi-control"
  result <-
    case piProcessSdkRunner (experimentPiProcessConfig context) of
      Just _ ->
        runPiSdkProcess
          (experimentPiProcessConfig context)
          (experimentEventSink context)
          (Just (unGoalNodeId (goalNodeId node)))
          workspaceRoot
          controlRoot
          (piPrompt context prompt)
          initialHistory
      Nothing -> runPiGoalProcess context workspaceRoot node prompt
  let
    status = piGoalStatus result
    summary = piGoalSummary node result
    agentResult =
      AgentRunResult
        { agentRunResultGoal = goalNodeId node
        , agentRunResultStatus = status
        , agentRunResultSummaryForDependents = summary
        , agentRunResultReads = preloadedGoalContextReads preloaded
        , agentRunResultWrites = Set.empty
        , agentRunResultSnapshot = SnapshotId (unGoalNodeId (goalNodeId node))
        }
  if serialGoalStatusIsTerminal status
    then do
      rememberSummary summaries (goalNodeId node) summary
      pure (Right agentResult)
    else pure (Left ("serial pi goal failed: " <> status))

runSerialHarnessGoal
  :: ExperimentContext
  -> GoalGraph
  -> Summaries
  -> GoalHistories
  -> GoalNode
  -> Text
  -> IO (Either Text AgentRunResult)
runSerialHarnessGoal context goalGraph summaries harnessHistories node prompt = do
  workspaceRoot <- normalise <$> getCurrentDirectory
  preloaded <-
    preloadGoalContextForWorkspace
      context
      (Just (goalNodeId node))
      workspaceRoot
      prompt
  handoffHistory <-
    harnessHistoryFor context goalGraph harnessHistories (goalNodeId node)
  let initialSuffix =
        workspaceContextHistory
          <> handoffHistory
          <> preloadedGoalContextHistory preloaded
  state <-
    runHarness
      HarnessConfig
        { harnessProvider = experimentBackend context
        , harnessRequestTemplate = experimentRequestTemplate context
        , harnessSystemPrompt = experimentSystemPromptText context
        , harnessUserPrompt = prompt
        , harnessInitialHistorySuffix = initialSuffix
        , harnessTools = experimentToolsForRun context
        , harnessMaxTurns = 32
        , harnessEventSink = experimentEventSink context
        , harnessWorkflowSpec = experimentWorkflowSpec context
        , harnessRequiredSubgoal =
            Just (unGoalNodeId (goalNodeId node), goalNodeName node)
        }
  let
    status = serialGoalStatus node state
    summary = serialGoalSummary node status state
    result =
      AgentRunResult
        { agentRunResultGoal = goalNodeId node
        , agentRunResultStatus = status
        , agentRunResultSummaryForDependents = summary
        , agentRunResultReads = preloadedGoalContextReads preloaded
        , agentRunResultWrites = Set.empty
        , agentRunResultSnapshot = SnapshotId (unGoalNodeId (goalNodeId node))
        }
  if serialGoalStatusIsTerminal status
    then do
      rememberSummary summaries (goalNodeId node) summary
      rememberGoalHistory
        harnessHistories
        (goalNodeId node)
        (ownHistoryAfterInitialItems (2 + length initialSuffix) (harnessHistory state))
      pure (Right result)
    else
      pure
        ( Left
            ( "serial goal "
                <> unGoalNodeId (goalNodeId node)
                <> " did not complete successfully: "
                <> status
            )
        )

runSerialCodexGoal
  :: ExperimentContext
  -> Summaries
  -> CodexHistories
  -> GoalNode
  -> Text
  -> IO (Either Text AgentRunResult)
runSerialCodexGoal context summaries histories node prompt = do
  workspaceRoot <- normalise <$> getCurrentDirectory
  let
    beforeWorkspace =
      experimentControlRoot context
        </> "serial"
        </> Text.unpack (unGoalNodeId (goalNodeId node))
        </> "before"
    controlRoot =
      experimentControlRoot context
        </> "serial"
        </> Text.unpack (unGoalNodeId (goalNodeId node))
        </> "control"
  resetDirectory beforeWorkspace
  copyWorkspaceTree workspaceRoot beforeWorkspace
  preloaded <-
    preloadGoalContextForWorkspace
      context
      (Just (goalNodeId node))
      workspaceRoot
      prompt
  let promptWithPreload = preloadTextPrompt preloaded prompt
  codexResult <-
    runCodexGoalProcessWithControlRoot
      context
      workspaceRoot
      controlRoot
      node
      promptWithPreload
  changedPaths <- workspaceChangedPaths beforeWorkspace workspaceRoot
  let
    status = codexGoalStatus codexResult
    summary = codexGoalSummary node codexResult
    result =
      AgentRunResult
        { agentRunResultGoal = goalNodeId node
        , agentRunResultStatus = status
        , agentRunResultSummaryForDependents = summary
        , agentRunResultReads = preloadedGoalContextReads preloaded
        , agentRunResultWrites = Set.fromList changedPaths
        , agentRunResultSnapshot = SnapshotId (unGoalNodeId (goalNodeId node))
        }
  if serialGoalStatusIsTerminal status
    then do
      rememberSummary summaries (goalNodeId node) summary
      rememberCodexHistory
        histories
        (goalNodeId node)
        (codexProcessStdout codexResult)
      pure (Right result)
    else
      pure
        ( Left
            ( "serial codex goal "
                <> unGoalNodeId (goalNodeId node)
                <> " failed: "
                <> status
            )
        )

runCodexGoalProcessWithControlRoot
  :: ExperimentContext
  -> FilePath
  -> FilePath
  -> GoalNode
  -> Text
  -> IO CodexProcessResult
runCodexGoalProcessWithControlRoot context workspaceRoot controlRoot node prompt = do
  experimentEventSink context $
    SubgoalStarted
      { eventSubgoalId = unGoalNodeId (goalNodeId node)
      , eventSubgoalName = goalNodeName node
      }
  result <-
    runCodexProcessWithControlRoot
      (experimentCodexProcessConfig context)
      (experimentEventSink context)
      (Just (unGoalNodeId (goalNodeId node)))
      workspaceRoot
      controlRoot
      (codexPrompt context prompt)
  experimentEventSink context $
    SubgoalEnded
      { eventSubgoalId = unGoalNodeId (goalNodeId node)
      , eventStatus = codexGoalStatus result
      , eventSummary = Just (codexGoalSummary node result)
      }
  recordDynamicPreloadPlanFromControlRoot context controlRoot
  pure result

runPiGoalProcess
  :: ExperimentContext
  -> FilePath
  -> GoalNode
  -> Text
  -> IO PiProcessResult
runPiGoalProcess context workspaceRoot node prompt = do
  experimentEventSink context $
    SubgoalStarted
      { eventSubgoalId = unGoalNodeId (goalNodeId node)
      , eventSubgoalName = goalNodeName node
      }
  result <-
    runPiProcess
      (experimentPiProcessConfig context)
      (experimentEventSink context)
      (Just (unGoalNodeId (goalNodeId node)))
      workspaceRoot
      (piPrompt context prompt)
  let status = piGoalStatus result
  experimentEventSink context $
    SubgoalEnded
      { eventSubgoalId = unGoalNodeId (goalNodeId node)
      , eventStatus = status
      , eventSummary = Just (piGoalSummary node result)
      }
  pure result

piPrompt :: ExperimentContext -> Text -> Text
piPrompt context prompt =
  let base =
        Text.replace
          "{{task_prompt}}"
          prompt
          ( Text.replace
              "{{system_prompt}}"
              (experimentSystemPromptText context)
              $(embedTextFile "lib/Agent/SeaOfGoals/Prompts/pi-goal-prompt.txt")
          )
   in if "Goal id: G000" `Text.isInfixOf` prompt
        then
          base
            <> "\n\nYou are the single G000 planner. Publish each later goal's file plan and predicted read-only action plan separately, in serial workflow order, as soon as that goal's plan is ready. Independent goals whose plans are ready together may be published as separate planner tool calls in the same model response. Continue planning later goals while the scheduler may execute already-published goals. Do not wait until the end to publish one aggregate plan, and do not publish a plan for a later goal before the earlier goal's plan."
        else base

piGoalStatus :: PiProcessResult -> Text
piGoalStatus result
  | Just (status, _) <- piEndGoalResult result = status
  | piProcessTimedOut result = "timeout"
  | piProcessExitCode result == 0 = "success"
  | otherwise = "failed"

piGoalSummary :: GoalNode -> PiProcessResult -> Text
piGoalSummary node result =
  case piEndGoalResult result of
    Just (_, summary) -> summary
    Nothing ->
      Text.intercalate
        " "
        [ "Goal"
        , unGoalNodeId (goalNodeId node)
        , "finished with status"
        , piGoalStatus result <> "."
        ]

piEndGoalResult :: PiProcessResult -> Maybe (Text, Text)
piEndGoalResult result =
  listToMaybe
    [ (status, summary)
    | line <- Text.lines (piProcessStdout result)
    , Right (Aeson.Object event) <-
        [Aeson.eitherDecodeStrict (TextEncoding.encodeUtf8 line)]
    , Just (Aeson.Object rawEvent) <-
        [AesonKeyMap.lookup (AesonKey.fromString "raw_event") event]
    , Just (Aeson.String "tool_execution_end") <-
        [AesonKeyMap.lookup (AesonKey.fromString "type") rawEvent]
    , Just (Aeson.String "end_goal") <-
        [AesonKeyMap.lookup (AesonKey.fromString "toolName") rawEvent]
    , Just (Aeson.Object toolResult) <-
        [AesonKeyMap.lookup (AesonKey.fromString "result") rawEvent]
    , Just (Aeson.Object details) <-
        [AesonKeyMap.lookup (AesonKey.fromString "details") toolResult]
    , Just (Aeson.String status) <-
        [AesonKeyMap.lookup (AesonKey.fromString "status") details]
    , Just (Aeson.String summary) <-
        [AesonKeyMap.lookup (AesonKey.fromString "summary") details]
    ]

codexPrompt :: ExperimentContext -> Text -> Text
codexPrompt context prompt =
  Text.replace
    "{{task_prompt}}"
    prompt
    ( Text.replace
        "{{system_prompt}}"
        (experimentSystemPromptText context)
        $(embedTextFile "lib/Agent/SeaOfGoals/Prompts/codex-goal-prompt.txt")
    )

preloadGoalContextForWorkspace
  :: ExperimentContext
  -> Maybe GoalNodeId
  -> FilePath
  -> Text
  -> IO PreloadedGoalContext
preloadGoalContextForWorkspace context maybeGoalId workspaceRoot prompt = do
  if isPlannerGoal maybeGoalId || historyHandoffReplacesPreload context
    then pure emptyPreloadedGoalContext
    else do
      dynamicPlan <- readIORef (experimentDynamicGoalContextPreloadPlan context)
      let
        GoalContextPreloadPlan plan =
          mergeGoalContextPreloadPlans
            (experimentGoalContextPreloadPlan context)
            dynamicPlan
        plannedFiles =
          maybeGoalId >>= \goalId -> Map.lookup (unGoalNodeId goalId) plan
      preloaded <-
        preloadGoalContextWithPlanDetailed
          (experimentGoalContextPreloadConfig context)
          plannedFiles
          workspaceRoot
          prompt
      predictedFileExists <-
        doesFileExist (experimentControlRoot context </> "predicted-actions-plan.json")
      predictedFilePlan <-
        if predictedFileExists
          then
            either (fail . ("invalid predicted actions plan: " <>)) pure
              =<< readPredictedActionsPlanFile
                (experimentControlRoot context </> "predicted-actions-plan.json")
          else pure (PredictedActionsPlan Map.empty)
      let
        predictedPlan =
          mergePredictedActionsPlans
            (experimentPredictedActionsPlan context)
            predictedFilePlan
        predicted =
          maybeGoalId >>= \goalId ->
            Map.lookup
              (unGoalNodeId goalId)
              (predictedActionsPlanGoals predictedPlan)
      predictedHistory <- runPredictedActions predicted workspaceRoot
      pure
        preloaded
          { preloadedGoalContextHistory =
              preloadedGoalContextHistory preloaded <> predictedHistory
          }

isPlannerGoal :: Maybe GoalNodeId -> Bool
isPlannerGoal = maybe False ((== "G000") . unGoalNodeId)

historyHandoffReplacesPreload :: ExperimentContext -> Bool
historyHandoffReplacesPreload context =
  experimentAgentRunner context == HarnessAgentRunner
    && experimentHarnessHistoryHandoff context

emptyPreloadedGoalContext :: PreloadedGoalContext
emptyPreloadedGoalContext =
  PreloadedGoalContext
    { preloadedGoalContextText = ""
    , preloadedGoalContextHistory = []
    , preloadedGoalContextReads = Set.empty
    }

preloadTextPrompt :: PreloadedGoalContext -> Text -> Text
preloadTextPrompt preloaded prompt =
  Text.intercalate
    "\n\n"
    (filter (not . Text.null) [preloadedGoalContextText preloaded, prompt])

recordDynamicPreloadPlanFromControlRoot
  :: ExperimentContext -> FilePath -> IO ()
recordDynamicPreloadPlanFromControlRoot context controlRoot = do
  let planPath = controlRoot </> "preload-plan.json"
  exists <- doesFileExist planPath
  when exists $ do
    parsed <- readGoalContextPreloadPlanFile planPath
    case parsed of
      Left err ->
        experimentEventSink context $
          EffectRecorded
            { eventEffect =
                EffectRecord
                  { effectKind = "preload_plan_parse_error"
                  , effectResource = Text.pack planPath
                  , effectDetail = Just (Text.pack err)
                  }
            , eventActiveSubgoal = Nothing
            }
      Right plan ->
        modifyIORef'
          (experimentDynamicGoalContextPreloadPlan context)
          (`mergeGoalContextPreloadPlans` plan)

recordPiPlanPublication
  :: ExperimentContext -> FilePath -> HarnessEvent -> IO ()
recordPiPlanPublication context controlRoot event =
  case event of
    ToolResultObserved{eventToolName = "set_preload_plan", eventResult = result} ->
      case Text.stripPrefix "SOG_PRELOAD_PLAN:" (piToolResultText result) of
        Nothing -> pure ()
        Just planText ->
          case eitherDecode
            (LazyByteString.fromStrict (TextEncoding.encodeUtf8 (Text.strip planText))) of
            Left _ -> pure ()
            Right plan ->
              do
                modifyIORef'
                  (experimentDynamicGoalContextPreloadPlan context)
                  (`mergeGoalContextPreloadPlans` plan)
                experimentEventSink
                  context
                  EffectRecorded
                    { eventEffect =
                        EffectRecord
                          { effectKind = "preload_plan_published"
                          , effectResource = "runtime"
                          , effectDetail =
                              Just (Text.intercalate "," (Map.keys (goalContextPreloadPlanGoals plan)))
                          }
                    , eventActiveSubgoal = Nothing
                    }
    ToolResultObserved
      { eventToolName = "set_predicted_actions_plan"
      , eventResult = result
      } ->
        case Text.stripPrefix "SOG_PREDICTED_ACTIONS_PLAN:" (piToolResultText result) of
          Nothing -> pure ()
          Just planText -> do
            let path = controlRoot </> "predicted-actions-plan.json"
            exists <- doesFileExist path
            old <-
              if exists
                then
                  either (const (pure (PredictedActionsPlan Map.empty))) pure
                    =<< readPredictedActionsPlanFile path
                else pure (PredictedActionsPlan Map.empty)
            case eitherDecode
              (LazyByteString.fromStrict (TextEncoding.encodeUtf8 (Text.strip planText))) of
              Left _ -> pure ()
              Right plan -> do
                createDirectoryIfMissing True controlRoot
                LazyByteString.writeFile path (encode (mergePredictedActionsPlans old plan))
                experimentEventSink
                  context
                  EffectRecorded
                    { eventEffect =
                        EffectRecord
                          { effectKind = "predicted_actions_plan_published"
                          , effectResource = Text.pack path
                          , effectDetail =
                              Just (Text.intercalate "," (Map.keys (predictedActionsPlanGoals plan)))
                          }
                    , eventActiveSubgoal = Nothing
                    }
    ToolResultObserved
      { eventToolName = "set_goal_resolution"
      , eventResult = result
      } ->
        case Text.stripPrefix "SOG_GOAL_RESOLUTION:" (piToolResultText result) of
          Nothing -> pure ()
          Just resolutionText ->
            case PlannerResolution.decodeResolution (Text.strip resolutionText) of
              Left err ->
                experimentEventSink context $
                  EffectRecorded
                    { eventEffect =
                        EffectRecord
                          { effectKind = "planner_resolution_parse_error"
                          , effectResource = "runtime"
                          , effectDetail = Just (Text.pack err)
                          }
                    , eventActiveSubgoal = Just "G000"
                    }
              Right resolution
                | PlannerResolution.resolutionGoalId resolution == "G000" ->
                    experimentEventSink context $
                      EffectRecorded
                        { eventEffect =
                            EffectRecord
                              { effectKind = "planner_resolution_rejected"
                              , effectResource = "G000"
                              , effectDetail = Just "the planner cannot resolve itself"
                              }
                        , eventActiveSubgoal = Just "G000"
                        }
                | otherwise -> do
                    let goalId = GoalNodeId (PlannerResolution.resolutionGoalId resolution)
                    modifyIORef'
                      (experimentPlannerResolutions context)
                      (Map.insert goalId resolution)
    _ -> pure ()

resolveGoalFromPlanner
  :: ExperimentContext
  -> Summaries
  -> IORef (Map GoalNodeId Int)
  -> GoalNode
  -> IO (Maybe AgentRunResult)
resolveGoalFromPlanner context summaries runs node = do
  runCounts <- readIORef runs
  if Map.member (goalNodeId node) runCounts
    then do
      modifyIORef'
        (experimentPlannerResolutions context)
        (Map.delete (goalNodeId node))
      pure Nothing
    else do
      resolution <-
        atomicModifyIORef'
          (experimentPlannerResolutions context)
          ( \resolutions ->
              ( Map.delete (goalNodeId node) resolutions
              , Map.lookup (goalNodeId node) resolutions
              )
          )
      traverse applyResolution resolution
 where
  applyResolution resolution = do
    let
      resolutionContext = PlannerResolution.resolutionContext resolution
      resolutionKind = plannerResolutionKindText (PlannerResolution.resolutionKind resolution)
    rememberSummary summaries (goalNodeId node) resolutionContext
    experimentEventSink context $
      PlannerGoalResolved
        { eventResolvedGoalId = unGoalNodeId (goalNodeId node)
        , eventResolutionKind = resolutionKind
        , eventResolutionContext = resolutionContext
        }
    pure
      AgentRunResult
        { agentRunResultGoal = goalNodeId node
        , agentRunResultStatus = "success"
        , agentRunResultSummaryForDependents = resolutionContext
        , agentRunResultReads = Set.empty
        , agentRunResultWrites = Set.empty
        , agentRunResultSnapshot =
            SnapshotId ("planner-resolution:" <> unGoalNodeId (goalNodeId node))
        }

plannerResolutionKindText :: PlannerResolution.Kind -> Text
plannerResolutionKindText PlannerResolution.CompletedByPlanner = "completed_by_planner"
plannerResolutionKindText PlannerResolution.NoAction = "no_action"

piToolResultText :: Text -> Text
piToolResultText result =
  case eitherDecode (LazyByteString.fromStrict (TextEncoding.encodeUtf8 result)) of
    Right (Aeson.Object objectValue) ->
      case AesonKeyMap.lookup (AesonKey.fromString "content") objectValue of
        Just (Aeson.Array content) ->
          case [ text
               | Aeson.Object part <- Vector.toList content
               , Just (Aeson.String text) <-
                   [AesonKeyMap.lookup (AesonKey.fromString "text") part]
               ] of
            text : _ -> text
            [] -> result
        _ -> result
    _ -> result

codexGoalStatus :: CodexProcessResult -> Text
codexGoalStatus result
  | codexProcessTimedOut result = "timeout"
  | codexProcessExitCode result == 0 = "success"
  | otherwise = "failed"

codexGoalSummary :: GoalNode -> CodexProcessResult -> Text
codexGoalSummary node result
  | not (Text.null (Text.strip (codexProcessLastMessage result))) =
      Text.strip (codexProcessLastMessage result)
  | otherwise =
      Text.intercalate
        " "
        [ "Goal"
        , unGoalNodeId (goalNodeId node)
        , "finished with status"
        , codexGoalStatus result <> "."
        ]

runConcurrentGoal
  :: ExperimentContext
  -> GoalGraph
  -> FilePath
  -> Summaries
  -> CodexHistories
  -> CodexHistories
  -> GoalHistories
  -> IORef Int
  -> IORef (Map GoalNodeId Int)
  -> IORef (Map GoalNodeId Int)
  -> GoalNode
  -> IO (Either Text AgentRunResult)
runConcurrentGoal
  context
  goalGraph
  baseWorkspace
  summaries
  histories
  pendingHistories
  harnessHistories
  acceptedGenerationRef
  runBaseGenerationsRef
  runsRef
  node = do
    recordGraphSnapshot
      context
      "concurrent_goal_enter"
      (Just ("enter " <> unGoalNodeId (goalNodeId node)))
      goalGraph
    runIndex <- nextGoalRunIndex runsRef (goalNodeId node)
    baseGeneration <- readIORef acceptedGenerationRef
    modifyIORef'
      runBaseGenerationsRef
      (Map.insert (goalNodeId node) baseGeneration)
    let
      runSlug =
        Text.unpack (unGoalNodeId (goalNodeId node))
          <> "-"
          <> show runIndex
      runRoot =
        experimentControlRoot context
          </> "concurrent"
          </> "goals"
          </> runSlug
      ancestorWorkspace = runRoot </> "ancestor"
      taskWorkspace =
        runRoot </> "workspace"
    predecessorSummaries <-
      summariesFor summaries (goalPredecessors goalGraph (goalNodeId node))
    predecessorHistories <-
      historiesFor context goalGraph histories (goalNodeId node)
    harnessPredecessorHistory <-
      harnessHistoryFor context goalGraph harnessHistories (goalNodeId node)
    let prompt =
          serialGoalPrompt
            (experimentUserPromptText context)
            goalGraph
            (experimentHarnessHistoryHandoff context)
            predecessorSummaries
            predecessorHistories
            node
    case experimentConcurrentWorkspaceMode context of
      CopyTreeWorkspace -> do
        resetDirectory runRoot
        copyWorkspaceTree baseWorkspace ancestorWorkspace
        copyWorkspaceTree ancestorWorkspace taskWorkspace
        tools <- experimentToolsForWorkspace context taskWorkspace
        preloaded <-
          preloadGoalContextForWorkspace
            context
            (Just (goalNodeId node))
            taskWorkspace
            prompt
        let promptWithPreload = preloadTextPrompt preloaded prompt
        case experimentAgentRunner context of
          HarnessAgentRunner ->
            runConcurrentHarnessGoal
              context
              ancestorWorkspace
              taskWorkspace
              tools
              harnessHistories
              node
              prompt
              harnessPredecessorHistory
              (preloadedGoalContextHistory preloaded)
              (preloadedGoalContextReads preloaded)
          CodexAgentRunner ->
            runConcurrentCodexGoal
              context
              pendingHistories
              (runRoot </> "control")
              ancestorWorkspace
              taskWorkspace
              node
              promptWithPreload
              (preloadedGoalContextReads preloaded)
          PiAgentRunner ->
            runConcurrentPiGoal
              context
              (runRoot </> "control")
              ancestorWorkspace
              taskWorkspace
              node
              prompt
              harnessPredecessorHistory
              (preloadedGoalContextHistory preloaded)
              (preloadedGoalContextReads preloaded)
      FuseEventWorkspace -> do
        case experimentAgentRunner context of
          HarnessAgentRunner ->
            pure
              ( Left
                  "SOG_CONCURRENT_WORKSPACE=fuse currently supports SOG_AGENT_RUNNER=codex only"
              )
          CodexAgentRunner ->
            runConcurrentCodexGoalWithFuse
              context
              pendingHistories
              baseWorkspace
              runRoot
              node
              prompt
          PiAgentRunner ->
            runConcurrentPiGoalWithFuse
              context
              baseWorkspace
              runRoot
              node
              prompt
              harnessPredecessorHistory

runConcurrentHarnessGoal
  :: ExperimentContext
  -> FilePath
  -> FilePath
  -> [ToolSpec]
  -> GoalHistories
  -> GoalNode
  -> Text
  -> [LLMInputItem]
  -> [LLMInputItem]
  -> Set FilePath
  -> IO (Either Text AgentRunResult)
runConcurrentHarnessGoal
  context
  ancestorWorkspace
  taskWorkspace
  tools
  harnessHistories
  node
  prompt
  handoffHistory
  preloadHistory
  preloadedReads = do
    let initialSuffix = workspaceContextHistory <> handoffHistory <> preloadHistory
    state <-
      runHarness
        HarnessConfig
          { harnessProvider = experimentBackend context
          , harnessRequestTemplate = experimentRequestTemplate context
          , harnessSystemPrompt = experimentSystemPromptText context
          , harnessUserPrompt = prompt
          , harnessInitialHistorySuffix = initialSuffix
          , harnessTools = tools
          , harnessMaxTurns = 32
          , harnessEventSink = experimentEventSink context
          , harnessWorkflowSpec = experimentWorkflowSpec context
          , harnessRequiredSubgoal =
              Just (unGoalNodeId (goalNodeId node), goalNodeName node)
          }
    let status = serialGoalStatus node state
    changedPaths <- workspaceChangedPaths ancestorWorkspace taskWorkspace
    let
      summary = serialGoalSummary node status state
      result =
        AgentRunResult
          { agentRunResultGoal = goalNodeId node
          , agentRunResultStatus = status
          , agentRunResultSummaryForDependents = summary
          , agentRunResultReads = preloadedReads
          , agentRunResultWrites = Set.fromList changedPaths
          , agentRunResultSnapshot =
              SnapshotId
                ( unGoalNodeId (goalNodeId node)
                    <> ":"
                    <> Text.pack taskWorkspace
                )
          }
    if serialGoalStatusIsTerminal status
      then do
        rememberGoalHistory
          harnessHistories
          (goalNodeId node)
          (ownHistoryAfterInitialItems (2 + length initialSuffix) (harnessHistory state))
        pure (Right result)
      else
        pure
          ( Left
              ( "concurrent goal "
                  <> unGoalNodeId (goalNodeId node)
                  <> " did not complete successfully: "
                  <> status
              )
          )

runConcurrentCodexGoal
  :: ExperimentContext
  -> CodexHistories
  -> FilePath
  -> FilePath
  -> FilePath
  -> GoalNode
  -> Text
  -> Set FilePath
  -> IO (Either Text AgentRunResult)
runConcurrentCodexGoal context pendingHistories controlRoot ancestorWorkspace taskWorkspace node prompt preloadedReads = do
  codexResult <-
    runCodexGoalProcessWithControlRoot context taskWorkspace controlRoot node prompt
  changedPaths <- workspaceChangedPaths ancestorWorkspace taskWorkspace
  let
    status = codexGoalStatus codexResult
    summary = codexGoalSummary node codexResult
    result =
      AgentRunResult
        { agentRunResultGoal = goalNodeId node
        , agentRunResultStatus = status
        , agentRunResultSummaryForDependents = summary
        , agentRunResultReads = preloadedReads
        , agentRunResultWrites = Set.fromList changedPaths
        , agentRunResultSnapshot =
            SnapshotId
              ( unGoalNodeId (goalNodeId node)
                  <> ":"
                  <> Text.pack taskWorkspace
              )
        }
  if serialGoalStatusIsTerminal status
    then do
      rememberCodexHistory
        pendingHistories
        (goalNodeId node)
        (codexProcessStdout codexResult)
      pure (Right result)
    else
      pure
        ( Left
            ( "concurrent codex goal "
                <> unGoalNodeId (goalNodeId node)
                <> " failed: "
                <> status
            )
        )

runConcurrentPiGoal
  :: ExperimentContext
  -> FilePath
  -> FilePath
  -> FilePath
  -> GoalNode
  -> Text
  -> [LLMInputItem]
  -> [LLMInputItem]
  -> Set FilePath
  -> IO (Either Text AgentRunResult)
runConcurrentPiGoal
  context
  controlRoot
  ancestorWorkspace
  taskWorkspace
  node
  prompt
  predecessorHistory
  preloadHistory
  preloadedReads = do
    result <-
      case piProcessSdkRunner (experimentPiProcessConfig context) of
        Just _ ->
          runPiSdkProcess
            (experimentPiProcessConfig context)
            ( \event -> do
                experimentEventSink context event
                recordPiPlanPublication context controlRoot event
            )
            (Just (unGoalNodeId (goalNodeId node)))
            taskWorkspace
            controlRoot
            (piPrompt context prompt)
            ( (if experimentPiHistoryHandoff context then predecessorHistory else [])
                <> preloadHistory
            )
        Nothing -> runPiGoalProcess context taskWorkspace node prompt
    changedPaths <- workspaceChangedPaths ancestorWorkspace taskWorkspace
    let
      status = piGoalStatus result
      summary = piGoalSummary node result
      agentResult =
        AgentRunResult
          { agentRunResultGoal = goalNodeId node
          , agentRunResultStatus = status
          , agentRunResultSummaryForDependents = summary
          , agentRunResultReads = preloadedReads
          , agentRunResultWrites = Set.fromList changedPaths
          , agentRunResultSnapshot =
              SnapshotId
                (unGoalNodeId (goalNodeId node) <> ":" <> Text.pack taskWorkspace)
          }
    if serialGoalStatusIsTerminal status
      then pure (Right agentResult)
      else pure (Left ("concurrent pi goal failed: " <> status))

runConcurrentCodexGoalWithFuse
  :: ExperimentContext
  -> CodexHistories
  -> FilePath
  -> FilePath
  -> GoalNode
  -> Text
  -> IO (Either Text AgentRunResult)
#ifdef SOG_FUSE
runConcurrentCodexGoalWithFuse context pendingHistories baseWorkspace runRoot node prompt = do
  resetDirectory runRoot
  let
    storeRoot = runRoot </> "store"
    controlRoot = runRoot </> "control"
    backend = FuseStore.Backend storeRoot
    taskId = unGoalNodeId (goalNodeId node)
  handle <-
    WorkspaceBackend.prepareWorkspace
      backend
      FuseStore.Spec
        { FuseStore.specTaskId = taskId
        , FuseStore.specBasePath = baseWorkspace
        , FuseStore.specAgentMountPath = "/workspace"
        }
  let mountValue = WorkspaceBackend.mount backend handle
  (codexResult, preloadedReads) <-
    bracket
      (mountFuseWorkspace handle mountValue)
      unmountFuseWorkspace
      ( \_ -> do
          preloaded <-
            preloadGoalContextForWorkspace
              context
              (Just (goalNodeId node))
              baseWorkspace
              prompt
          let promptWithPreload = preloadTextPrompt preloaded prompt
          result <-
            runCodexGoalProcessWithControlRoot
              context
              (WorkspaceBackend.mountHostPath mountValue)
              controlRoot
              node
              promptWithPreload
          pure (result, preloadedGoalContextReads preloaded)
      )
  accessLog <- filterWorkspaceAccesses <$> FuseStore.accessLog handle
  let
    status = codexGoalStatus codexResult
    summary = codexGoalSummary node codexResult
    result =
      AgentRunResult
        { agentRunResultGoal = goalNodeId node
        , agentRunResultStatus = status
        , agentRunResultSummaryForDependents = summary
        , agentRunResultReads =
            Set.union
              preloadedReads
              (FuseStore.readSet accessLog)
        , agentRunResultWrites = FuseStore.writeSet accessLog
        , agentRunResultSnapshot =
            SnapshotId
              ( unGoalNodeId (goalNodeId node)
                  <> ":"
                  <> Text.pack (storeRoot </> Text.unpack taskId </> "files")
              )
        }
  if serialGoalStatusIsTerminal status
    then do
      rememberCodexHistory
        pendingHistories
        (goalNodeId node)
        (codexProcessStdout codexResult)
      pure (Right result)
    else
      pure
        ( Left
            ( "concurrent codex goal "
                <> unGoalNodeId (goalNodeId node)
                <> " failed: "
                <> status
            )
        )
#else
runConcurrentCodexGoalWithFuse _ _ _ _ _ _ =
  pure (Left "SOG_CONCURRENT_WORKSPACE=fuse requires building SeaOfGoals with -f fuse")
#endif

runConcurrentPiGoalWithFuse
  :: ExperimentContext
  -> FilePath
  -> FilePath
  -> GoalNode
  -> Text
  -> [LLMInputItem]
  -> IO (Either Text AgentRunResult)
#ifdef SOG_FUSE
runConcurrentPiGoalWithFuse context baseWorkspace runRoot node prompt predecessorHistory = do
  resetDirectory runRoot
  let
    storeRoot = runRoot </> "store"
    controlRoot = runRoot </> "control"
    backend = FuseStore.Backend storeRoot
    taskId = unGoalNodeId (goalNodeId node)
  handle <-
    WorkspaceBackend.prepareWorkspace
      backend
      FuseStore.Spec
        { FuseStore.specTaskId = taskId
        , FuseStore.specBasePath = baseWorkspace
        , FuseStore.specAgentMountPath = "/workspace"
        }
  let mountValue = WorkspaceBackend.mount backend handle
  (piResult, preloadedReads) <-
    bracket
      (mountFuseWorkspace handle mountValue)
      unmountFuseWorkspace
      ( \_ -> do
          preloaded <-
            preloadGoalContextForWorkspace
              context
              (Just (goalNodeId node))
              baseWorkspace
              prompt
          result <-
            runPiSdkProcess
              (experimentPiProcessConfig context)
              ( \event -> do
                  experimentEventSink context event
                  recordPiPlanPublication context controlRoot event
              )
              (Just taskId)
              (WorkspaceBackend.mountHostPath mountValue)
              controlRoot
              (piPrompt context prompt)
              ( (if experimentPiHistoryHandoff context then predecessorHistory else [])
                  <> preloadedGoalContextHistory preloaded
              )
          pure (result, preloadedGoalContextReads preloaded)
      )
  accessLog <- filterWorkspaceAccesses <$> FuseStore.accessLog handle
  let
    status = piGoalStatus piResult
    summary = piGoalSummary node piResult
    result =
      AgentRunResult
        { agentRunResultGoal = goalNodeId node
        , agentRunResultStatus = status
        , agentRunResultSummaryForDependents = summary
        , agentRunResultReads =
            Set.union preloadedReads (FuseStore.readSet accessLog)
        , agentRunResultWrites = FuseStore.writeSet accessLog
        , agentRunResultSnapshot =
            SnapshotId
              ( taskId
                  <> ":"
                  <> Text.pack (storeRoot </> Text.unpack taskId </> "files")
              )
        }
  if serialGoalStatusIsTerminal status
    then pure (Right result)
    else pure (Left ("concurrent pi goal failed: " <> status))
#else
runConcurrentPiGoalWithFuse _ _ _ _ _ _ =
  pure (Left "SOG_CONCURRENT_WORKSPACE=fuse requires building SeaOfGoals with -f fuse")
#endif

#ifdef SOG_FUSE
filterWorkspaceAccesses :: [FuseStore.Access] -> [FuseStore.Access]
filterWorkspaceAccesses =
  filter (not . ignoredAccess)
 where
  ignoredAccess access =
    any isIgnoredPath (accessPaths access)

  accessPaths access =
    case access of
      FuseStore.ContentRead path -> [path]
      FuseStore.MetadataRead path -> [path]
      FuseStore.DirectoryRead path -> [path]
      FuseStore.FileCreated path -> [path]
      FuseStore.FileModified path -> [path]
      FuseStore.FileDeleted path -> [path]
      FuseStore.FileRenamed fromPath toPath -> [fromPath, toPath]

  isIgnoredPath path =
    case splitDirectories (normalise path) of
      ".sog" : _ -> True
      _ -> False
#endif

mergeConcurrentGoal
  :: ExperimentContext
  -> GoalGraph
  -> FilePath
  -> Summaries
  -> CodexHistories
  -> CodexHistories
  -> IORef [AcceptedEffects]
  -> IORef Int
  -> IORef (Map GoalNodeId Int)
  -> AgentRunResult
  -> IO (Either ConcurrentChaseConflict ())
mergeConcurrentGoal
  context
  goalGraph
  baseWorkspace
  summaries
  histories
  pendingHistories
  acceptedEffectsRef
  acceptedGenerationRef
  runBaseGenerationsRef
  result = do
    recordMergeGraphSnapshot context goalGraph "merge_before" result Nothing
    maybeConflict <-
      firstConcurrentConflict
        context
        baseWorkspace
        acceptedEffectsRef
        runBaseGenerationsRef
        result
    case maybeConflict of
      Just (path, formerGoal) -> do
        recordMergeGraphSnapshot
          context
          goalGraph
          "merge_conflict"
          result
          (Just ("conflict on " <> Text.pack path <> " with " <> unGoalNodeId formerGoal))
        experimentEventSink context $
          EffectRecorded
            EffectRecord
              { effectKind = "merge_conflict"
              , effectResource = Text.pack path
              , effectDetail =
                  Just
                    ( "former="
                        <> unGoalNodeId formerGoal
                        <> ", latter="
                        <> unGoalNodeId (agentRunResultGoal result)
                    )
              }
            Nothing
        pure
          ( Left
              ConcurrentChaseConflict
                { concurrentChaseConflictLeft = agentRunResultGoal result
                , concurrentChaseConflictRight = formerGoal
                , concurrentChaseConflictReason =
                    "workspace access conflict on " <> Text.pack path
                }
          )
      Nothing -> do
        regularFileWrites <- regularFileWritePaths baseWorkspace result
        applyGoalWorkspace baseWorkspace result
        rememberSummary
          summaries
          (agentRunResultGoal result)
          (agentRunResultSummaryForDependents result)
        promoteCodexHistory
          pendingHistories
          histories
          (agentRunResultGoal result)
        generation <- nextAcceptedGeneration acceptedGenerationRef
        modifyIORef'
          acceptedEffectsRef
          (acceptedEffectFromResult generation regularFileWrites result :)
        rememberMergeAccepted context result
        recordMergeGraphSnapshot context goalGraph "merge_accept" result Nothing
        pure (Right ())

recordDagSnapshot
  :: ExperimentContext -> Text -> Maybe Text -> ChaseState -> IO ()
recordDagSnapshot context phase reason state =
  experimentEventSink context $
    DagSnapshotObserved
      { eventPhase = phase
      , eventDagReason = reason
      , eventDagNodes = graphNodeIds (chaseGraph state)
      , eventDagEdges = graphEdges (chaseGraph state)
      , eventDagQueued = textGoalSet (chaseQueued state)
      , eventDagRunning = textGoalSet (chaseRunning state)
      , eventDagCompleted = textGoalSet (Map.keysSet (chaseCompleted state))
      , eventDagStatuses = chaseStatuses state
      }

recordGraphSnapshot
  :: ExperimentContext -> Text -> Maybe Text -> GoalGraph -> IO ()
recordGraphSnapshot context phase reason graph =
  experimentEventSink context $
    DagSnapshotObserved
      { eventPhase = phase
      , eventDagReason = reason
      , eventDagNodes = graphNodeIds graph
      , eventDagEdges = graphEdges graph
      , eventDagQueued = textGoalSet (Map.keysSet (goalGraphNodes graph))
      , eventDagRunning = Set.empty
      , eventDagCompleted = Set.empty
      , eventDagStatuses = Map.empty
      }

recordMergeGraphSnapshot
  :: ExperimentContext
  -> GoalGraph
  -> Text
  -> AgentRunResult
  -> Maybe Text
  -> IO ()
recordMergeGraphSnapshot context graph phase result reason =
  experimentEventSink context $
    DagSnapshotObserved
      { eventPhase = phase
      , eventDagReason =
          Just
            ( Text.intercalate
                "; "
                ( filter
                    (not . Text.null)
                    [ "goal=" <> unGoalNodeId (agentRunResultGoal result)
                    , fromMaybe "" reason
                    ]
                )
            )
      , eventDagNodes = graphNodeIds graph
      , eventDagEdges = graphEdges graph
      , eventDagQueued = Set.empty
      , eventDagRunning = Set.singleton (unGoalNodeId (agentRunResultGoal result))
      , eventDagCompleted = Set.empty
      , eventDagStatuses =
          Map.singleton (unGoalNodeId (agentRunResultGoal result)) phase
      }

graphNodeIds :: GoalGraph -> [Text]
graphNodeIds graph =
  fmap unGoalNodeId (Map.keys (goalGraphNodes graph))

graphEdges :: GoalGraph -> [(Text, Text)]
graphEdges graph =
  [ (unGoalNodeId from, unGoalNodeId to)
  | (from, to) <- Set.toList (goalGraphEdges graph)
  ]

textGoalSet :: Set GoalNodeId -> Set Text
textGoalSet =
  Set.map unGoalNodeId

chaseStatuses :: ChaseState -> Map Text Text
chaseStatuses state =
  Map.unions
    [ Map.fromSet (const "queued") (textGoalSet (chaseQueued state))
    , Map.fromSet (const "running") (textGoalSet (chaseRunning state))
    , Map.fromSet
        (const "completed")
        (textGoalSet (Map.keysSet (chaseCompleted state)))
    ]

ancestorWorkspacePath :: AgentRunResult -> FilePath
ancestorWorkspacePath result =
  takeDirectory (snapshotWorkspacePath (agentRunResultSnapshot result))
    </> "ancestor"

firstConcurrentConflict
  :: ExperimentContext
  -> FilePath
  -> IORef [AcceptedEffects]
  -> IORef (Map GoalNodeId Int)
  -> AgentRunResult
  -> IO (Maybe (FilePath, GoalNodeId))
firstConcurrentConflict context baseWorkspace acceptedEffectsRef runBaseGenerationsRef result =
  case experimentConcurrentWorkspaceMode context of
    CopyTreeWorkspace -> do
      conflictPaths <-
        workspaceMergeConflictPaths
          (ancestorWorkspacePath result)
          baseWorkspace
          (snapshotWorkspacePath (agentRunResultSnapshot result))
      acceptedEffects <- readIORef acceptedEffectsRef
      let
        preferredConflicts =
          [ (path, acceptedEffectsGoal effects)
          | path <- Set.toList conflictPaths
          , effects <- acceptedEffects
          , path `Set.member` acceptedEffectsWrites effects
          ]
        fallback =
          case Set.lookupMin conflictPaths of
            Nothing -> Nothing
            Just path -> Just (path, agentRunResultGoal result)
      pure (preferredConflicts `firstOr` fallback)
    FuseEventWorkspace -> do
      baseGenerations <- readIORef runBaseGenerationsRef
      acceptedEffects <- readIORef acceptedEffectsRef
      regularFileWrites <- regularFileWritePaths baseWorkspace result
      let
        baseGeneration =
          Map.findWithDefault 0 (agentRunResultGoal result) baseGenerations
        concurrentEffects =
          filter
            ((> baseGeneration) . acceptedEffectsGeneration)
            acceptedEffects
      pure
        ( firstAccessSetConflict
            (experimentConflictMode context)
            concurrentEffects
            regularFileWrites
            result
        )

firstAccessSetConflict
  :: ConflictMode
  -> [AcceptedEffects]
  -> Set FilePath
  -> AgentRunResult
  -> Maybe (FilePath, GoalNodeId)
firstAccessSetConflict mode accepted regularFileWrites result =
  firstOr
    [ (path, acceptedEffectsGoal effects)
    | effects <- accepted
    , path <-
        Set.toList
          ( conflictingPaths
              mode
              currentAccesses
              (acceptedAccesses effects)
          )
    ]
    Nothing
 where
  currentAccesses =
    AccessSets
      { accessReads = agentRunResultReads result
      , accessWrites = agentRunResultWrites result
      , accessRegularFileWrites = regularFileWrites
      }
  acceptedAccesses effects =
    AccessSets
      { accessReads = acceptedEffectsReads effects
      , accessWrites = acceptedEffectsWrites effects
      , accessRegularFileWrites = acceptedEffectsRegularFileWrites effects
      }

acceptedEffectFromResult
  :: Int -> Set FilePath -> AgentRunResult -> AcceptedEffects
acceptedEffectFromResult generation regularFileWrites result =
  AcceptedEffects
    { acceptedEffectsGoal = agentRunResultGoal result
    , acceptedEffectsGeneration = generation
    , acceptedEffectsReads = agentRunResultReads result
    , acceptedEffectsWrites = agentRunResultWrites result
    , acceptedEffectsRegularFileWrites = regularFileWrites
    }

regularFileWritePaths :: FilePath -> AgentRunResult -> IO (Set FilePath)
regularFileWritePaths baseWorkspace result =
  Set.fromList
    <$> filterM
      isRegularFileWrite
      (Set.toList (agentRunResultWrites result))
 where
  taskWorkspace = snapshotWorkspacePath (agentRunResultSnapshot result)
  isRegularFileWrite relativePath =
    (||)
      <$> doesFileExist (taskWorkspace </> relativePath)
      <*> doesFileExist (baseWorkspace </> relativePath)

nextAcceptedGeneration :: IORef Int -> IO Int
nextAcceptedGeneration generationRef = do
  current <- readIORef generationRef
  let next = current + 1
  writeIORef generationRef next
  pure next

firstOr :: [value] -> Maybe value -> Maybe value
firstOr (value : _) _ = Just value
firstOr [] fallback = fallback

workspaceMergeConflictPaths
  :: FilePath -> FilePath -> FilePath -> IO (Set FilePath)
workspaceMergeConflictPaths ancestorRoot baseRoot taskRoot = do
  baseChanges <- Set.fromList <$> workspaceChangedPaths ancestorRoot baseRoot
  taskChanges <- Set.fromList <$> workspaceChangedPaths ancestorRoot taskRoot
  Set.fromList
    <$> filterM
      changedToDifferentContent
      (Set.toList (Set.intersection baseChanges taskChanges))
 where
  changedToDifferentContent relativePath = do
    let
      basePath = baseRoot </> relativePath
      taskPath = taskRoot </> relativePath
    baseExists <- doesFileExist basePath
    taskExists <- doesFileExist taskPath
    case (baseExists, taskExists) of
      (False, False) -> pure False
      (True, False) -> pure True
      (False, True) -> pure True
      (True, True) -> (/=) <$> ByteString.readFile basePath <*> ByteString.readFile taskPath

applyGoalWorkspace :: FilePath -> AgentRunResult -> IO ()
applyGoalWorkspace baseWorkspace result = do
  let taskWorkspace = snapshotWorkspacePath (agentRunResultSnapshot result)
  forM_ (Set.toList (agentRunResultWrites result)) $ \relativePath -> do
    let
      source = taskWorkspace </> relativePath
      target = baseWorkspace </> relativePath
    sourceExists <- doesPathExist source
    if sourceExists
      then do
        sourceIsDirectory <- doesDirectoryExist source
        when sourceIsDirectory $
          createDirectoryIfMissing True target
        unless sourceIsDirectory $ do
          createDirectoryIfMissing True (takeDirectory target)
          ByteString.readFile source >>= ByteString.writeFile target
      else do
        targetExists <- doesPathExist target
        when targetExists $ removePathForcibly target

rememberMergeAccepted :: ExperimentContext -> AgentRunResult -> IO ()
rememberMergeAccepted context result =
  experimentEventSink context $
    EffectRecorded
      EffectRecord
        { effectKind = "merge_accept"
        , effectResource = unGoalNodeId (agentRunResultGoal result)
        , effectDetail =
            Just
              ( "writes="
                  <> Text.pack (show (Set.toList (agentRunResultWrites result)))
              )
        }
      Nothing

snapshotWorkspacePath :: SnapshotId -> FilePath
snapshotWorkspacePath snapshotId =
  case Text.splitOn ":" (unSnapshotId snapshotId) of
    _goalId : pathParts -> Text.unpack (Text.intercalate ":" pathParts)
    [] -> Text.unpack (unSnapshotId snapshotId)

nextGoalRunIndex :: IORef (Map GoalNodeId Int) -> GoalNodeId -> IO Int
nextGoalRunIndex runsRef goalId = do
  runs <- readIORef runsRef
  let next = Map.findWithDefault 0 goalId runs + 1
  writeIORef runsRef (Map.insert goalId next runs)
  pure next

resetDirectory :: FilePath -> IO ()
resetDirectory path = do
  exists <- doesPathExist path
  when exists (removePathForcibly path)
  createDirectoryIfMissing True path

copyWorkspaceTree :: FilePath -> FilePath -> IO ()
copyWorkspaceTree sourceRoot targetRoot = do
  files <- listWorkspaceFiles sourceRoot
  forM_ files $ \relativePath -> do
    let
      source = sourceRoot </> relativePath
      target = targetRoot </> relativePath
    createDirectoryIfMissing True (takeDirectory target)
    ByteString.readFile source >>= ByteString.writeFile target

workspaceChangedPaths :: FilePath -> FilePath -> IO [FilePath]
workspaceChangedPaths baseRoot taskRoot = do
  baseFiles <- Set.fromList <$> listWorkspaceFiles baseRoot
  taskFiles <- Set.fromList <$> listWorkspaceFiles taskRoot
  filterM changed (Set.toList (Set.union baseFiles taskFiles))
 where
  changed relativePath = do
    let
      basePath = baseRoot </> relativePath
      taskPath = taskRoot </> relativePath
    baseExists <- doesFileExist basePath
    taskExists <- doesFileExist taskPath
    case (baseExists, taskExists) of
      (False, False) -> pure False
      (True, False) -> pure True
      (False, True) -> pure True
      (True, True) -> (/=) <$> ByteString.readFile basePath <*> ByteString.readFile taskPath

listWorkspaceFiles :: FilePath -> IO [FilePath]
listWorkspaceFiles root = go ""
 where
  go relativeDir = do
    let absoluteDir = root </> relativeDir
    exists <- doesDirectoryExist absoluteDir
    if not exists
      then pure []
      else do
        names <- listDirectory absoluteDir
        fmap concat $
          forM (filter (not . isIgnoredWorkspaceEntry relativeDir) names) $ \name -> do
            let
              relativePath =
                if null relativeDir
                  then name
                  else relativeDir </> name
              absolutePath = root </> relativePath
            isDirectory <- doesDirectoryExist absolutePath
            if isDirectory
              then go relativePath
              else do
                isFile <- doesFileExist absolutePath
                pure [relativePath | isFile]

isIgnoredWorkspaceEntry :: FilePath -> FilePath -> Bool
isIgnoredWorkspaceEntry relativeDir name =
  null relativeDir
    && ( name == ".sog"
           || name == "sog-trace.jsonl"
       )
    || any (== ".sog") (splitDirectories (relativeDir </> name))

lockedAppendEvent :: MVar () -> FilePath -> HarnessEvent -> IO ()
lockedAppendEvent lock path event =
  modifyMVar_ lock $ \() -> do
    appendEvent path event
    pure ()

serialGoalPrompt
  :: Text
  -> GoalGraph
  -> Bool
  -> [(GoalNodeId, Text)]
  -> [(GoalNodeId, Text)]
  -> GoalNode
  -> Text
serialGoalPrompt originalPrompt goalGraph _historyHandoff predecessorSummaries predecessorHistories node =
  Text.intercalate
    "\n\n"
    ( filter
        (not . Text.null)
        [ "Original task:\n" <> originalPrompt
        , renderCompiledGoalGraphForPrompt goalGraph node
        , renderedCompletedPredecessors
        , renderedHistories
        , Text.unlines
            [ "Execute exactly this compiled goal now."
            , "Goal id: " <> unGoalNodeId (goalNodeId node)
            , "Goal name: " <> goalNodeName node
            , ""
            , goalNodePrompt node
            , ""
            , "Use the current workspace and process environment as the source of truth."
            , "If a dependency service is already available through an environment variable, use that value instead of recreating the service or assuming host ports from the original skill text."
            , "Do not call docker unless this goal explicitly requires Docker and the docker command is available."
            , ""
            , "Begin the assigned work directly. When the assigned work is complete, stop; do not perform extra verification or repeat completed exploration."
            , "Do not start a different goal in this agent loop."
            ]
        ]
    )
 where
  renderedCompletedPredecessors
    | null predecessorSummaries = ""
    | otherwise =
        "Completed predecessor goals in the skill graph: "
          <> Text.intercalate ", " (fmap (unGoalNodeId . fst) predecessorSummaries)
  renderedHistories
    | null predecessorHistories = ""
    | otherwise =
        Text.intercalate
          "\n\n"
          ( "Linearized Codex histories from transitive predecessor goals:"
              : fmap renderHistory predecessorHistories
          )
  renderHistory (goalId, history) =
    Text.unlines
      [ "BEGIN CODEX HISTORY " <> unGoalNodeId goalId
      , history
      , "END CODEX HISTORY " <> unGoalNodeId goalId
      ]

renderCompiledGoalGraphForPrompt :: GoalGraph -> GoalNode -> Text
renderCompiledGoalGraphForPrompt graph currentNode =
  Text.unlines
    ( [ "Compiled goal graph:"
      , graphInstruction
      ]
        <> fmap renderNode orderedNodes
    )
 where
  currentIsPlanner =
    unGoalNodeId (goalNodeId currentNode) == "G000"
  graphInstruction
    | currentIsPlanner =
        "Use these exact goal ids, names, descriptions, prompts, and predecessor edges when planning preloaded context for this run."
    | otherwise =
        "Use these exact goal ids, names, and predecessor edges to stay inside the current goal boundary."
  orderedNodes =
    sortOn goalNodeSerialIndex (Map.elems (goalGraphNodes graph))
  predecessorIds goalId =
    [ fromId
    | (fromId, toId) <- Set.toList (goalGraphEdges graph)
    , toId == goalId
    ]
  renderNode goal =
    Text.unlines
      ( [ "- id: " <> unGoalNodeId (goalNodeId goal)
        , "  name: " <> goalNodeName goal
        , "  predecessors: " <> renderGoalIds (predecessorIds (goalNodeId goal))
        ]
          <> [ "  goal prompt: " <> goalNodePrompt goal
             | currentIsPlanner
             ]
      )
  renderGoalIds [] = "[]"
  renderGoalIds goalIds =
    "[" <> Text.intercalate ", " (fmap unGoalNodeId goalIds) <> "]"

serialGoalStatus :: GoalNode -> HarnessState -> Text
serialGoalStatus node state
  | Just (status, _) <-
      Map.lookup (unGoalNodeId (goalNodeId node)) (harnessSubgoalResults state) =
      status
  | unGoalNodeId (goalNodeId node)
      `Set.member` workflowCompletedNodes (harnessWorkflowStatus state) =
      "success"
  | unGoalNodeId (goalNodeId node)
      `Set.member` workflowSkippedNodes (harnessWorkflowStatus state) =
      "skipped"
  | unGoalNodeId (goalNodeId node)
      `Set.member` workflowFailedNodes (harnessWorkflowStatus state) =
      "failed"
  | otherwise = "finished_without_success_status"

serialGoalStatusIsTerminal :: Text -> Bool
serialGoalStatusIsTerminal status =
  status == "success" || status == "skipped"

serialGoalSummary :: GoalNode -> Text -> HarnessState -> Text
serialGoalSummary node status state =
  fromMaybe
    (goalNodeName node <> " finished with status " <> status)
    ( Map.lookup (unGoalNodeId (goalNodeId node)) (harnessSubgoalResults state)
        >>= snd
    )

type Summaries = IORef (Map GoalNodeId Text)

type CodexHistories = IORef (Map GoalNodeId Text)

newSummaries :: IO Summaries
newSummaries = newIORef Map.empty

rememberSummary :: Summaries -> GoalNodeId -> Text -> IO ()
rememberSummary summaries goalId summary =
  modifyIORef' summaries (Map.insert goalId summary)

summariesFor :: Summaries -> Set GoalNodeId -> IO [(GoalNodeId, Text)]
summariesFor summaries goalIds = do
  summaryMap <- readIORef summaries
  pure
    [ (goalId, summary)
    | goalId <- Set.toList goalIds
    , Just summary <- [Map.lookup goalId summaryMap]
    ]

newCodexHistories :: IO CodexHistories
newCodexHistories = newIORef Map.empty

rememberCodexHistory :: CodexHistories -> GoalNodeId -> Text -> IO ()
rememberCodexHistory histories goalId history =
  modifyIORef' histories (Map.insert goalId history)

promoteCodexHistory :: CodexHistories -> CodexHistories -> GoalNodeId -> IO ()
promoteCodexHistory pendingHistories acceptedHistories goalId = do
  pending <- readIORef pendingHistories
  case Map.lookup goalId pending of
    Nothing -> pure ()
    Just history -> rememberCodexHistory acceptedHistories goalId history

historiesFor
  :: ExperimentContext
  -> GoalGraph
  -> CodexHistories
  -> GoalNodeId
  -> IO [(GoalNodeId, Text)]
historiesFor context graph histories goalId
  | not (experimentCodexHistoryHandoff context) = pure []
  | otherwise = do
      historyMap <- readIORef histories
      pure
        [ (predecessor, history)
        | predecessor <- transitivePredecessorsInSerialOrder graph goalId
        , Just history <- [Map.lookup predecessor historyMap]
        ]

harnessHistoryFor
  :: ExperimentContext
  -> GoalGraph
  -> GoalHistories
  -> GoalNodeId
  -> IO [LLMInputItem]
harnessHistoryFor context graph histories goalId
  | not (experimentHarnessHistoryHandoff context) = pure []
  | otherwise = historiesForGoal graph histories goalId

transitivePredecessorsInSerialOrder :: GoalGraph -> GoalNodeId -> [GoalNodeId]
transitivePredecessorsInSerialOrder graph goalId =
  sortOn goalOrder (Set.toList (go Set.empty (goalPredecessors graph goalId)))
 where
  goalOrder predecessor =
    maybe
      maxBound
      goalNodeSerialIndex
      (Map.lookup predecessor (goalGraphNodes graph))

  go seen frontier =
    case Set.minView frontier of
      Nothing -> seen
      Just (current, rest)
        | current `Set.member` seen -> go seen rest
        | otherwise ->
            go
              (Set.insert current seen)
              (rest <> goalPredecessors graph current)

loadCodexHistoryHandoff :: IO Bool
loadCodexHistoryHandoff = do
  maybeValue <- lookupEnv "SOG_CODEX_HISTORY_HANDOFF"
  pure
    ( case fmap Text.toLower (Text.pack <$> maybeValue) of
        Just "1" -> True
        Just "true" -> True
        Just "yes" -> True
        Just "on" -> True
        _ -> False
    )

loadHarnessHistoryHandoff :: IO Bool
loadHarnessHistoryHandoff = do
  maybeValue <- lookupEnv "SOG_HARNESS_HISTORY_HANDOFF"
  pure
    ( case fmap Text.toLower (Text.pack <$> maybeValue) of
        Just "1" -> True
        Just "true" -> True
        Just "yes" -> True
        Just "on" -> True
        _ -> False
    )

loadPiHistoryHandoff :: IO Bool
loadPiHistoryHandoff = do
  maybeValue <- lookupEnv "SOG_PI_HISTORY_HANDOFF"
  pure
    ( case fmap Text.toLower (Text.pack <$> maybeValue) of
        Just "1" -> True
        Just "true" -> True
        Just "yes" -> True
        Just "on" -> True
        _ -> False
    )

loadConcurrentWorkspaceMode :: IO ConcurrentWorkspaceMode
loadConcurrentWorkspaceMode = do
  maybeValue <- lookupEnv "SOG_CONCURRENT_WORKSPACE"
  case fmap Text.toLower (Text.pack <$> maybeValue) of
    Nothing -> pure CopyTreeWorkspace
    Just "" -> pure CopyTreeWorkspace
    Just "copy-tree" -> pure CopyTreeWorkspace
    Just "copy" -> pure CopyTreeWorkspace
    Just "fuse" -> pure FuseEventWorkspace
    Just other -> fail ("unknown SOG_CONCURRENT_WORKSPACE: " <> Text.unpack other)

loadHarnessLifecycleMode :: IO Bool
loadHarnessLifecycleMode = do
  maybeValue <- lookupEnv "SOG_HARNESS_LIFECYCLE"
  pure
    ( case fmap Text.toLower (Text.pack <$> maybeValue) of
        Just "0" -> False
        Just "false" -> False
        Just "no" -> False
        Just "off" -> False
        _ -> True
    )

lookupNonEmptyEnv :: String -> IO (Maybe String)
lookupNonEmptyEnv name = do
  value <- lookupEnv name
  pure $
    case value of
      Just text | not (null text) -> Just text
      _ -> Nothing

loadWorkflowSpecFromEnv :: IO (Maybe WorkflowSpec)
loadWorkflowSpecFromEnv = do
  maybePath <- lookupEnv "SOG_WORKFLOW_SPEC"
  case maybePath of
    Nothing -> pure Nothing
    Just "" -> pure Nothing
    Just path -> do
      decoded <- eitherDecode <$> LazyByteString.readFile path
      case decoded of
        Left err -> fail ("could not parse SOG_WORKFLOW_SPEC: " <> err)
        Right spec -> pure (Just spec)

loadSkillContextFromEnv :: IO Text
loadSkillContextFromEnv = do
  maybeText <- lookupEnv "SOG_SKILL_TEXT"
  maybePath <- lookupEnv "SOG_SKILL_PATH"
  skillText <-
    case (maybeText, maybePath) of
      (Just text, _) | not (null text) -> pure (Text.pack text)
      (_, Just path) | not (null path) -> TextIO.readFile path
      _ -> pure ""
  pure
    ( if Text.null skillText
        then ""
        else
          Text.replace
            "{{skill_text}}"
            skillText
            $(embedTextFile "lib/Agent/SeaOfGoals/Prompts/skill-context.txt")
    )

experimentSystemPrompt :: Text
experimentSystemPrompt =
  $(embedTextFile "lib/Agent/SeaOfGoals/Prompts/experiment-system.txt")

experimentSystemPromptNoLifecycle :: Text
experimentSystemPromptNoLifecycle =
  $(embedTextFile "lib/Agent/SeaOfGoals/Prompts/experiment-system-no-lifecycle.txt")

experimentTools :: [ToolSpec]
experimentTools =
  experimentToolsWithShell shellTool

experimentToolsWithShell :: ToolSpec -> [ToolSpec]
experimentToolsWithShell shellToolSpec =
  [ endGoalTool
  , writeFileTool
  , shellToolSpec
  ]

workspaceContextHistory :: [LLMInputItem]
workspaceContextHistory =
  [ ToolCallInput contextCall
  , ToolResultInput
      ToolResult
        { toolResultCallId = toolCallId contextCall
        , toolResultName = Just "workspace_context"
        , toolResultContent =
            [ TextPart
                ( Text.unlines
                    [ "current_directory: /workspace"
                    , "workspace_root: /workspace"
                    , "allowed_scope: /workspace/**"
                    , "Only read or modify files below /workspace. Do not inspect parent directories, filesystem roots, host paths, or harness control files."
                    ]
                )
            ]
        }
  ]
 where
  contextCall =
    ToolCall
      { toolCallId = "sog-workspace-context"
      , toolCallName = "workspace_context"
      , toolCallArguments = object []
      }

loadExperimentToolsWithControlRoot
  :: FilePath -> IORef GoalContextPreloadPlan -> Bool -> IO [ToolSpec]
loadExperimentToolsWithControlRoot controlRoot dynamicPlan harnessLifecycle = do
  workspaceRoot <- normalise <$> getCurrentDirectory
  experimentToolsForWorkspaceWithControlRoot
    workspaceRoot
    controlRoot
    dynamicPlan
    harnessLifecycle

experimentToolsForWorkspace :: ExperimentContext -> FilePath -> IO [ToolSpec]
experimentToolsForWorkspace context workspaceRoot =
  experimentToolsForWorkspaceWithControlRoot
    workspaceRoot
    (workspaceRoot <> ".sog")
    (experimentDynamicGoalContextPreloadPlan context)
    (experimentHarnessLifecycle context)

experimentToolsForWorkspaceWithControlRoot
  :: FilePath -> FilePath -> IORef GoalContextPreloadPlan -> Bool -> IO [ToolSpec]
experimentToolsForWorkspaceWithControlRoot workspaceRoot controlRoot dynamicPlan harnessLifecycle = do
  maybeSandbox <- lookupEnv "SOG_SANDBOX"
  maybeBwrap <- lookupEnv "SOG_BWRAP"
  case (maybeSandbox, maybeBwrap) of
    (Just "bwrap", _) ->
      loadBwrapExperimentToolsAt
        workspaceRoot
        controlRoot
        dynamicPlan
        harnessLifecycle
        (fromMaybe "bwrap" maybeBwrap)
    (_, Just binary)
      | not (null binary) ->
          loadBwrapExperimentToolsAt
            workspaceRoot
            controlRoot
            dynamicPlan
            harnessLifecycle
            binary
    _ ->
      pure
        ( experimentToolsForPathWithLifecycle
            workspaceRoot
            dynamicPlan
            harnessLifecycle
        )

loadBwrapExperimentToolsAt
  :: FilePath
  -> FilePath
  -> IORef GoalContextPreloadPlan
  -> Bool
  -> FilePath
  -> IO [ToolSpec]
loadBwrapExperimentToolsAt workspaceRoot controlRoot dynamicPlan harnessLifecycle binary = do
  let normalWorkspaceRoot = normalise workspaceRoot
  let
    bwrapRoot = normalise controlRoot </> "bwrap"
    cacheRoot = bwrapRoot </> "cache"
    homeRoot = bwrapRoot </> "home"
    tmpRoot = bwrapRoot </> "tmp"
  mapM_ (createDirectoryIfMissing True) [cacheRoot, homeRoot, tmpRoot]
  let
    runner = BwrapSandboxRunner (BwrapCommand.Config binary)
    view =
      BwrapProfile.demoWorkspaceOnlyView
        BwrapProfile.DemoPaths
          { BwrapProfile.demoWorkspaceHostPath = normalWorkspaceRoot
          , BwrapProfile.demoCacheHostPath = cacheRoot
          , BwrapProfile.demoHomeHostPath = homeRoot
          , BwrapProfile.demoTmpHostPath = tmpRoot
          }
  handle <-
    createSandbox
      runner
      BwrapSandboxSpec
        { bwrapSandboxId = "experiment-bwrap"
        , bwrapSandboxView = view
        }
  pure
    ( lifecycleTools harnessLifecycle
        <> [ setPreloadPlanTool dynamicPlan
           , setPredictedActionsPlanTool controlRoot
           , writeFileToolAt normalWorkspaceRoot
           , bwrapShellTool
               BwrapToolBinding
                 { bwrapToolRunner = runner
                 , bwrapToolHandle = handle
                 }
           ]
    )

experimentToolsForPathWithLifecycle
  :: FilePath -> IORef GoalContextPreloadPlan -> Bool -> [ToolSpec]
experimentToolsForPathWithLifecycle workspaceRoot dynamicPlan harnessLifecycle =
  lifecycleTools harnessLifecycle
    <> [ setPreloadPlanTool dynamicPlan
       , setPredictedActionsPlanTool (workspaceRoot <> ".sog")
       , writeFileToolAt workspaceRoot
       , shellToolAt workspaceRoot
       ]

lifecycleTools :: Bool -> [ToolSpec]
lifecycleTools False = []
lifecycleTools True =
  [ endGoalTool
  ]

endGoalTool :: ToolSpec
endGoalTool =
  objectToolSpec
    "end_goal"
    "Finish the assigned goal and pass its result to successor goals."
    [ ("id", textSchema "Assigned goal id being ended")
    , ("status", textSchema "success, failed, skipped, or blocked")
    ,
      ( "summary"
      , textSchema
          "Optional result summary. History-handoff goals pass their complete history instead."
      )
    ]
    ["id", "status"]
    $ \toolCall -> do
      case parseArgs toolCall of
        Left err -> pure (textResult toolCall err, [])
        Right args ->
          pure
            ( textResult toolCall "goal ended"
            ,
              [ SubgoalEnded
                  { eventSubgoalId = endId args
                  , eventStatus = endStatus args
                  , eventSummary = endSummary args
                  }
              ]
            )

setPreloadPlanTool :: IORef GoalContextPreloadPlan -> ToolSpec
setPreloadPlanTool dynamicPlan =
  objectToolSpec
    "set_preload_plan"
    "Submit a JSON preload plan for later goals to the harness. This records control data only and does not write workspace files."
    [
      ( "plan_json"
      , textSchema
          "JSON object with shape {\"goals\":{\"G001\":[\"relative/path/from/workspace\"]}}"
      )
    ]
    ["plan_json"]
    $ \toolCall ->
      case parseArgs toolCall of
        Left err -> pure (textResult toolCall err, [])
        Right args ->
          case eitherDecode
            (LazyByteString.fromStrict (TextEncoding.encodeUtf8 (preloadPlanJson args))) of
            Left err ->
              pure (textResult toolCall ("invalid preload plan JSON: " <> Text.pack err), [])
            Right plan@(GoalContextPreloadPlan goals) -> do
              modifyIORef'
                dynamicPlan
                (`mergeGoalContextPreloadPlans` plan)
              pure
                ( textResult toolCall "preload plan recorded"
                ,
                  [ EffectRecorded
                      { eventEffect =
                          EffectRecord
                            { effectKind = "preload_plan"
                            , effectResource = "dynamic"
                            , effectDetail =
                                Just
                                  ( "goals="
                                      <> Text.intercalate "," (Map.keys goals)
                                  )
                            }
                      , eventActiveSubgoal = Nothing
                      }
                  ]
                )

setPredictedActionsPlanTool :: FilePath -> ToolSpec
setPredictedActionsPlanTool controlRoot =
  objectToolSpec
    "set_predicted_actions_plan"
    "Publish a JSON plan of conservative read-only bash actions for later goals. This records control data only and does not modify the workspace. It may be called incrementally; previously published goals are retained."
    [
      ( "plan_json"
      , textSchema
          "JSON object with shape {\"goals\":{\"G001\":[{\"command\":\"rg pattern src\"}]}}"
      )
    ]
    ["plan_json"]
    $ \toolCall ->
      case parseArgs toolCall of
        Left err -> pure (textResult toolCall err, [])
        Right args -> do
          let planPath = controlRoot </> "predicted-actions-plan.json"
          let parsed =
                eitherDecode
                  ( LazyByteString.fromStrict
                      (TextEncoding.encodeUtf8 (predictedActionsPlanJson args))
                  )
          case parsed of
            Left err ->
              pure
                ( textResult toolCall ("invalid predicted actions plan JSON: " <> Text.pack err)
                , []
                )
            Right plan -> do
              exists <- doesFileExist planPath
              existing <-
                if exists
                  then readPredictedActionsPlanFile planPath
                  else pure (Right (PredictedActionsPlan Map.empty))
              case existing of
                Left err ->
                  pure
                    ( textResult
                        toolCall
                        ("existing predicted actions plan is invalid: " <> Text.pack err)
                    , []
                    )
                Right oldPlan -> do
                  createDirectoryIfMissing True controlRoot
                  LazyByteString.writeFile
                    planPath
                    (encode (mergePredictedActionsPlans oldPlan plan))
                  pure
                    ( textResult toolCall "predicted actions plan recorded"
                    ,
                      [ EffectRecorded
                          { eventEffect =
                              EffectRecord
                                { effectKind = "predicted_actions_plan"
                                , effectResource = Text.pack planPath
                                , effectDetail =
                                    Just
                                      ( "goals="
                                          <> Text.intercalate "," (Map.keys (predictedActionsPlanGoals plan))
                                      )
                                }
                          , eventActiveSubgoal = Nothing
                          }
                      ]
                    )

writeFileTool :: ToolSpec
writeFileTool =
  objectToolSpec
    "write_file"
    "Write complete UTF-8 text content to a local file."
    [ ("path", textSchema "Path to write, such as /workspace/application.yml")
    , ("content", textSchema "Complete file content to write")
    ]
    ["path", "content"]
    $ \toolCall -> do
      workspaceRoot <- normalise <$> getCurrentDirectory
      handleWriteFileTool workspaceRoot toolCall

writeFileToolAt :: FilePath -> ToolSpec
writeFileToolAt workspaceRoot =
  objectToolSpec
    "write_file"
    "Write complete UTF-8 text content to a local file."
    [ ("path", textSchema "Path to write, such as /workspace/application.yml")
    , ("content", textSchema "Complete file content to write")
    ]
    ["path", "content"]
    $ handleWriteFileTool (normalise workspaceRoot)

handleWriteFileTool :: FilePath -> ToolCall -> IO (ToolResult, [HarnessEvent])
handleWriteFileTool workspaceRoot toolCall =
  case parseArgs toolCall of
    Left err -> pure (textResult toolCall err, [])
    Right args -> do
      resolved <- resolveWorkspaceWritePathAt workspaceRoot (writePath args)
      case resolved of
        Left err -> pure (textResult toolCall err, [])
        Right path -> do
          createDirectoryIfMissing True (takeDirectory path)
          TextIO.writeFile path (writeContent args)
          pure
            ( textResult toolCall "file written"
            ,
              [ EffectRecorded
                  { eventEffect =
                      EffectRecord
                        { effectKind = "write"
                        , effectResource = Text.pack path
                        , effectDetail = Just "write_file"
                        }
                  , eventActiveSubgoal = Nothing
                  }
              ]
            )

resolveWorkspaceWritePathAt :: FilePath -> Text -> IO (Either Text FilePath)
resolveWorkspaceWritePathAt workspaceRoot requestedPath = do
  let
    rawPath = Text.unpack requestedPath
    workspaceAgentPrefix = "/workspace/" :: String
    absolutePath =
      normalise $
        if rawPath == "/workspace"
          then workspaceRoot
          else
            if workspaceAgentPrefix `isPrefixOf` rawPath
              then workspaceRoot </> drop (length workspaceAgentPrefix) rawPath
              else
                if isAbsolute rawPath
                  then rawPath
                  else workspaceRoot </> rawPath
    workspacePrefix = addTrailingPathSeparator workspaceRoot
  pure $
    if absolutePath == workspaceRoot || workspacePrefix `isPrefixOf` absolutePath
      then Right absolutePath
      else
        Left
          ( "write_file path must stay under "
              <> Text.pack workspaceRoot
              <> ": "
              <> requestedPath
          )

shellTool :: ToolSpec
shellTool =
  objectToolSpec
    "shell"
    "Run a local shell command and return stdout, stderr, and exit code."
    [ ("command", textSchema "Shell command to run")
    ]
    ["command"]
    $ \toolCall -> do
      workspaceRoot <- normalise <$> getCurrentDirectory
      handleShellTool workspaceRoot toolCall

shellToolAt :: FilePath -> ToolSpec
shellToolAt workspaceRoot =
  objectToolSpec
    "shell"
    "Run a local shell command and return stdout, stderr, and exit code."
    [ ("command", textSchema "Shell command to run")
    ]
    ["command"]
    $ handleShellTool (normalise workspaceRoot)

handleShellTool :: FilePath -> ToolCall -> IO (ToolResult, [HarnessEvent])
handleShellTool workspaceRoot toolCall =
  case parseArgs toolCall of
    Left err -> pure (textResult toolCall err, [])
    Right args -> do
      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          ( (proc "/bin/sh" ["-lc", Text.unpack (shellCommand args)])
              { cwd = Just workspaceRoot
              }
          )
          ""
      let resultText =
            Text.unlines
              [ "exit_code: " <> exitCodeText exitCode
              , "stdout:"
              , Text.pack stdoutText
              , "stderr:"
              , Text.pack stderrText
              ]
      pure (textResult toolCall resultText, [])

appendEvent :: FilePath -> HarnessEvent -> IO ()
appendEvent path event = do
  timestamp <- getCurrentTime
  LazyByteString.appendFile
    path
    ( encode
        ( object
            [ "timestamp" .= iso8601Show timestamp
            , "event" .= event
            ]
        )
        <> "\n"
    )

textSchema :: Text -> Value
textSchema description =
  object
    [ "type" .= ("string" :: Text)
    , "description" .= description
    ]

textResult :: ToolCall -> Text -> ToolResult
textResult toolCall content =
  ToolResult
    { toolResultCallId = toolCallId toolCall
    , toolResultName = Just (toolCallName toolCall)
    , toolResultContent = [TextPart content]
    }

parseArgs :: FromJSON value => ToolCall -> Either Text value
parseArgs toolCall =
  case eitherDecode (encode (toolCallArguments toolCall)) of
    Left err -> Left ("invalid tool arguments: " <> Text.pack err)
    Right value -> Right value

newtype SetPreloadPlanArgs = SetPreloadPlanArgs
  { preloadPlanJson :: Text
  }

instance FromJSON SetPreloadPlanArgs where
  parseJSON =
    withObject "SetPreloadPlanArgs" $ \value ->
      SetPreloadPlanArgs <$> value .: "plan_json"

newtype SetPredictedActionsPlanArgs = SetPredictedActionsPlanArgs
  { predictedActionsPlanJson :: Text
  }

instance FromJSON SetPredictedActionsPlanArgs where
  parseJSON =
    withObject "SetPredictedActionsPlanArgs" $ \value ->
      SetPredictedActionsPlanArgs <$> value .: "plan_json"

data EndGoalArgs = EndGoalArgs
  { endId :: Text
  , endStatus :: Text
  , endSummary :: Maybe Text
  }

instance FromJSON EndGoalArgs where
  parseJSON =
    withObject "EndGoalArgs" $ \value ->
      do
        goalId <- value .: "id"
        status <- value .: "status"
        summary <- value .:? "summary"
        if status `notElem` ["success", "failed", "skipped", "blocked"]
          then fail "end_goal requires a valid status"
          else pure (EndGoalArgs goalId status (Text.strip <$> summary))

data WriteFileArgs = WriteFileArgs
  { writePath :: Text
  , writeContent :: Text
  }

instance FromJSON WriteFileArgs where
  parseJSON =
    withObject "WriteFileArgs" $ \value ->
      WriteFileArgs
        <$> value .: "path"
        <*> value .: "content"

newtype ShellArgs = ShellArgs
  { shellCommand :: Text
  }

instance FromJSON ShellArgs where
  parseJSON =
    withObject "ShellArgs" $ \value ->
      ShellArgs <$> value .: "command"

exitCodeText :: ExitCode -> Text
exitCodeText ExitSuccess = "0"
exitCodeText (ExitFailure code) = Text.pack (show code)
