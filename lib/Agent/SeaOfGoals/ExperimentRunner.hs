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
  , runCodexProcess
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
import Agent.SeaOfGoals.Harness
  ( HarnessConfig (..)
  , HarnessState (..)
  , runHarness
  )
import Agent.SeaOfGoals.LLM
  ( LLMContentPart (TextPart)
  , LLMRequest (..)
  , ResponseFormat (PlainText)
  , ToolCall (..)
  , ToolResult (..)
  )
import Agent.SeaOfGoals.LLM.Backends.GPT
  ( GPTBackend (..)
  , defaultGPTEndpoint
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
  )
import Agent.SeaOfGoals.Scheduling.GraphChase
  ( ChaseState (..)
  , initialChaseState
  )
import Agent.SeaOfGoals.Scheduling.SerialScheduler
  ( SerialScheduler (..)
  , SerialSchedulerResult (..)
  , goalPredecessors
  , runSerialScheduler
  )
import Agent.SeaOfGoals.Tools
  ( ToolSpec
  , objectToolSpec
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
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
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
  , experimentSystemPromptText :: Text
  , experimentUserPromptText :: Text
  , experimentConfig :: Config
  , experimentAgentRunner :: AgentRunnerMode
  , experimentCodexProcessConfig :: CodexProcessConfig
  , experimentToolsForRun :: [ToolSpec]
  , experimentEventSink :: HarnessEvent -> IO ()
  , experimentWorkflowSpec :: Maybe WorkflowSpec
  }

data AgentRunnerMode
  = HarnessAgentRunner
  | CodexAgentRunner
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
  tracePath <- fromMaybe "sog-trace.jsonl" <$> lookupEnv "SOG_TRACE_PATH"
  model <- Text.pack . fromMaybe "gpt-5.5" <$> lookupEnv "SOG_MODEL"
  config <- loadConfigFromEnv
  agentRunner <- loadAgentRunnerMode
  codexProcessConfig <- loadCodexProcessConfigFromEnv
  workflowSpec <- loadWorkflowSpecFromEnv
  tools <- loadExperimentTools
  skillContext <- loadSkillContextFromEnv
  createDirectoryIfMissing True (takeDirectory tracePath)
  traceLock <- newMVar ()
  let
    backend =
      GPTBackend
        { gptApiKey = apiKey
        , gptEndpoint = defaultGPTEndpoint
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
        }
    workflowPrompt = maybe "" renderWorkflowPrompt workflowSpec
    systemPrompt =
      Text.intercalate
        "\n\n"
        (filter (not . Text.null) [experimentSystemPrompt, skillContext, workflowPrompt])
  pure
    ExperimentContext
      { experimentBackend = backend
      , experimentRequestTemplate = requestTemplate
      , experimentTracePath = tracePath
      , experimentSystemPromptText = systemPrompt
      , experimentUserPromptText = prompt
      , experimentConfig = config
      , experimentAgentRunner = agentRunner
      , experimentCodexProcessConfig = codexProcessConfig
      , experimentToolsForRun = tools
      , experimentEventSink = lockedAppendEvent traceLock tracePath
      , experimentWorkflowSpec = workflowSpec
      }

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
            , harnessTools = experimentToolsForRun context
            , harnessMaxTurns = 64
            , harnessEventSink = experimentEventSink context
            , harnessWorkflowSpec = experimentWorkflowSpec context
            }
    CodexAgentRunner -> do
      workspaceRoot <- normalise <$> getCurrentDirectory
      result <-
        runCodexProcess
          (experimentCodexProcessConfig context)
          (experimentEventSink context)
          Nothing
          workspaceRoot
          (codexPrompt context (experimentUserPromptText context))
      when (codexProcessExitCode result /= 0) $
        fail
          ("codex process failed with exit code " <> show (codexProcessExitCode result))
  putStrLn ("Trace written to " <> experimentTracePath context)

runSerialPromptWithGraph :: ExperimentContext -> CompiledGoalGraph -> IO ()
runSerialPromptWithGraph context compiledGraph = do
  let goalGraph = compiledGraphToGoalGraph compiledGraph
  summariesRef <- newSummaries
  result <-
    runSerialScheduler
      SerialScheduler
        { serialSchedulerRunGoal =
            runSerialGoal context goalGraph summariesRef
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
  let
    goalGraph = compiledGraphToGoalGraph compiledGraph
    chaseConfig = configConcurrentChase (experimentConfig context)
  workspaceRoot <- normalise <$> getCurrentDirectory
  recordDagSnapshot
    context
    "concurrent_initial"
    (Just "compiled goal graph before scheduling")
    (initialChaseState goalGraph)
  summariesRef <- newSummaries
  runsRef <- newIORef Map.empty
  acceptedWritesRef <- newIORef Map.empty
  result <-
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
              runsRef
        , concurrentChaseMergeGoal =
            mergeConcurrentGoal
              context
              goalGraph
              workspaceRoot
              summariesRef
              acceptedWritesRef
        }
      goalGraph
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
    Just other -> fail ("unknown SOG_AGENT_RUNNER: " <> Text.unpack other)

runSerialGoal
  :: ExperimentContext
  -> GoalGraph
  -> Summaries
  -> GoalNode
  -> IO (Either Text AgentRunResult)
runSerialGoal context goalGraph summaries node = do
  recordGraphSnapshot
    context
    "serial_goal_enter"
    (Just ("enter " <> unGoalNodeId (goalNodeId node)))
    goalGraph
  predecessorSummaries <-
    summariesFor summaries (goalPredecessors goalGraph (goalNodeId node))
  let prompt =
        serialGoalPrompt
          (experimentUserPromptText context)
          predecessorSummaries
          node
  case experimentAgentRunner context of
    HarnessAgentRunner ->
      runSerialHarnessGoal context summaries node prompt
    CodexAgentRunner ->
      runSerialCodexGoal context summaries node prompt

runSerialHarnessGoal
  :: ExperimentContext
  -> Summaries
  -> GoalNode
  -> Text
  -> IO (Either Text AgentRunResult)
runSerialHarnessGoal context summaries node prompt = do
  state <-
    runHarness
      HarnessConfig
        { harnessProvider = experimentBackend context
        , harnessRequestTemplate = experimentRequestTemplate context
        , harnessSystemPrompt = experimentSystemPromptText context
        , harnessUserPrompt = prompt
        , harnessTools = experimentToolsForRun context
        , harnessMaxTurns = 32
        , harnessEventSink = experimentEventSink context
        , harnessWorkflowSpec = experimentWorkflowSpec context
        }
  let
    status = serialGoalStatus node state
    summary = serialGoalSummary node status
    result =
      AgentRunResult
        { agentRunResultGoal = goalNodeId node
        , agentRunResultStatus = status
        , agentRunResultSummaryForDependents = summary
        , agentRunResultReads = Set.empty
        , agentRunResultWrites = Set.empty
        , agentRunResultSnapshot = SnapshotId (unGoalNodeId (goalNodeId node))
        }
  if serialGoalStatusIsTerminal status
    then do
      rememberSummary summaries (goalNodeId node) summary
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
  -> GoalNode
  -> Text
  -> IO (Either Text AgentRunResult)
runSerialCodexGoal context summaries node prompt = do
  workspaceRoot <- normalise <$> getCurrentDirectory
  let beforeWorkspace =
        workspaceRoot
          </> ".sog"
          </> "serial"
          </> Text.unpack (unGoalNodeId (goalNodeId node))
          </> "before"
  resetDirectory beforeWorkspace
  copyWorkspaceTree workspaceRoot beforeWorkspace
  codexResult <-
    runCodexGoalProcess context workspaceRoot node prompt
  changedPaths <- workspaceChangedPaths beforeWorkspace workspaceRoot
  let
    status = codexGoalStatus codexResult
    summary = codexGoalSummary node codexResult
    result =
      AgentRunResult
        { agentRunResultGoal = goalNodeId node
        , agentRunResultStatus = status
        , agentRunResultSummaryForDependents = summary
        , agentRunResultReads = Set.empty
        , agentRunResultWrites = Set.fromList changedPaths
        , agentRunResultSnapshot = SnapshotId (unGoalNodeId (goalNodeId node))
        }
  if serialGoalStatusIsTerminal status
    then do
      rememberSummary summaries (goalNodeId node) summary
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

runCodexGoalProcess
  :: ExperimentContext
  -> FilePath
  -> GoalNode
  -> Text
  -> IO CodexProcessResult
runCodexGoalProcess context workspaceRoot node prompt = do
  experimentEventSink context $
    SubgoalStarted
      { eventSubgoalId = unGoalNodeId (goalNodeId node)
      , eventSubgoalName = goalNodeName node
      }
  result <-
    runCodexProcess
      (experimentCodexProcessConfig context)
      (experimentEventSink context)
      (Just (unGoalNodeId (goalNodeId node)))
      workspaceRoot
      (codexPrompt context prompt)
  experimentEventSink context $
    SubgoalEnded
      { eventSubgoalId = unGoalNodeId (goalNodeId node)
      , eventStatus = codexGoalStatus result
      , eventSummary = Just (codexGoalSummary node result)
      }
  pure result

codexPrompt :: ExperimentContext -> Text -> Text
codexPrompt context prompt =
  Text.intercalate
    "\n\n"
    [ "You are executing one SeaOfGoals task node inside an externally managed sandbox."
    , "Use the instructions below as the task-specific developer guidance for this process. Work only in the current workspace unless the task explicitly requires inspection elsewhere."
    , "SeaOfGoals instructions:"
    , experimentSystemPromptText context
    , "Task prompt:"
    , prompt
    , "When the task is finished, reply with a concise summary for dependent goals."
    ]

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
  -> IORef (Map GoalNodeId Int)
  -> GoalNode
  -> IO (Either Text AgentRunResult)
runConcurrentGoal context goalGraph baseWorkspace summaries runsRef node = do
  recordGraphSnapshot
    context
    "concurrent_goal_enter"
    (Just ("enter " <> unGoalNodeId (goalNodeId node)))
    goalGraph
  runIndex <- nextGoalRunIndex runsRef (goalNodeId node)
  let
    runSlug =
      Text.unpack (unGoalNodeId (goalNodeId node))
        <> "-"
        <> show runIndex
    taskWorkspace =
      baseWorkspace
        </> ".sog"
        </> "concurrent"
        </> "goals"
        </> runSlug
        </> "workspace"
  resetDirectory taskWorkspace
  copyWorkspaceTree baseWorkspace taskWorkspace
  predecessorSummaries <-
    summariesFor summaries (goalPredecessors goalGraph (goalNodeId node))
  tools <- experimentToolsForWorkspace taskWorkspace
  let prompt =
        serialGoalPrompt
          (experimentUserPromptText context)
          predecessorSummaries
          node
  case experimentAgentRunner context of
    HarnessAgentRunner ->
      runConcurrentHarnessGoal context taskWorkspace tools node prompt
    CodexAgentRunner ->
      runConcurrentCodexGoal context baseWorkspace taskWorkspace node prompt

runConcurrentHarnessGoal
  :: ExperimentContext
  -> FilePath
  -> [ToolSpec]
  -> GoalNode
  -> Text
  -> IO (Either Text AgentRunResult)
runConcurrentHarnessGoal context taskWorkspace tools node prompt = do
  baseWorkspace <- normalise <$> getCurrentDirectory
  state <-
    runHarness
      HarnessConfig
        { harnessProvider = experimentBackend context
        , harnessRequestTemplate = experimentRequestTemplate context
        , harnessSystemPrompt = experimentSystemPromptText context
        , harnessUserPrompt = prompt
        , harnessTools = tools
        , harnessMaxTurns = 32
        , harnessEventSink = experimentEventSink context
        , harnessWorkflowSpec = experimentWorkflowSpec context
        }
  let status = serialGoalStatus node state
  changedPaths <- workspaceChangedPaths baseWorkspace taskWorkspace
  let
    summary = serialGoalSummary node status
    result =
      AgentRunResult
        { agentRunResultGoal = goalNodeId node
        , agentRunResultStatus = status
        , agentRunResultSummaryForDependents = summary
        , agentRunResultReads = Set.empty
        , agentRunResultWrites = Set.fromList changedPaths
        , agentRunResultSnapshot =
            SnapshotId
              ( unGoalNodeId (goalNodeId node)
                  <> ":"
                  <> Text.pack taskWorkspace
              )
        }
  if serialGoalStatusIsTerminal status
    then pure (Right result)
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
  -> FilePath
  -> FilePath
  -> GoalNode
  -> Text
  -> IO (Either Text AgentRunResult)
runConcurrentCodexGoal context baseWorkspace taskWorkspace node prompt = do
  codexResult <- runCodexGoalProcess context taskWorkspace node prompt
  changedPaths <- workspaceChangedPaths baseWorkspace taskWorkspace
  let
    status = codexGoalStatus codexResult
    summary = codexGoalSummary node codexResult
    result =
      AgentRunResult
        { agentRunResultGoal = goalNodeId node
        , agentRunResultStatus = status
        , agentRunResultSummaryForDependents = summary
        , agentRunResultReads = Set.empty
        , agentRunResultWrites = Set.fromList changedPaths
        , agentRunResultSnapshot =
            SnapshotId
              ( unGoalNodeId (goalNodeId node)
                  <> ":"
                  <> Text.pack taskWorkspace
              )
        }
  if serialGoalStatusIsTerminal status
    then pure (Right result)
    else
      pure
        ( Left
            ( "concurrent codex goal "
                <> unGoalNodeId (goalNodeId node)
                <> " failed: "
                <> status
            )
        )

mergeConcurrentGoal
  :: ExperimentContext
  -> GoalGraph
  -> FilePath
  -> Summaries
  -> IORef (Map FilePath GoalNodeId)
  -> AgentRunResult
  -> IO (Either ConcurrentChaseConflict ())
mergeConcurrentGoal context goalGraph baseWorkspace summaries acceptedWritesRef result = do
  recordMergeGraphSnapshot context goalGraph "merge_before" result Nothing
  acceptedWrites <- readIORef acceptedWritesRef
  case firstWriteConflict acceptedWrites (agentRunResultWrites result) of
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
                  "workspace write/write conflict on " <> Text.pack path
              }
        )
    Nothing -> do
      applyGoalWorkspace baseWorkspace result
      rememberSummary
        summaries
        (agentRunResultGoal result)
        (agentRunResultSummaryForDependents result)
      modifyIORef'
        acceptedWritesRef
        ( \current ->
            foldr
              (`Map.insert` agentRunResultGoal result)
              current
              (Set.toList (agentRunResultWrites result))
        )
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

firstWriteConflict
  :: Map FilePath GoalNodeId -> Set FilePath -> Maybe (FilePath, GoalNodeId)
firstWriteConflict acceptedWrites writes =
  case [ (path, formerGoal)
       | path <- Set.toList writes
       , Just formerGoal <- [Map.lookup path acceptedWrites]
       ] of
    conflict : _ -> Just conflict
    [] -> Nothing

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

serialGoalPrompt :: Text -> [(GoalNodeId, Text)] -> GoalNode -> Text
serialGoalPrompt originalPrompt predecessorSummaries node =
  Text.intercalate
    "\n\n"
    ( filter
        (not . Text.null)
        [ "Original task:\n" <> originalPrompt
        , renderedSummaries
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
            , "Do not read harness trajectory files such as sog-trace.jsonl; they are private experiment records, not task inputs."
            , ""
            , "Before doing work, call begin_subgoal with this exact goal id."
            , "When this goal is complete, call end_subgoal with this exact goal id and a concise summary."
            , "Do not start a different goal in this agent loop."
            ]
        ]
    )
 where
  renderedSummaries
    | null predecessorSummaries = ""
    | otherwise =
        Text.unlines
          ( "Completed predecessor summaries:"
              : fmap renderSummary predecessorSummaries
          )
  renderSummary (goalId, summary) =
    "- " <> unGoalNodeId goalId <> ": " <> summary

serialGoalStatus :: GoalNode -> HarnessState -> Text
serialGoalStatus node state
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

serialGoalSummary :: GoalNode -> Text -> Text
serialGoalSummary node status =
  goalNodeName node <> " finished with status " <> status

type Summaries = IORef (Map GoalNodeId Text)

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

experimentTools :: [ToolSpec]
experimentTools =
  experimentToolsWithShell shellTool

experimentToolsWithShell :: ToolSpec -> [ToolSpec]
experimentToolsWithShell shellToolSpec =
  [ beginSubgoalTool
  , endSubgoalTool
  , recordEffectTool
  , writeFileTool
  , shellToolSpec
  ]

loadExperimentTools :: IO [ToolSpec]
loadExperimentTools = getCurrentDirectory >>= experimentToolsForWorkspace

experimentToolsForWorkspace :: FilePath -> IO [ToolSpec]
experimentToolsForWorkspace workspaceRoot = do
  maybeSandbox <- lookupEnv "SOG_SANDBOX"
  maybeBwrap <- lookupEnv "SOG_BWRAP"
  case (maybeSandbox, maybeBwrap) of
    (Just "bwrap", _) ->
      loadBwrapExperimentToolsAt workspaceRoot (fromMaybe "bwrap" maybeBwrap)
    (_, Just binary)
      | not (null binary) ->
          loadBwrapExperimentToolsAt workspaceRoot binary
    _ ->
      pure (experimentToolsForPath workspaceRoot)

loadBwrapExperimentToolsAt :: FilePath -> FilePath -> IO [ToolSpec]
loadBwrapExperimentToolsAt workspaceRoot binary = do
  let normalWorkspaceRoot = normalise workspaceRoot
  let
    bwrapRoot = normalWorkspaceRoot </> ".sog" </> "bwrap"
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
    [ beginSubgoalTool
    , endSubgoalTool
    , recordEffectTool
    , writeFileToolAt normalWorkspaceRoot
    , bwrapShellTool
        BwrapToolBinding
          { bwrapToolRunner = runner
          , bwrapToolHandle = handle
          }
    ]

experimentToolsForPath :: FilePath -> [ToolSpec]
experimentToolsForPath workspaceRoot =
  [ beginSubgoalTool
  , endSubgoalTool
  , recordEffectTool
  , writeFileToolAt workspaceRoot
  , shellToolAt workspaceRoot
  ]

beginSubgoalTool :: ToolSpec
beginSubgoalTool =
  objectToolSpec
    "begin_subgoal"
    "Mark the beginning of a concrete subgoal before doing work."
    [ ("id", textSchema "Stable subgoal id, such as an SCFG node id N001")
    , ("name", textSchema "Short human-readable subgoal name")
    ]
    ["id", "name"]
    $ \toolCall -> do
      case parseArgs toolCall of
        Left err -> pure (textResult toolCall err, [])
        Right args ->
          pure
            ( textResult toolCall "subgoal started"
            ,
              [ SubgoalStarted
                  { eventSubgoalId = beginId args
                  , eventSubgoalName = beginName args
                  }
              ]
            )

endSubgoalTool :: ToolSpec
endSubgoalTool =
  objectToolSpec
    "end_subgoal"
    "Mark the end of the current subgoal."
    [ ("id", textSchema "Subgoal id being ended")
    , ("status", textSchema "success, failed, skipped, or blocked")
    , ("summary", textSchema "Short result summary")
    ]
    ["id", "status"]
    $ \toolCall -> do
      case parseArgs toolCall of
        Left err -> pure (textResult toolCall err, [])
        Right args ->
          pure
            ( textResult toolCall "subgoal ended"
            ,
              [ SubgoalEnded
                  { eventSubgoalId = endId args
                  , eventStatus = endStatus args
                  , eventSummary = endSummary args
                  }
              ]
            )

recordEffectTool :: ToolSpec
recordEffectTool =
  objectToolSpec
    "record_effect"
    "Record a side effect observed by the agent."
    [
      ( "kind"
      , textSchema "read, write, delete, spawn, network, db, docker, or artifact"
      )
    , ("resource", textSchema "Resource identifier affected by this step")
    , ("detail", textSchema "Optional short detail")
    ]
    ["kind", "resource"]
    $ \toolCall -> do
      case parseArgs toolCall of
        Left err -> pure (textResult toolCall err, [])
        Right args ->
          pure
            ( textResult toolCall "effect recorded"
            ,
              [ EffectRecorded
                  { eventEffect =
                      EffectRecord
                        { effectKind = effectKindArg args
                        , effectResource = effectResourceArg args
                        , effectDetail = effectDetailArg args
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

data BeginSubgoalArgs = BeginSubgoalArgs
  { beginId :: Text
  , beginName :: Text
  }

instance FromJSON BeginSubgoalArgs where
  parseJSON =
    withObject "BeginSubgoalArgs" $ \value ->
      BeginSubgoalArgs
        <$> value .: "id"
        <*> value .: "name"

data EndSubgoalArgs = EndSubgoalArgs
  { endId :: Text
  , endStatus :: Text
  , endSummary :: Maybe Text
  }

instance FromJSON EndSubgoalArgs where
  parseJSON =
    withObject "EndSubgoalArgs" $ \value ->
      EndSubgoalArgs
        <$> value .: "id"
        <*> value .: "status"
        <*> value .:? "summary"

data EffectArgs = EffectArgs
  { effectKindArg :: Text
  , effectResourceArg :: Text
  , effectDetailArg :: Maybe Text
  }

instance FromJSON EffectArgs where
  parseJSON =
    withObject "EffectArgs" $ \value ->
      EffectArgs
        <$> value .: "kind"
        <*> value .: "resource"
        <*> value .:? "detail"

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
