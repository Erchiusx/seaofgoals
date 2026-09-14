module Main (main) where

import Agent.LLM.Transport
  ( TransportResponse (..)
  )
import Agent.SeaOfGoals.CodexProcess
  ( CodexProcessConfig (..)
  , codexProcessExecSpec
  , codexProcessView
  , defaultCodexProcessConfig
  )
import Agent.SeaOfGoals.Compile.Compiler
  ( CompiledGoal (..)
  , CompiledGoalGraph (..)
  , CompilerStrategy (OrderedSpeculativeCompilerStrategy)
  , compilerCodexPromptForStrategy
  , compilerCodexPromptWithPreloadPlanner
  , validateCompiledGoalGraph
  )
import Agent.SeaOfGoals.Config
  ( ConcurrentChaseConfig (..)
  , Config (..)
  , defaultConfig
  , loadConfigFile
  )
import Agent.SeaOfGoals.ExperimentRunner qualified as Experiment
import Agent.SeaOfGoals.GoalContextPreload
  ( GoalContextPreloadConfig (..)
  , PreloadedGoalContext (..)
  , defaultGoalContextPreloadConfig
  , preloadGoalContext
  , preloadGoalContextDetailed
  , preloadGoalContextWithPlan
  , preloadGoalContextWithPlanDetailed
  )
import Agent.SeaOfGoals.Harness
  ( HarnessConfig (..)
  , HarnessState (..)
  , runHarness
  )
import Agent.SeaOfGoals.LLM
  ( LLM (..)
  , LLMContentPart (TextPart)
  , LLMError (LLMProviderError)
  , LLMInputItem (MessageInput, ToolCallInput, ToolResultInput)
  , LLMMessage (..)
  , LLMRequest (..)
  , LLMResponse (..)
  , LLMRole (..)
  , ResponseFormat (PlainText)
  , ToolCall (..)
  , ToolResult (..)
  )
import Agent.SeaOfGoals.LLM.Backends.GPT
  ( defaultGPTEndpoint
  , loadGPTEndpointFromEnv
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
import Agent.SeaOfGoals.Scheduling.Graph
  ( reduceGoalGraph
  )
import Agent.SeaOfGoals.Scheduling.GraphChase
  ( ChaseEvent (..)
  , ChaseState (..)
  , GoalLaunch (..)
  , completeGoal
  , completeQueuedGoal
  , initialChaseState
  , nextReadyGoals
  , replanForMergeConflict
  , startReadyGoals
  )
import Agent.SeaOfGoals.Scheduling.MergeScheduler
  ( MergeDependencyUpdate (..)
  , applyMergeConflict
  , goalGraphDescendants
  )
import Agent.SeaOfGoals.Scheduling.PlannerResolution qualified as PlannerResolution
import Agent.SeaOfGoals.Scheduling.Replan
  ( ReplanInput (..)
  , ReplanResult (..)
  , replanAfterMergeConflict
  )
import Agent.SeaOfGoals.Scheduling.SerialScheduler
  ( SerialScheduler (..)
  , SerialSchedulerResult (..)
  , readyGoalNodes
  , runSerialScheduler
  )
import Agent.SeaOfGoals.Scheduling.SpeculativeChase qualified as Speculative
import Agent.SeaOfGoals.Scheduling.SpeculativeRunner qualified as SpeculativeRunner
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
  ( WorkflowNode (..)
  , WorkflowSpec (..)
  , workflowCompletedNodes
  , workflowLastNode
  , workflowTransitionWarnings
  )
import Agent.SeaOfGoals.Workspace.Backend
  ( Backend (..)
  , Diff (..)
  , Mount (..)
  , PathChange (..)
  )
import Agent.SeaOfGoals.Workspace.Bwrap.Command qualified as Bwrap
import Agent.SeaOfGoals.Workspace.Bwrap.Profile qualified as BwrapProfile
import Agent.SeaOfGoals.Workspace.ConflictPolicy
  ( AccessSets (..)
  , ConflictMode (..)
  , conflictingPaths
  )
import Agent.SeaOfGoals.Workspace.Containerd.Command qualified as Containerd
import Agent.SeaOfGoals.Workspace.Effects
  ( EffectScope (..)
  , ScopedEffects (..)
  , normalizeAccessEffects
  , scopeAccesses
  , scopedAccessConflict
  )
import Agent.SeaOfGoals.Workspace.Fuse.Merge
  ( FuseMergeInput (..)
  , MergeConflict (..)
  , mergeFuseSnapshots
  )
import Agent.SeaOfGoals.Workspace.Fuse.Store
  ( Access (..)
  , readSet
  , writeSet
  )
import Agent.SeaOfGoals.Workspace.Fuse.Store qualified as FuseStore
import Agent.SeaOfGoals.Workspace.ProcessExec
  ( ProcessExecSpec (..)
  , runProcessExecWithStdoutLineSink
  )
import Agent.SeaOfGoals.Workspace.Sandbox
  ( BindMode (..)
  , ExecSpec (..)
  , ExecTimeout (..)
  , SandboxExecOutcome (..)
  , SandboxRunner (..)
  )
import Agent.SeaOfGoals.Workspace.Sandbox.Process
  ( ProcessSandboxRunner (..)
  , ProcessSandboxSpec (..)
  )
import Agent.SeaOfGoals.Workspace.ToolRunner
  ( CommandToolResponse (..)
  , ToolRunner (..)
  )
import Agent.SeaOfGoals.Workspace.ToolRunner.Sandboxed
  ( SandboxedToolCall (..)
  , SandboxedToolError (..)
  , SandboxedToolRunner (..)
  , SandboxedToolRunnerEnv (..)
  , commandResponseToToolResult
  , parseCommandToolCall
  )
import Control.Concurrent
  ( forkIO
  , newEmptyMVar
  , putMVar
  , takeMVar
  , threadDelay
  )
import Control.Monad (when)
import Data.Aeson
  ( FromJSON (..)
  , Value
  , eitherDecode
  , encode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.ByteString qualified as ByteString
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock
  ( diffUTCTime
  , getCurrentTime
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getTemporaryDirectory
  , removePathForcibly
  , renameFile
  )
import System.Environment
  ( lookupEnv
  , setEnv
  , unsetEnv
  )
import System.Exit (exitFailure)
import System.FilePath ((</>))

main :: IO ()
main = do
  unicodeTransportResponseBodyTest
  gptEndpointEnvTest
  configFileTest
  compilerGraphValidationTest
  compilerPreloadPlannerPromptTest
  plannerResolutionParsingTest
  workspaceConflictPolicyTest
  goalContextPreloadTest
  goalGraphReductionTest
  codexProcessCommandTest
  processExecStreamingStdoutTest
  bwrapCommandRenderingTest
  containerdCommandRenderingTest
  fuseStoreWorkspaceTest
  fuseStoreAccessConflictTest
  fuseWorkspaceMergeTest
  rootOnlyEffectsTest
  accessNormalizationTest
  mergeSchedulerConflictTest
  replanAfterMergeConflictTest
  graphChaseSchedulerTest
  concurrentChaseSchedulerTest
  plannerChaseSchedulerTest
  serialSchedulerTest
  speculativeChaseSchedulerTest
  speculativeRunnerTest
  sandboxedToolCallTest
  eventsRef <- newIORef []
  provider <- newFakeProvider fakeResponses
  finalState <-
    runHarness
      HarnessConfig
        { harnessProvider = provider
        , harnessRequestTemplate = requestTemplate
        , harnessSystemPrompt = "Use tools."
        , harnessUserPrompt = "Run a tiny tool-call loop."
        , harnessInitialHistorySuffix = []
        , harnessTools = testTools
        , harnessMaxTurns = 8
        , harnessEventSink = \event -> modifyIORef' eventsRef (event :)
        , harnessRequiredSubgoal = Just ("S1", "tiny step")
        , harnessWorkflowSpec = Just testWorkflow
        }
  events <- reverse <$> readIORef eventsRef
  assertEqual
    "active subgoal is cleared"
    Nothing
    (harnessActiveSubgoal finalState)
  assertEqual
    "workflow completed node"
    (Set.singleton "S1")
    (workflowCompletedNodes (harnessWorkflowStatus finalState))
  assertEqual
    "workflow last node"
    (Just "S1")
    (workflowLastNode (harnessWorkflowStatus finalState))
  assertEqual
    "workflow warning for undeclared transition"
    []
    (workflowTransitionWarnings (harnessWorkflowStatus finalState))
  assertBool "subgoal started" (any isSubgoalStarted events)
  assertBool
    "harness records the assigned goal name"
    (any isAssignedGoalName events)
  assertBool "effect was assigned to active subgoal" (any isEffectForS1 events)
  assertBool "workflow status was observed" (any isWorkflowStatusForS1 events)
  assertBool "shell tool was called" (any (isToolCall "shell") events)
  assertBool "shell output was observed" (any isShellResult events)
  assertBool "subgoal ended" (any isSubgoalEnded events)
  assertBool "harness finished" (any isHarnessFinished events)
  putStrLn "Harness tool-call loop test passed."
  harnessParallelToolCallsTest
  harnessRequiredGoalTest
  harnessWithoutGoalTest

workspaceConflictPolicyTest :: IO ()
workspaceConflictPolicyTest = do
  let
    current =
      AccessSets
        { accessReads = Set.fromList ["config.json", "input.txt"]
        , accessWrites = Set.fromList ["dist", "output.txt"]
        , accessRegularFileWrites = Set.singleton "output.txt"
        }
    accepted =
      AccessSets
        { accessReads = Set.fromList ["output.txt", "dist"]
        , accessWrites = Set.fromList ["dist", "config.json"]
        , accessRegularFileWrites = Set.singleton "config.json"
        }
  assertEqual
    "strict conflicts include directory and file access conflicts"
    (Set.fromList ["config.json", "dist", "output.txt"])
    (conflictingPaths StrictAccessConflicts current accepted)
  assertEqual
    "file-writes-only ignores directory writes but retains file read/write conflicts"
    (Set.fromList ["config.json", "output.txt"])
    (conflictingPaths FileWriteConflictsOnly current accepted)
  assertEqual
    "file-writes-only detects regular-file write/write conflicts"
    (Set.singleton "same.txt")
    ( conflictingPaths
        FileWriteConflictsOnly
        (AccessSets Set.empty (Set.singleton "same.txt") (Set.singleton "same.txt"))
        (AccessSets Set.empty (Set.singleton "same.txt") (Set.singleton "same.txt"))
    )

unicodeTransportResponseBodyTest :: IO ()
unicodeTransportResponseBodyTest = do
  let
    payload = object ["name" .= ("迁移安全检查清单" :: Text)]
    response =
      TransportResponse
        { transportStatus = 200
        , transportResponseHeaders = []
        , transportResponseBody = encode payload
        , transportResponseJSON = Just payload
        }
  assertEqual
    "transport response body keeps UTF-8 JSON bytes"
    (Right payload)
    (eitherDecode (transportResponseBody response) :: Either String Value)

gptEndpointEnvTest :: IO ()
gptEndpointEnvTest =
  withEnvVar "OPENAI_CHAT_COMPLETIONS_URL" Nothing $
    withEnvVar "OPENAI_BASE_URL" Nothing $ do
      defaultEndpoint <- loadGPTEndpointFromEnv
      assertEqual "default GPT endpoint" defaultGPTEndpoint defaultEndpoint
      withEnvVar "OPENAI_BASE_URL" (Just "https://risellm.snakin.top/v1") $ do
        riseEndpoint <- loadGPTEndpointFromEnv
        assertEqual
          "OPENAI_BASE_URL is expanded to responses endpoint"
          "https://risellm.snakin.top/v1/responses"
          riseEndpoint
      withEnvVar
        "OPENAI_RESPONSES_URL"
        (Just "https://example.test/custom/responses")
        $ do
          explicitResponsesEndpoint <- loadGPTEndpointFromEnv
          assertEqual
            "explicit responses URL wins"
            "https://example.test/custom/responses"
            explicitResponsesEndpoint
      withEnvVar
        "OPENAI_CHAT_COMPLETIONS_URL"
        (Just "https://example.test/custom/chat")
        $ do
          explicitEndpoint <- loadGPTEndpointFromEnv
          assertEqual
            "explicit chat completions URL wins"
            "https://example.test/custom/chat"
            explicitEndpoint

configFileTest :: IO ()
configFileTest = do
  assertEqual
    "default concurrent chase parallelism is four"
    4
    ( concurrentChaseConfigMaxParallelism
        (configConcurrentChase defaultConfig)
    )
  tempRoot <- getTemporaryDirectory
  let
    configRoot = tempRoot </> "sog-config-test"
    configPath = configRoot </> "seaofgoals.config.json"
  removePathForcibly configRoot
  createDirectoryIfMissing True configRoot
  ByteString.writeFile
    configPath
    "{ \"concurrentChase\": { \"maxParallelism\": 4, \"maxReplans\": 7 } }"
  loaded <- loadConfigFile configPath
  assertEqual
    "config file controls concurrent chase parallelism"
    4
    ( concurrentChaseConfigMaxParallelism
        (configConcurrentChase loaded)
    )
  assertEqual
    "config file controls concurrent chase max replans"
    7
    ( concurrentChaseConfigMaxReplans
        (configConcurrentChase loaded)
    )

compilerGraphValidationTest :: IO ()
compilerGraphValidationTest = do
  assertEqual
    "valid compiler DAG"
    []
    (validateCompiledGoalGraph validCompilerGraph)
  let convertedGraph = compiledGraphToGoalGraph validCompilerGraph
  assertEqual
    "compiled graph preserves goal array as serial order"
    [0, 1]
    ( goalNodeSerialIndex
        <$> Map.elems (goalGraphNodes convertedGraph)
    )
  assertBool
    "compiled graph converts predecessors to scheduler edges"
    ( Set.member
        (goalId "G001", goalId "G002")
        (goalGraphEdges convertedGraph)
    )
  assertBool
    "compiler DAG rejects unknown predecessor"
    (not (null (validateCompiledGoalGraph unknownPredecessorCompilerGraph)))
  assertBool
    "compiler DAG rejects cycle"
    (not (null (validateCompiledGoalGraph cyclicCompilerGraph)))

compilerPreloadPlannerPromptTest :: IO ()
compilerPreloadPlannerPromptTest = do
  let prompt = compilerCodexPromptWithPreloadPlanner True "demo" "raw skill"
  assertBool
    "compiler preload planner prompt inserts G000"
    ("id G000" `Text.isInfixOf` prompt)
  assertBool
    "compiler preload planner prompt names preload plan tool"
    ("set_preload_plan" `Text.isInfixOf` prompt)
  assertBool
    "compiler preload planner prompt names goal resolution tool"
    ("set_goal_resolution" `Text.isInfixOf` prompt)
  let speculativePrompt = compilerCodexPromptForStrategy OrderedSpeculativeCompilerStrategy False "demo" "raw skill"
  assertBool
    "ordered speculative compiler prompt makes list order canonical"
    ("only execution order" `Text.isInfixOf` speculativePrompt)
  assertBool
    "ordered speculative compiler prompt forbids DAG predecessors"
    ("Emit no predecessor edges" `Text.isInfixOf` speculativePrompt)

plannerResolutionParsingTest :: IO ()
plannerResolutionParsingTest = do
  assertEqual
    "planner resolution parses read-only completion"
    ( Right
        PlannerResolution.Resolution
          { PlannerResolution.resolutionGoalId = "G001"
          , PlannerResolution.resolutionKind = PlannerResolution.CompletedByPlanner
          , PlannerResolution.resolutionContext = "Audit complete."
          }
    )
    ( PlannerResolution.decodeResolution
        "{\"goal_id\":\"G001\",\"kind\":\"completed_by_planner\",\"context\":\"Audit complete.\"}"
    )
  assertBool
    "planner resolution rejects unknown kinds"
    ( case PlannerResolution.decodeResolution
        "{\"goal_id\":\"G002\",\"kind\":\"write_complete\",\"context\":\"bad\"}" of
        Left _ -> True
        Right _ -> False
    )

goalContextPreloadTest :: IO ()
goalContextPreloadTest = do
  tempRoot <- getTemporaryDirectory
  let root = tempRoot </> "sog-goal-context-preload-test"
  removePathForcibly root
  createDirectoryIfMissing True (root </> "src")
  ByteString.writeFile
    (root </> "src" </> "ColorMenu.tsx")
    "export const ColorMenu = 1;\n"
  ByteString.writeFile
    (root </> "src" </> "SearchBox.tsx")
    "export const SearchBox = 1;\n"
  rendered <-
    preloadedGoalContextText
      <$> preloadGoalContextDetailed
        GoalContextPreloadConfig
          { goalContextPreloadEnabled = True
          , goalContextPreloadMaxFiles = 4
          , goalContextPreloadMaxBytesPerFile = 1024
          , goalContextPreloadMaxDirectoryEntries = 20
          }
        root
        "Implement ColorMenu widget"
  preloaded <-
    preloadGoalContextDetailed
      GoalContextPreloadConfig
        { goalContextPreloadEnabled = True
        , goalContextPreloadMaxFiles = 4
        , goalContextPreloadMaxBytesPerFile = 1024
        , goalContextPreloadMaxDirectoryEntries = 20
        }
      root
      "Implement ColorMenu widget"
  assertBool
    "preload includes marker"
    ("<preloaded_workspace_context>" `Text.isInfixOf` rendered)
  assertBool
    "preload includes selected path"
    ("src/ColorMenu.tsx" `Text.isInfixOf` rendered)
  assertBool
    "preload includes selected content"
    ("export const ColorMenu" `Text.isInfixOf` rendered)
  assertBool
    "preload lists unselected path"
    ("src/SearchBox.tsx" `Text.isInfixOf` rendered)
  assertEqual
    "preload records selected files as reads"
    (Set.fromList ["src/ColorMenu.tsx"])
    (preloadedGoalContextReads preloaded)
  assertBool
    "preload synthetic history includes tool call"
    (any isPreloadToolCall (preloadedGoalContextHistory preloaded))
  assertBool
    "preload synthetic history includes tool result"
    (any isPreloadToolResult (preloadedGoalContextHistory preloaded))
  plannedRendered <-
    preloadedGoalContextText
      <$> preloadGoalContextWithPlanDetailed
        GoalContextPreloadConfig
          { goalContextPreloadEnabled = True
          , goalContextPreloadMaxFiles = 4
          , goalContextPreloadMaxBytesPerFile = 1024
          , goalContextPreloadMaxDirectoryEntries = 20
          }
        (Just ["src/SearchBox.tsx"])
        root
        "Implement a widget that does not name the planned file"
  assertBool
    "preload plan includes selected content"
    ("export const SearchBox" `Text.isInfixOf` plannedRendered)
  plannedPreloaded <-
    preloadGoalContextWithPlanDetailed
      GoalContextPreloadConfig
        { goalContextPreloadEnabled = True
        , goalContextPreloadMaxFiles = 4
        , goalContextPreloadMaxBytesPerFile = 1024
        , goalContextPreloadMaxDirectoryEntries = 20
        }
      (Just ["src/SearchBox.tsx"])
      root
      "Implement a widget that does not name the planned file"
  assertEqual
    "preload plan records planned files as reads"
    (Set.fromList ["src/SearchBox.tsx"])
    (preloadedGoalContextReads plannedPreloaded)
  let
    futurePlan = Just ["src/Moved.tsx", "src/Created.tsx", "src/Missing.tsx"]
    futureConfig = defaultGoalContextPreloadConfig{goalContextPreloadEnabled = True}
  renameFile (root </> "src/SearchBox.tsx") (root </> "src/Moved.tsx")
  ByteString.writeFile (root </> "src/Created.tsx") "export const Created = 2;\n"
  futurePreloaded <-
    preloadGoalContextWithPlanDetailed
      futureConfig
      futurePlan
      root
      "Validate merged results"
  assertBool
    "preload resolves created and moved files at goal entry"
    ( all
        (`Text.isInfixOf` preloadedGoalContextText futurePreloaded)
        [ "BEGIN FILE src/Moved.tsx"
        , "export const SearchBox"
        , "BEGIN FILE src/Created.tsx"
        , "export const Created"
        ]
    )
  assertBool
    "missing prediction is reported in synthetic tool history"
    ( any
        ( \case
            ToolResultInput result ->
              "[unavailable: planned file"
                `Text.isInfixOf` Text.concat [content | TextPart content <- toolResultContent result]
            _ -> False
        )
        (preloadedGoalContextHistory futurePreloaded)
    )
  assertEqual
    "preload records missing read attempts as dependencies"
    (Set.fromList ["src/Moved.tsx", "src/Created.tsx", "src/Missing.tsx"])
    (preloadedGoalContextReads futurePreloaded)
  let plannedPaths = ["src/Planned" <> show i <> ".ts" | i <- [1 .. 20 :: Int]]
  mapM_
    (\path -> ByteString.writeFile (root </> path) "export const value = 1;\n")
    plannedPaths
  completePlan <-
    preloadGoalContextWithPlanDetailed
      futureConfig
      (Just plannedPaths)
      root
      "Validate"
  assertEqual
    "explicit preload plan is not truncated by the automatic file limit"
    (Set.fromList plannedPaths)
    (preloadedGoalContextReads completePlan)
  assertBool
    "every explicitly planned file reaches synthetic history"
    ( all
        ( \_path ->
            any
              ( \case
                  ToolResultInput result ->
                    Text.pack ("export const value = 1;\n")
                      `Text.isInfixOf` Text.concat [content | TextPart content <- toolResultContent result]
                  _ -> False
              )
              (preloadedGoalContextHistory completePlan)
        )
        plannedPaths
    )
  automaticPlan <-
    preloadGoalContextWithPlanDetailed futureConfig Nothing root "Planned"
  assertEqual
    "automatic preload selection is not truncated by the default"
    (Set.size (Set.fromList plannedPaths))
    (Set.size (preloadedGoalContextReads automaticPlan))
  unsafePreloaded <-
    preloadGoalContextWithPlanDetailed
      futureConfig
      ( Just
          ["../outside.ts", "/outside.ts", ".sog/private.ts", "node_modules/private.ts"]
      )
      root
      "Validate"
  assertEqual
    "planned paths stay inside permitted workspace sources"
    Set.empty
    (preloadedGoalContextReads unsafePreloaded)
  disabledRendered <-
    preloadGoalContext
      GoalContextPreloadConfig
        { goalContextPreloadEnabled = False
        , goalContextPreloadMaxFiles = 4
        , goalContextPreloadMaxBytesPerFile = 1024
        , goalContextPreloadMaxDirectoryEntries = 20
        }
      root
      "Implement ColorMenu widget"
  assertEqual "disabled old preload API stays empty" "" disabledRendered
  disabledPlannedRendered <-
    preloadGoalContextWithPlan
      GoalContextPreloadConfig
        { goalContextPreloadEnabled = False
        , goalContextPreloadMaxFiles = 4
        , goalContextPreloadMaxBytesPerFile = 1024
        , goalContextPreloadMaxDirectoryEntries = 20
        }
      (Just ["src/SearchBox.tsx"])
      root
      "Implement SearchBox widget"
  assertEqual
    "disabled old planned preload API stays empty"
    ""
    disabledPlannedRendered
  removePathForcibly root

goalGraphReductionTest :: IO ()
goalGraphReductionTest = do
  let
    graph =
      GoalGraph
        { goalGraphNodes =
            Map.fromList
              [ (goalId "G001", schedulerGoal "G001" 0)
              , (goalId "G002", schedulerGoal "G002" 1)
              , (goalId "G003", schedulerGoal "G003" 2)
              ]
        , goalGraphEdges =
            Set.fromList
              [ (goalId "G001", goalId "G002")
              , (goalId "G002", goalId "G003")
              , (goalId "G001", goalId "G003")
              ]
        }
    reduced = reduceGoalGraph graph
    converted =
      compiledGraphToGoalGraph
        CompiledGoalGraph
          { compiledSkill = "test"
          , compiledGoals =
              [ compilerGoal "G001" []
              , compilerGoal "G002" ["G001"]
              , compilerGoal "G003" ["G001", "G002"]
              ]
          }

  assertEqual
    "goal graph reduction removes transitive edges"
    ( Set.fromList
        [ (goalId "G001", goalId "G002")
        , (goalId "G002", goalId "G003")
        ]
    )
    (goalGraphEdges reduced)
  assertEqual
    "compiled graph conversion keeps only direct predecessor edges"
    (goalGraphEdges reduced)
    (goalGraphEdges converted)

codexProcessCommandTest :: IO ()
codexProcessCommandTest = do
  defaults <- defaultCodexProcessConfig
  let
    config =
      defaults
        { codexProcessBwrapBinary = "bwrap"
        , codexProcessHostCodexHome = "/host/codex-home"
        , codexProcessSandboxCodexBinary = "/codex-home/bin/codex"
        , codexProcessModel = "gpt-test"
        }
    spec =
      codexProcessExecSpec
        config
        "/sog-control/prompt.txt"
        "/sog-control/last.txt"
    view = codexProcessView config "/tmp/workspace"
    command = Bwrap.bwrapCommand (Bwrap.Config "bwrap") view spec
    rendered = Text.pack (unwords command)
  assertBool
    "codex command runs through bwrap"
    ("bwrap" `elem` command)
  assertBool
    "codex home is mounted"
    (hasSubsequence ["--bind", "/host/codex-home", "/codex-home"] command)
  assertBool
    "codex exec reads prompt from sandbox control mount"
    ("/sog-control/prompt.txt" `Text.isInfixOf` rendered)
  assertBool
    "codex exec writes last message in sandbox control mount"
    ("/sog-control/last.txt" `Text.isInfixOf` rendered)
  assertBool
    "codex exec receives model through environment"
    (hasSubsequence ["--setenv", "SOG_MODEL", "gpt-test"] command)

processExecStreamingStdoutTest :: IO ()
processExecStreamingStdoutTest = do
  linesRef <- newIORef []
  outcome <-
    runProcessExecWithStdoutLineSink
      ProcessExecSpec
        { processExecArgv = ["sh", "-c", "printf 'one\\ntwo\\n'"]
        , processExecCwd = Nothing
        , processExecEnv = Nothing
        , processExecTimeout = ExecNoTimeout
        , processExecStdin = Nothing
        }
      (\line -> modifyIORef' linesRef (<> [line]))
  observedLines <- readIORef linesRef
  assertEqual
    "streaming stdout sink sees each line"
    ["one", "two"]
    observedLines
  assertEqual
    "streaming stdout preserves full captured stdout"
    "one\ntwo\n"
    (sandboxExecStdout outcome)

bwrapCommandRenderingTest :: IO ()
bwrapCommandRenderingTest = do
  let
    view =
      BwrapProfile.demoWorkspaceOnlyView
        BwrapProfile.DemoPaths
          { demoWorkspaceHostPath = "/tmp/sog/workspace"
          , demoCacheHostPath = "/tmp/sog/cache"
          , demoHomeHostPath = "/tmp/sog/home"
          , demoTmpHostPath = "/tmp/sog/tmp"
          }
    spec =
      ExecSpec
        { execArgv = ["sh", "-c", "pwd && echo $HOME && echo $FOO"]
        , execCwd = "."
        , execEnv = [("FOO", "bar")]
        , execTimeout = ExecTimeoutSeconds 5
        }
    command = Bwrap.bwrapCommand (Bwrap.Config "bwrap") view spec

  assertBool
    "bwrap command creates tmpfs root"
    (hasSubsequence ["--tmpfs", "/"] command)
  assertBool
    "bwrap command ro-binds host usr"
    (hasSubsequence ["--ro-bind", "/usr", "/usr"] command)
  assertBool
    "bwrap command binds workspace read-write"
    (hasSubsequence ["--bind", "/tmp/sog/workspace", "/workspace"] command)
  assertBool
    "bwrap command binds cache read-write"
    (hasSubsequence ["--bind", "/tmp/sog/cache", "/cache"] command)
  assertBool
    "bwrap command binds synthetic home read-write"
    (hasSubsequence ["--bind", "/tmp/sog/home", "/home/sog"] command)
  assertBool
    "bwrap command rewrites HOME"
    (hasSubsequence ["--setenv", "HOME", "/home/sog"] command)
  assertBool
    "bwrap command redirects cabal store outside workspace"
    ( hasSubsequence
        ["--setenv", "CABAL_STORE_DIR", "/cache/cabal-store"]
        command
    )
  assertBool
    "bwrap command keeps task-specific env"
    (hasSubsequence ["--setenv", "FOO", "bar"] command)
  assertBool
    "bwrap command defaults cwd to workspace"
    (hasSubsequence ["--chdir", "/workspace"] command)
  assertEqual
    "bwrap command appends argv after separator"
    ["--", "sh", "-c", "pwd && echo $HOME && echo $FOO"]
    (drop (length command - 4) command)

containerdCommandRenderingTest :: IO ()
containerdCommandRenderingTest = do
  let
    config =
      Containerd.Config
        { configBinary = "ctr"
        , configNamespace = Just "sog"
        , configAddress = Just "/run/containerd/containerd.sock"
        , configSnapshotter = Just "overlayfs"
        }
    spec =
      Containerd.TaskSpec
        { taskId = "goal/one"
        , taskRoot = Containerd.Image "docker.io/library/alpine:latest"
        , taskMounts =
            [ Containerd.Mount
                { mountHostPath = "/tmp/sog-mount"
                , mountContainerPath = "/workspace"
                , mountMode = BindReadWrite
                }
            ]
        , taskLabels = Map.singleton "sog.goal" "goal/one"
        , taskInitArgv = ["sleep", "infinity"]
        }
    handle =
      Containerd.Handle
        { handleId = Containerd.containerdContainerId "goal/one"
        , handleConfig = config
        }
    execSpec =
      ExecSpec
        { execArgv = ["sh", "-c", "pwd && echo $FOO"]
        , execCwd = "."
        , execEnv = [("FOO", "bar")]
        , execTimeout = ExecTimeoutSeconds 5
        }

  assertEqual
    "containerd task id is sanitized"
    "sog-goal-one"
    (Containerd.containerdContainerId "goal/one")
  assertEqual
    "containerd task id replaces path and shell-hostile characters"
    "sog-goal-two--tmp---"
    (Containerd.containerdContainerId "goal two:/tmp/迁移")
  assertEqual
    "containerd create command includes namespace, snapshotter, mount, label, and init"
    [ "ctr"
    , "--address"
    , "/run/containerd/containerd.sock"
    , "--namespace"
    , "sog"
    , "containers"
    , "create"
    , "--snapshotter"
    , "overlayfs"
    , "--mount"
    , "type=bind,src=/tmp/sog-mount,dst=/workspace,options=rbind:rw"
    , "--label"
    , "sog.goal=goal/one"
    , "docker.io/library/alpine:latest"
    , "sog-goal-one"
    , "sleep"
    , "infinity"
    ]
    (Containerd.containerdCreateArgs config spec)
  assertBool
    "containerd create command can render read-only mounts"
    ( "type=bind,src=/tmp/sog-readonly,dst=/readonly,options=rbind:ro"
        `elem` Containerd.containerdCreateArgs
          config
          spec
            { Containerd.taskMounts =
                [ Containerd.Mount
                    { mountHostPath = "/tmp/sog-readonly"
                    , mountContainerPath = "/readonly"
                    , mountMode = BindReadOnly
                    }
                ]
            }
    )
  assertEqual
    "containerd create command can render rootfs roots"
    [ "ctr"
    , "--address"
    , "/run/containerd/containerd.sock"
    , "--namespace"
    , "sog"
    , "containers"
    , "create"
    , "--snapshotter"
    , "overlayfs"
    , "--rootfs"
    , "/tmp/sog-rootfs"
    , "sog-goal-one"
    , "sleep"
    , "infinity"
    ]
    ( Containerd.containerdCreateArgs
        config
        spec
          { Containerd.taskRoot = Containerd.Rootfs "/tmp/sog-rootfs"
          , Containerd.taskMounts = []
          , Containerd.taskLabels = mempty
          }
    )
  assertEqual
    "containerd exec command defaults cwd to /workspace and prefixes env"
    [ "ctr"
    , "--address"
    , "/run/containerd/containerd.sock"
    , "--namespace"
    , "sog"
    , "tasks"
    , "exec"
    , "--exec-id"
    , "exec-1"
    , "--cwd"
    , "/workspace"
    , "sog-goal-one"
    , "env"
    , "FOO=bar"
    , "sh"
    , "-c"
    , "pwd && echo $FOO"
    ]
    (Containerd.containerdExecArgs config handle "exec-1" execSpec)
  assertEqual
    "containerd exec command preserves explicit cwd"
    [ "ctr"
    , "--address"
    , "/run/containerd/containerd.sock"
    , "--namespace"
    , "sog"
    , "tasks"
    , "exec"
    , "--exec-id"
    , "exec-2"
    , "--cwd"
    , "/workspace/subdir"
    , "sog-goal-one"
    , "pwd"
    ]
    ( Containerd.containerdExecArgs
        config
        handle
        "exec-2"
        execSpec
          { execArgv = ["pwd"]
          , execCwd = "/workspace/subdir"
          , execEnv = []
          }
    )

fuseStoreWorkspaceTest :: IO ()
fuseStoreWorkspaceTest = do
  tempRoot <- getTemporaryDirectory
  let
    root = tempRoot </> "sog-fuse-store-test"
    base = root </> "base"
    store = root </> "store"
  removePathForcibly root
  createDirectoryIfMissing True (base </> "src")
  ByteString.writeFile (base </> "src" </> "Main.hs") "main = putStrLn \"old\"\n"
  ByteString.writeFile (base </> "src" </> "Obsolete.hs") "obsolete\n"

  handle <-
    prepareWorkspace
      (FuseStore.Backend store)
      FuseStore.Spec
        { specTaskId = "task/one"
        , specBasePath = base
        , specAgentMountPath = "/workspace"
        }

  assertEqual
    "workspace exposes configured agent mount path"
    "/workspace"
    (mountAgentPath (mount (FuseStore.Backend store) handle))

  assertEqual
    "workspace reads unchanged base file"
    "main = putStrLn \"old\"\n"
    =<< FuseStore.readFile handle ("src" </> "Main.hs")

  FuseStore.writeFile handle ("src" </> "Main.hs") "main = putStrLn \"new\"\n"
  FuseStore.writeFile handle "README.md" "hello\n"
  FuseStore.deletePath handle ("src" </> "Obsolete.hs")

  assertEqual
    "workspace reads local modification"
    "main = putStrLn \"new\"\n"
    =<< FuseStore.readFile handle ("src" </> "Main.hs")
  assertEqual
    "workspace write does not mutate base"
    "main = putStrLn \"old\"\n"
    =<< ByteString.readFile (base </> "src" </> "Main.hs")

  diffValue <- diff (FuseStore.Backend store) handle
  assertEqual
    "workspace diff records changed paths"
    [ PathCreated "README.md"
    , PathModified ("src" </> "Main.hs")
    , PathDeleted ("src" </> "Obsolete.hs")
    ]
    (diffChanges diffValue)

  ByteString.writeFile
    (base </> "src" </> "Main.hs")
    "main = putStrLn \"conflict\"\n"
  finalized <- finalizeWorkspace (FuseStore.Backend store) handle
  case finalized of
    Left [conflict] ->
      assertEqual
        "workspace finalize reports conflicting path"
        ("src" </> "Main.hs")
        (FuseStore.conflictPath conflict)
    Left conflicts ->
      fail ("expected one workspace conflict, got " <> show conflicts)
    Right snapshot ->
      fail ("expected workspace conflict, got snapshot " <> show snapshot)

  localCreated <- doesFileExist (store </> "task_one" </> "files" </> "README.md")
  assertBool "workspace stores created file locally" localCreated

  accesses <- FuseStore.accessLog handle
  let accessCursor = length accesses
  FuseStore.writeFile handle "README.md" "updated\n"
  (nextCursor, newAccesses) <- FuseStore.accessLogSince accessCursor handle
  assertEqual "incremental access cursor advances after a new operation" (accessCursor + 1) nextCursor
  assertEqual "incremental access log excludes prior rounds" [FileModified "README.md"] newAccesses
  assertEqual
    "workspace read set records content reads"
    ( Set.fromList
        [ "src" </> "Main.hs"
        ]
    )
    ( Set.intersection
        (Set.fromList ["src" </> "Main.hs"])
        (readSet accesses)
    )
  assertEqual
    "workspace write set records changed paths"
    ( Set.fromList
        [ "README.md"
        , "src" </> "Main.hs"
        , "src" </> "Obsolete.hs"
        ]
    )
    (writeSet accesses)

fuseStoreAccessConflictTest :: IO ()
fuseStoreAccessConflictTest = do
  tempRoot <- getTemporaryDirectory
  let
    root = tempRoot </> "sog-fuse-access-conflict-test"
    base = root </> "base"
    store = root </> "store"
    backend = FuseStore.Backend store
  removePathForcibly root
  createDirectoryIfMissing True (base </> "src")
  ByteString.writeFile (base </> "src" </> "Input.txt") "old\n"
  ByteString.writeFile (base </> "src" </> "Shared.txt") "shared\n"
  ByteString.writeFile (base </> "src" </> "Other.txt") "other\n"

  reader <-
    prepareWorkspace
      backend
      FuseStore.Spec
        { specTaskId = "reader"
        , specBasePath = base
        , specAgentMountPath = "/workspace"
        }
  writer <-
    prepareWorkspace
      backend
      FuseStore.Spec
        { specTaskId = "writer"
        , specBasePath = base
        , specAgentMountPath = "/workspace"
        }

  _ <- FuseStore.readFile reader ("src" </> "Input.txt")
  _ <- FuseStore.statPath reader ("src" </> "Shared.txt")
  _ <- FuseStore.listDirectory reader "src"
  FuseStore.writeFile writer ("src" </> "Input.txt") "new\n"

  readerAccesses <- FuseStore.accessLog reader
  writerAccesses <- FuseStore.accessLog writer
  assertBool
    "write/access overlap is a baseline conflict"
    (FuseStore.accessConflict readerAccesses writerAccesses)
  assertEqual
    "reader access set records content, metadata, and directory reads"
    ( Set.fromList
        [ "src"
        , "src" </> "Input.txt"
        , "src" </> "Shared.txt"
        ]
    )
    (readSet readerAccesses)
  assertEqual
    "writer write set records modified file"
    (Set.singleton ("src" </> "Input.txt"))
    (writeSet writerAccesses)

  otherReader <-
    prepareWorkspace
      backend
      FuseStore.Spec
        { specTaskId = "other-reader"
        , specBasePath = base
        , specAgentMountPath = "/workspace"
        }
  _ <- FuseStore.readFile otherReader ("src" </> "Other.txt")
  otherReaderAccesses <- FuseStore.accessLog otherReader
  assertBool
    "read/read overlap is not a baseline conflict"
    (not (FuseStore.accessConflict readerAccesses otherReaderAccesses))

  directoryReader <-
    prepareWorkspace
      backend
      FuseStore.Spec
        { specTaskId = "directory-reader"
        , specBasePath = base
        , specAgentMountPath = "/workspace"
        }
  directoryWriter <-
    prepareWorkspace
      backend
      FuseStore.Spec
        { specTaskId = "directory-writer"
        , specBasePath = base
        , specAgentMountPath = "/workspace"
        }
  _ <- FuseStore.listDirectory directoryReader "src"
  FuseStore.writeFile directoryWriter ("src" </> "New.txt") "new\n"
  assertBool
    "directory read conflicts with child creation"
    =<< FuseStore.accessConflict
      <$> FuseStore.accessLog directoryReader
      <*> FuseStore.accessLog directoryWriter

fuseWorkspaceMergeTest :: IO ()
fuseWorkspaceMergeTest = do
  tempRoot <- getTemporaryDirectory
  let
    root = tempRoot </> "sog-fuse-merge-test"
    base = root </> "base"
    store = root </> "store"
    target = root </> "target"
    backend = FuseStore.Backend store
  removePathForcibly root
  createDirectoryIfMissing True (base </> "src")
  createDirectoryIfMissing True (target </> "src")
  ByteString.writeFile (base </> "src" </> "A.txt") "old-a\n"
  ByteString.writeFile (base </> "src" </> "B.txt") "old-b\n"
  ByteString.writeFile (base </> "src" </> "Obsolete.txt") "old-obsolete\n"
  ByteString.writeFile (target </> "src" </> "A.txt") "old-a\n"
  ByteString.writeFile (target </> "src" </> "B.txt") "old-b\n"
  ByteString.writeFile (target </> "src" </> "Obsolete.txt") "old-obsolete\n"

  former <-
    prepareWorkspace
      backend
      FuseStore.Spec
        { specTaskId = "former"
        , specBasePath = base
        , specAgentMountPath = "/workspace"
        }
  latter <-
    prepareWorkspace
      backend
      FuseStore.Spec
        { specTaskId = "latter"
        , specBasePath = base
        , specAgentMountPath = "/workspace"
        }
  FuseStore.writeFile former ("src" </> "A.txt") "new-a\n"
  FuseStore.deletePath former ("src" </> "Obsolete.txt")
  FuseStore.writeFile latter ("src" </> "B.txt") "new-b\n"
  formerInput <- mergeInputOrFail backend former
  latterInput <- mergeInputOrFail backend latter

  result <-
    mergeFuseSnapshots
      (RootOnly "/workspace")
      target
      [formerInput, latterInput]
  case result of
    Left conflict ->
      fail ("expected workspace merge success, got " <> show conflict)
    Right _ -> pure ()
  assertEqual
    "workspace merge applies former modification"
    "new-a\n"
    =<< ByteString.readFile (target </> "src" </> "A.txt")
  assertEqual
    "workspace merge applies latter modification"
    "new-b\n"
    =<< ByteString.readFile (target </> "src" </> "B.txt")
  obsoleteExists <- doesFileExist (target </> "src" </> "Obsolete.txt")
  assertBool "workspace merge applies deletion" (not obsoleteExists)

  conflictReader <-
    prepareWorkspace
      backend
      FuseStore.Spec
        { specTaskId = "conflict-reader"
        , specBasePath = base
        , specAgentMountPath = "/workspace"
        }
  conflictWriter <-
    prepareWorkspace
      backend
      FuseStore.Spec
        { specTaskId = "conflict-writer"
        , specBasePath = base
        , specAgentMountPath = "/workspace"
        }
  _ <- FuseStore.readFile conflictReader ("src" </> "A.txt")
  FuseStore.writeFile conflictWriter ("src" </> "A.txt") "conflict\n"
  conflictReaderInput <- mergeInputOrFail backend conflictReader
  conflictWriterInput <- mergeInputOrFail backend conflictWriter
  conflictResult <-
    mergeFuseSnapshots
      (RootOnly "/workspace")
      target
      [conflictReaderInput, conflictWriterInput]
  case conflictResult of
    Left
      AccessConflict
        { mergeFormerTask = "conflict-reader"
        , mergeLatterTask = "conflict-writer"
        } -> pure ()
    Left conflict ->
      fail ("unexpected workspace merge conflict shape: " <> show conflict)
    Right success ->
      fail ("expected workspace merge conflict, got " <> show success)

mergeInputOrFail
  :: FuseStore.Backend -> FuseStore.Handle -> IO FuseMergeInput
mergeInputOrFail backend handle = do
  snapshotResult <- finalizeWorkspace backend handle
  accesses <- FuseStore.accessLog handle
  case snapshotResult of
    Left conflicts ->
      fail ("expected finalized workspace, got conflicts " <> show conflicts)
    Right snapshot ->
      pure
        FuseMergeInput
          { fuseMergeInputSnapshot = snapshot
          , fuseMergeInputAccesses = accesses
          }

rootOnlyEffectsTest :: IO ()
rootOnlyEffectsTest = do
  let
    scope = RootOnly "/workspace"
    rawAccesses =
      [ ContentRead "/workspace/src/Input.txt"
      , FileModified "/home/host/.cache/tool/state"
      , DirectoryRead "src"
      , FileRenamed
          "/workspace/src/Old.txt"
          "/home/host/.cache/tool/Old.txt"
      , FileRenamed
          "/home/host/.cache/tool/New.txt"
          "/workspace/src/New.txt"
      ]
    scoped = scopeAccesses scope rawAccesses

  assertEqual
    "workspace-only scope keeps workspace paths and relative paths"
    [ ContentRead ("src" </> "Input.txt")
    , DirectoryRead "src"
    , FileDeleted ("src" </> "Old.txt")
    , FileCreated ("src" </> "New.txt")
    ]
    (scopedAccesses scoped)
  assertEqual
    "workspace-only scope records ignored external accesses"
    [ FileModified "/home/host/.cache/tool/state"
    ]
    (scopedIgnoredExternalAccesses scoped)
  assertBool
    "workspace-only conflict ignores external writes"
    ( not
        ( scopedAccessConflict
            scope
            [ContentRead "/workspace/src/Input.txt"]
            [FileModified "/home/host/.cache/tool/state"]
        )
    )
  assertBool
    "workspace-only conflict keeps workspace write/read dependency"
    ( scopedAccessConflict
        scope
        [ContentRead "/workspace/src/Input.txt"]
        [FileModified "/workspace/src/Input.txt"]
    )

accessNormalizationTest :: IO ()
accessNormalizationTest = do
  let scope = RootOnly "/workspace"

  assertEqual
    "rename is normalized to delete plus create"
    [ FileDeleted ("src" </> "Old.txt")
    , FileCreated ("src" </> "New.txt")
    ]
    ( normalizeAccessEffects
        [FileRenamed ("src" </> "Old.txt") ("src" </> "New.txt")]
    )
  assertEqual
    "workspace scoped rename is normalized"
    [ FileDeleted ("src" </> "Old.txt")
    , FileCreated ("src" </> "New.txt")
    ]
    ( scopedAccesses
        ( scopeAccesses
            scope
            [ FileRenamed
                "/workspace/src/Old.txt"
                "/workspace/src/New.txt"
            ]
        )
    )
  assertBool
    "rename conflicts with a read of the old path"
    ( scopedAccessConflict
        scope
        [FileRenamed "/workspace/src/Old.txt" "/workspace/src/New.txt"]
        [ContentRead "/workspace/src/Old.txt"]
    )
  assertBool
    "rename conflicts with a read of the new path"
    ( scopedAccessConflict
        scope
        [FileRenamed "/workspace/src/Old.txt" "/workspace/src/New.txt"]
        [ContentRead "/workspace/src/New.txt"]
    )

mergeSchedulerConflictTest :: IO ()
mergeSchedulerConflictTest = do
  let graph =
        GoalGraph
          { goalGraphNodes =
              Map.fromList
                [ (goalId "S1", schedulerGoal "S1" 1)
                , (goalId "S2", schedulerGoal "S2" 2)
                , (goalId "S3", schedulerGoal "S3" 3)
                , (goalId "S4", schedulerGoal "S4" 4)
                ]
          , goalGraphEdges =
              Set.fromList
                [ (goalId "S2", goalId "S3")
                , (goalId "S3", goalId "S4")
                ]
          }

  assertEqual
    "goal graph descendants are transitive"
    (Set.fromList [goalId "S3", goalId "S4"])
    (goalGraphDescendants graph (goalId "S2"))
  case applyMergeConflict graph (goalId "S2") (goalId "S1") of
    Left err ->
      fail ("expected scheduler update, got " <> Text.unpack err)
    Right update -> do
      assertEqual
        "merge conflict is directed by serial order"
        (goalId "S1")
        (mergeDependencyFormer update)
      assertEqual
        "merge conflict invalidates the serially later goal"
        (goalId "S2")
        (mergeDependencyLatter update)
      assertBool
        "merge conflict adds the discovered dependency edge"
        ( Set.member
            (goalId "S1", goalId "S2")
            (goalGraphEdges (mergeDependencyGraph update))
        )
      assertEqual
        "merge conflict invalidates latter and descendants"
        (Set.fromList [goalId "S2", goalId "S3", goalId "S4"])
        (mergeDependencyInvalidated update)

replanAfterMergeConflictTest :: IO ()
replanAfterMergeConflictTest = do
  let
    graph =
      GoalGraph
        { goalGraphNodes =
            Map.fromList
              [ (goalId "S1", schedulerGoal "S1" 1)
              , (goalId "S2", schedulerGoal "S2" 2)
              , (goalId "S3", schedulerGoal "S3" 3)
              , (goalId "S4", schedulerGoal "S4" 4)
              , (goalId "S5", schedulerGoal "S5" 5)
              ]
        , goalGraphEdges =
            Set.fromList
              [ (goalId "S2", goalId "S3")
              , (goalId "S3", goalId "S4")
              ]
        }
    completed =
      Map.fromList
        [ (goalId "S1", fakeAgentRunResult (schedulerGoal "S1" 1))
        , (goalId "S2", fakeAgentRunResult (schedulerGoal "S2" 2))
        , (goalId "S3", fakeAgentRunResult (schedulerGoal "S3" 3))
        ]
    input =
      ReplanInput
        { replanInputGraph = graph
        , replanInputCompleted = completed
        , replanInputQueued = Set.fromList [goalId "S4", goalId "S5"]
        , replanInputRunning = Set.singleton (goalId "S3")
        , replanInputConflictLeft = goalId "S2"
        , replanInputConflictRight = goalId "S1"
        }

  case replanAfterMergeConflict input of
    Left err ->
      fail ("expected replan result, got " <> Text.unpack err)
    Right result -> do
      assertEqual
        "replan keeps completed former goal"
        (Set.singleton (goalId "S1"))
        (Map.keysSet (replanResultCompleted result))
      assertEqual
        "replan cancels invalidated queued/running work"
        (Set.fromList [goalId "S3", goalId "S4"])
        (replanResultCancelled result)
      assertBool
        "replan adds discovered dependency"
        ( Set.member
            (goalId "S1", goalId "S2")
            (goalGraphEdges (mergeDependencyGraph (replanResultDependencyUpdate result)))
        )
      assertEqual
        "replan queues invalidated work plus existing unaffected queued work"
        (Set.fromList [goalId "S2", goalId "S3", goalId "S4", goalId "S5"])
        (replanResultQueued result)
      assertEqual
        "replan exposes dependency-ready queued goals in serial order"
        [goalId "S2", goalId "S5"]
        (replanResultReady result)

graphChaseSchedulerTest :: IO ()
graphChaseSchedulerTest = do
  let
    graph =
      GoalGraph
        { goalGraphNodes =
            Map.fromList
              [ (goalId "S1", schedulerGoal "S1" 1)
              , (goalId "S2", schedulerGoal "S2" 2)
              , (goalId "S3", schedulerGoal "S3" 3)
              , (goalId "S4", schedulerGoal "S4" 4)
              ]
        , goalGraphEdges =
            Set.fromList
              [ (goalId "S2", goalId "S3")
              ]
        }
    initial = initialChaseState graph

  assertEqual
    "graph chase initially exposes dependency-ready queued goals"
    [goalId "S1", goalId "S2", goalId "S4"]
    (goalNodeId <$> nextReadyGoals initial)

  let (runningState, launches) = startReadyGoals 2 initial
  assertEqual
    "graph chase starts one concurrent batch in serial order"
    [goalId "S1", goalId "S2"]
    (goalNodeId . goalLaunchNode <$> launches)
  assertEqual
    "graph chase moves launched goals to running"
    (Set.fromList [goalId "S1", goalId "S2"])
    (chaseRunning runningState)
  assertEqual
    "graph chase keeps not-yet-started ready work queued"
    (Set.fromList [goalId "S3", goalId "S4"])
    (chaseQueued runningState)

  completedS1 <-
    either (fail . Text.unpack) pure $
      completeGoal (fakeAgentRunResult (schedulerGoal "S1" 1)) runningState
  completedS2 <-
    either (fail . Text.unpack) pure $
      completeGoal (fakeAgentRunResult (schedulerGoal "S2" 2)) completedS1
  resolvedS4 <-
    either (fail . Text.unpack) pure $
      completeQueuedGoal (fakeAgentRunResult (schedulerGoal "S4" 4)) completedS2
  assertEqual
    "graph chase records run and planner-resolved goals"
    (Set.fromList [goalId "S1", goalId "S2", goalId "S4"])
    (Map.keysSet (chaseCompleted resolvedS4))

  replanned <-
    either (fail . Text.unpack) pure $
      replanForMergeConflict (goalId "S2") (goalId "S1") resolvedS4
  assertEqual
    "graph chase keeps the serial former completed"
    (Set.fromList [goalId "S1", goalId "S4"])
    (Map.keysSet (chaseCompleted replanned))
  assertEqual
    "graph chase requeues invalidated latter and descendant"
    (Set.fromList [goalId "S2", goalId "S3"])
    (chaseQueued replanned)
  assertEqual
    "graph chase ready set follows updated dependency"
    [goalId "S2"]
    (goalNodeId <$> nextReadyGoals replanned)
  assertBool
    "graph chase records replan event"
    (any isReplanEvent (chaseEvents replanned))

concurrentChaseSchedulerTest :: IO ()
concurrentChaseSchedulerTest = do
  runCountsRef <- newIORef Map.empty
  mergedRef <- newIORef []
  conflictRef <- newIORef False
  let
    chaseConfig = configConcurrentChase defaultConfig
    graph =
      GoalGraph
        { goalGraphNodes =
            Map.fromList
              [ (goalId "S1", schedulerGoal "S1" 1)
              , (goalId "S2", schedulerGoal "S2" 2)
              , (goalId "S3", schedulerGoal "S3" 3)
              ]
        , goalGraphEdges =
            Set.fromList
              [ (goalId "S2", goalId "S3")
              ]
        }
    runner =
      ConcurrentChaseRunner
        { concurrentChaseMaxParallelism =
            concurrentChaseConfigMaxParallelism chaseConfig
        , concurrentChaseMaxReplans =
            concurrentChaseConfigMaxReplans chaseConfig
        , concurrentChaseRunGoal = \node -> do
            atomicModifyIORef'
              runCountsRef
              ( \counts ->
                  ( Map.insertWith (+) (goalNodeId node) (1 :: Int) counts
                  , ()
                  )
              )
            pure (Right (fakeAgentRunResult node))
        , concurrentChaseMergeGoal = \result -> do
            merged <- readIORef mergedRef
            conflictTriggered <- readIORef conflictRef
            if agentRunResultGoal result == goalId "S2"
              && goalId "S1" `elem` merged
              && not conflictTriggered
              then do
                writeIORef conflictRef True
                pure $
                  Left
                    ConcurrentChaseConflict
                      { concurrentChaseConflictLeft = goalId "S2"
                      , concurrentChaseConflictRight = goalId "S1"
                      , concurrentChaseConflictReason = "synthetic conflict"
                      }
              else do
                modifyIORef' mergedRef (<> [agentRunResultGoal result])
                pure (Right ())
        }

  result <- runConcurrentChase runner graph
  case result of
    Left err ->
      fail ("expected concurrent chase success, got " <> Text.unpack err)
    Right summary -> do
      runCounts <- readIORef runCountsRef
      assertEqual
        "concurrent chase reruns only the conflict-latter goal"
        ( Map.fromList
            [ (goalId "S1", 1 :: Int)
            , (goalId "S2", 2)
            , (goalId "S3", 1)
            ]
        )
        runCounts
      assertEqual
        "concurrent chase accepts every goal"
        (Set.fromList [goalId "S1", goalId "S2", goalId "S3"])
        (Map.keysSet (concurrentChaseCompleted summary))
      assertEqual
        "concurrent chase records successful merge order"
        [goalId "S1", goalId "S2", goalId "S3"]
        (concurrentChaseMergeOrder summary)
      assertEqual
        "concurrent chase records one replan"
        1
        (concurrentChaseReplans summary)
      assertBool
        "concurrent chase graph learns serial conflict dependency"
        ( Set.member
            (goalId "S1", goalId "S2")
            (goalGraphEdges (chaseGraph (concurrentChaseFinalState summary)))
        )

plannerChaseSchedulerTest :: IO ()
plannerChaseSchedulerTest = do
  plannedRef <- newIORef (Set.empty :: Set.Set GoalNodeId)
  resolvedRef <- newIORef False
  executionWhilePlanningRef <- newIORef False
  launchedRef <- newIORef []
  mergedRef <- newIORef []
  let
    graph =
      GoalGraph
        { goalGraphNodes =
            Map.fromList
              [ (goalId "G000", schedulerGoal "G000" 0)
              , (goalId "G001", schedulerGoal "G001" 1)
              , (goalId "G002", schedulerGoal "G002" 2)
              ]
        , goalGraphEdges = Set.singleton (goalId "G001", goalId "G002")
        }
    runner =
      ConcurrentChaseRunner
        { concurrentChaseMaxParallelism = 2
        , concurrentChaseMaxReplans = 0
        , concurrentChaseRunGoal = \node -> do
            if goalNodeId node == goalId "G000"
              then do
                atomicModifyIORef'
                  plannedRef
                  ( \ids ->
                      ( Set.insert (goalId "G002") ids
                      , ()
                      )
                  )
                writeIORef resolvedRef True
                threadDelay 100000
              else do
                modifyIORef' launchedRef (<> [goalNodeId node])
                planned <- readIORef plannedRef
                when (goalId "G002" `Set.member` planned) $
                  writeIORef executionWhilePlanningRef True
            pure (Right (fakeAgentRunResult node))
        , concurrentChaseMergeGoal = \result -> do
            modifyIORef' mergedRef (<> [agentRunResultGoal result])
            pure (Right ())
        }
  result <-
    runConcurrentChaseWithPlanner
      runner
      graph
      (goalId "G000")
      (\nodeId -> Set.member nodeId <$> readIORef plannedRef)
      ( \node -> do
          resolved <- readIORef resolvedRef
          pure $
            if resolved && goalNodeId node == goalId "G001"
              then Just (fakeAgentRunResult node)
              else Nothing
      )
  case result of
    Left err -> fail ("expected planner chase success, got " <> Text.unpack err)
    Right summary -> do
      assertEqual
        "planner chase excludes the planner and preserves serial merge order"
        [goalId "G002"]
        (concurrentChaseMergeOrder summary)
      assertEqual
        "planner chase records goals completed without agent launch"
        [goalId "G001"]
        (concurrentChaseResolvedOrder summary)
  overlapped <- readIORef executionWhilePlanningRef
  assertBool
    "planner chase starts a goal after its plan while planner is still running"
    overlapped
  merged <- readIORef mergedRef
  assertEqual
    "planner control work is not passed to workspace merge"
    [goalId "G002"]
    merged
  launched <- readIORef launchedRef
  assertEqual
    "planner-completed goal does not launch an agent"
    [goalId "G002"]
    launched

serialSchedulerTest :: IO ()
serialSchedulerTest = do
  let
    graph =
      GoalGraph
        { goalGraphNodes =
            Map.fromList
              [ (goalId "S1", schedulerGoal "S1" 1)
              , (goalId "S2", schedulerGoal "S2" 2)
              , (goalId "S3", schedulerGoal "S3" 3)
              ]
        , goalGraphEdges =
            Set.fromList
              [ (goalId "S1", goalId "S3")
              , (goalId "S2", goalId "S3")
              ]
        }
    scheduler =
      SerialScheduler
        { serialSchedulerRunGoal = pure . Right . fakeAgentRunResult
        }

  assertEqual
    "serial scheduler exposes initially ready goals in serial order"
    [goalId "S1", goalId "S2"]
    (goalNodeId <$> readyGoalNodes graph Set.empty)
  result <- runSerialScheduler scheduler graph
  case result of
    Left err ->
      fail ("expected serial scheduler success, got " <> Text.unpack err)
    Right summary -> do
      assertEqual
        "serial scheduler follows dependency-safe serial order"
        [goalId "S1", goalId "S2", goalId "S3"]
        (serialSchedulerRunOrder summary)
      assertEqual
        "serial scheduler records completed result for every node"
        (Set.fromList [goalId "S1", goalId "S2", goalId "S3"])
        (Map.keysSet (serialSchedulerCompleted summary))

  mismatchResult <-
    runSerialScheduler
      SerialScheduler
        { serialSchedulerRunGoal =
            \node -> pure (Right (fakeAgentRunResult node){agentRunResultGoal = goalId "wrong"})
        }
      graph
  case mismatchResult of
    Left "agent result goal id does not match scheduled goal" -> pure ()
    Left err -> fail ("unexpected serial scheduler mismatch error: " <> Text.unpack err)
    Right summary -> fail ("expected serial scheduler mismatch failure, got " <> show summary)

speculativeChaseSchedulerTest :: IO ()
speculativeChaseSchedulerTest = do
  let
    s1 = goalId "S1"
    s2 = goalId "S2"
    initial = Speculative.initialSpeculativeState [schedulerGoal "S1" 1, schedulerGoal "S2" 2]
    s1Writes = Speculative.EffectSet Set.empty (Set.singleton "generated.txt")
    s2Reads = Speculative.EffectSet (Set.singleton "generated.txt") Set.empty
    (afterS1Effects, initialAborts) = Speculative.recordEffects s1 s1Writes initial
    (afterS2Effects, aborted) = Speculative.recordEffects s2 s2Reads afterS1Effects

  assertEqual "a goal's own first writes do not abort later goals without observed effects" [] initialAborts
  assertEqual "an earlier write invalidates a later reader" [s2] aborted
  assertEqual
    "conflicting later goal is aborted"
    (Just (Speculative.SpeculativeAborted (Speculative.GoalEpoch 0)))
    (Map.lookup s2 (Speculative.speculativeGoalStatus afterS2Effects))

  let
    (afterS1Finish, committed) = Speculative.finishGoal s1 afterS2Effects
    restartedS2 = Speculative.restartGoal s2 afterS1Finish
    (afterRebasedRead, rebasedAborts) = Speculative.recordEffects s2 s2Reads restartedS2

  assertEqual "the finished prefix is committed in serial order" [s1] committed
  assertEqual
    "restart moves the goal to a new epoch"
    (Just (Speculative.SpeculativeRunning (Speculative.GoalEpoch 1)))
    (Map.lookup s2 (Speculative.speculativeGoalStatus restartedS2))
  assertEqual "a restarted goal reads from its committed base without being aborted again" [] rebasedAborts
  assertEqual
    "rebased read remains running"
    (Just (Speculative.SpeculativeRunning (Speculative.GoalEpoch 1)))
    (Map.lookup s2 (Speculative.speculativeGoalStatus afterRebasedRead))

  let
    reverseInitial = Speculative.initialSpeculativeState [schedulerGoal "S1" 1, schedulerGoal "S2" 2]
    s1Reads = Speculative.EffectSet (Set.singleton "config.json") Set.empty
    s2Writes = Speculative.EffectSet Set.empty (Set.singleton "config.json")
    (afterEarlyRead, _) = Speculative.recordEffects s1 s1Reads reverseInitial
    (_, reverseAborts) = Speculative.recordEffects s2 s2Writes afterEarlyRead

  assertEqual "an earlier read and later write is not an invalidating conflict" [] reverseAborts

speculativeRunnerTest :: IO ()
speculativeRunnerTest = do
  s1Ready <- newEmptyMVar
  allowS1Finish <- newEmptyMVar
  s2Epochs <- newIORef []
  _ <-
    forkIO $ do
      takeMVar s1Ready
      threadDelay 100000
      putMVar allowS1Finish ()
  result <-
    SpeculativeRunner.runSpeculativeChase
      SpeculativeRunner.SpeculativeChaseRunner
        { SpeculativeRunner.speculativeChaseRunGoal =
            \node epoch report ->
              case goalNodeId node of
                goal | goal == goalId "S1" -> do
                  report (Speculative.EffectSet Set.empty (Set.singleton "generated.txt"))
                  putMVar s1Ready ()
                  takeMVar allowS1Finish
                  pure (Right (fakeAgentRunResult node))
                _ -> do
                  modifyIORef' s2Epochs (<> [epoch])
                  report (Speculative.EffectSet (Set.singleton "generated.txt") Set.empty)
                  if epoch == Speculative.GoalEpoch 0
                    then threadDelay 10000000 >> pure (Right (fakeAgentRunResult node))
                    else pure (Right (fakeAgentRunResult node))
        , SpeculativeRunner.speculativeChaseMergeGoal = \_ -> pure (Right ())
        }
      [schedulerGoal "S1" 1, schedulerGoal "S2" 2]
  case result of
    Left err -> fail ("expected speculative runner success, got " <> Text.unpack err)
    Right summary -> do
      assertEqual "speculative runner commits in source order" [goalId "S1", goalId "S2"] (SpeculativeRunner.speculativeChaseCommitOrder summary)
      assertEqual "conflicting later goal is restarted after the prefix commits" [goalId "S2"] (SpeculativeRunner.speculativeChaseRestarted summary)
  observedEpochs <- readIORef s2Epochs
  assertEqual "restarted goal receives the rebased epoch" [Speculative.GoalEpoch 0, Speculative.GoalEpoch 1] observedEpochs

sandboxedToolCallTest :: IO ()
sandboxedToolCallTest = do
  tempRoot <- getTemporaryDirectory
  let workspace = tempRoot </> "sog-sandboxed-tool-test"
  removePathForcibly workspace
  createDirectoryIfMissing True workspace
  let runner = ProcessSandboxRunner
  sandbox <-
    createSandbox
      runner
      ProcessSandboxSpec
        { processSandboxId = "sandboxed-tool-test"
        , processSandboxWorkspace = workspace
        }
  let
    toolRunner = SandboxedToolRunner runner
    env = SandboxedToolRunnerEnv sandbox
    toolCall =
      ToolCall
        { toolCallId = "call-1"
        , toolCallName = "shell"
        , toolCallArguments =
            object
              [ "name" .= ("shell" :: Text)
              , "argv"
                  .= (["sh", "-c", "pwd && echo sandboxed > result.txt && cat result.txt"] :: [Text])
              , "cwd" .= workspace
              , "timeout" .= object ["seconds" .= (5 :: Int)]
              ]
        }
  sandboxedCall <-
    case parseCommandToolCall toolCall of
      Right parsed -> pure parsed
      Left err -> fail ("unexpected sandboxed tool parse error: " <> show err)
  response <- runTool toolRunner env sandboxedCall
  assertEqual "sandboxed tool exits successfully" 0 (commandToolExitCode response)
  assertBool
    "sandboxed tool captures stdout"
    ( "sandboxed"
        `Text.isInfixOf` TextEncoding.decodeUtf8 (commandToolStdout response)
    )
  assertEqual
    "sandboxed tool writes inside workspace"
    "sandboxed\n"
    =<< ByteString.readFile (workspace </> "result.txt")
  let result = commandResponseToToolResult sandboxedCall response
  assertEqual
    "sandboxed tool result keeps call id"
    "call-1"
    (toolResultCallId result)
  destroySandbox runner sandbox

  case parseCommandToolCall
    toolCall{toolCallArguments = object ["argv" .= ([] :: [Text])]} of
    Left (SandboxedToolInvalidArguments _) -> pure ()
    Right parsed ->
      fail
        ( "expected sandboxed tool parse failure, got "
            <> show (sandboxedToolRequest parsed)
        )

harnessRequiredGoalTest :: IO ()
harnessRequiredGoalTest = mapM_ check ["success", "blocked"]
 where
  check status = do
    eventsRef <- newIORef []
    let
      call name args = ToolCall name name (object args)
      trailing = call "unexpected" []
      done =
        call
          "end_goal"
          [ "id" .= ("S1" :: Text)
          , "status" .= status
          , "summary" .= ("Run node check.js; preserve baseline abc123." :: Text)
          ]
      wrong =
        call
          "end_goal"
          [ "id" .= ("other" :: Text)
          , "status" .= status
          , "summary" .= ("Wrong goal" :: Text)
          ]
      textOnly =
        (responseWithToolCalls [])
          { responseMessage = assistantMessage "Finished the plan."
          }
    provider@(FakeProvider remainingRef) <-
      newFakeProvider
        [ textOnly
        , responseWithToolCall wrong
        , responseWithToolCalls [done, trailing]
        , textOnly
        ]
    state <-
      runHarness
        HarnessConfig
          { harnessProvider = provider
          , harnessRequestTemplate = requestTemplate
          , harnessSystemPrompt = "Use tools."
          , harnessUserPrompt = "Prepare a plan."
          , harnessInitialHistorySuffix = []
          , harnessTools =
              Experiment.experimentTools
                <> [ objectToolSpec
                       "unexpected"
                       "Must not run after completion."
                       []
                       []
                       (\_ -> fail "executed after end_goal")
                   ]
          , harnessMaxTurns = 6
          , harnessEventSink = \event -> modifyIORef' eventsRef (event :)
          , harnessWorkflowSpec = Just testWorkflow
          , harnessRequiredSubgoal = Just ("S1", "plan")
          }
    remaining <- readIORef remainingRef
    events <- readIORef eventsRef
    assertEqual
      "end_goal stops without another model request"
      1
      (length remaining)
    assertEqual
      "real summary and status survive completion"
      (Just (status, Just "Run node check.js; preserve baseline abc123."))
      (Map.lookup "S1" (harnessSubgoalResults state))
    assertEqual
      "calls after end_goal do not execute"
      Nothing
      (harnessActiveSubgoal state)
    assertEqual
      "invalid ends do not produce completion events"
      1
      (length [() | SubgoalEnded{} <- events])
    assertBool
      "text-only response adds a user reminder to history"
      ( any
          ( \case
              MessageInput (LLMMessage User parts) ->
                any
                  (\case TextPart text -> "calling end_goal" `Text.isInfixOf` text; _ -> False)
                  parts
              _ -> False
          )
          (harnessHistory state)
      )
    assertBool
      "reminder is visible in trace"
      (any (\case UserMessageObserved{} -> True; _ -> False) events)
    assertEqual
      "harness starts the goal exactly once"
      1
      (length [() | SubgoalStarted{} <- events])
    assertBool
      "experiment tools expose no obsolete lifecycle or effect tools"
      ( all
          ((`notElem` ["begin_subgoal", "end_subgoal", "record_effect"]) . toolName)
          Experiment.experimentTools
      )
    assertBool
      "end_goal is available"
      (any ((== "end_goal") . toolName) Experiment.experimentTools)

harnessWithoutGoalTest :: IO ()
harnessWithoutGoalTest = do
  eventsRef <- newIORef []
  let done = (responseWithToolCalls []){responseMessage = assistantMessage "Done."}
  provider@(FakeProvider remainingRef) <- newFakeProvider [done, done]
  state <-
    runHarness
      HarnessConfig
        { harnessProvider = provider
        , harnessRequestTemplate = requestTemplate
        , harnessSystemPrompt = "Follow the skill workflow in order."
        , harnessUserPrompt = "Run the whole skill."
        , harnessInitialHistorySuffix = []
        , harnessTools = []
        , harnessMaxTurns = 4
        , harnessEventSink = \event -> modifyIORef' eventsRef (event :)
        , harnessWorkflowSpec = Nothing
        , harnessRequiredSubgoal = Nothing
        }
  remaining <- readIORef remainingRef
  events <- readIORef eventsRef
  assertEqual
    "unassigned agent stops on a text-only response"
    1
    (length remaining)
  assertEqual
    "unassigned agent has no active goal"
    Nothing
    (harnessActiveSubgoal state)
  assertBool
    "unassigned agent has no automatic goal start or completion reminder"
    ( not
        ( any
            (\case SubgoalStarted{} -> True; UserMessageObserved{} -> True; _ -> False)
            events
        )
    )

harnessParallelToolCallsTest :: IO ()
harnessParallelToolCallsTest = do
  eventsRef <- newIORef []
  startedRef <- newIORef []
  finishedRef <- newIORef []
  provider <-
    newFakeProvider
      [ responseWithToolCalls
          [ ToolCall
              { toolCallId = "call-slow-a"
              , toolCallName = "slow"
              , toolCallArguments = object ["name" .= ("a" :: Text)]
              }
          , ToolCall
              { toolCallId = "call-slow-b"
              , toolCallName = "slow"
              , toolCallArguments = object ["name" .= ("b" :: Text)]
              }
          ]
      , responseWithToolCall $
          ToolCall
            { toolCallId = "call-end"
            , toolCallName = "end_goal"
            , toolCallArguments =
                object ["id" .= ("S1" :: Text), "status" .= ("success" :: Text)]
            }
      , LLMResponse
          { responseModel = "fake-model"
          , responseMessage = assistantMessage "done"
          , responseToolCalls = []
          , responseOutput = []
          , responseUsage = Nothing
          , responseFinishReason = Just "stop"
          }
      ]
  before <- getCurrentTime
  _ <-
    runHarness
      HarnessConfig
        { harnessProvider = provider
        , harnessRequestTemplate = requestTemplate
        , harnessSystemPrompt = "Use tools."
        , harnessUserPrompt = "Run parallel tools."
        , harnessInitialHistorySuffix = []
        , harnessTools =
            [ slowTool startedRef finishedRef
            , endGoalTool
            ]
        , harnessMaxTurns = 8
        , harnessEventSink = \event -> atomicModifyIORef' eventsRef (\events -> (event : events, ()))
        , harnessRequiredSubgoal = Just ("S1", "tiny step")
        , harnessWorkflowSpec = Just testWorkflow
        }
  after <- getCurrentTime
  let elapsed = realToFrac (diffUTCTime after before) :: Double
  started <- readIORef startedRef
  finished <- readIORef finishedRef
  events <- reverse <$> readIORef eventsRef
  assertBool
    "two slow tool calls ran in parallel"
    (elapsed < 0.35)
  assertEqual
    "both slow tool calls started"
    (Set.fromList ["a", "b"])
    (Set.fromList started)
  assertEqual
    "both slow tool calls finished"
    (Set.fromList ["a", "b"])
    (Set.fromList finished)
  assertBool
    "parallel tool calls keep active subgoal"
    (all isSlowToolCallForS1 (filter isSlowToolCall events))
  putStrLn "Harness parallel tool-call test passed."

requestTemplate :: LLMRequest
requestTemplate =
  LLMRequest
    { requestModel = "fake-model"
    , requestInput = []
    , requestTemperature = Nothing
    , requestMaxTokens = Nothing
    , requestStopSequences = []
    , requestResponseFormat = PlainText
    , requestTools = []
    , requestConfig = Nothing
    , requestPromptCacheKey = Nothing
    , requestPromptCacheRetention = Nothing
    }

testTools :: [ToolSpec]
testTools =
  [ recordEffectTool
  , shellTool
  , endGoalTool
  ]

testWorkflow :: WorkflowSpec
testWorkflow =
  WorkflowSpec
    { workflowName = "test workflow"
    , workflowNodes =
        [ WorkflowNode
            { workflowNodeId = "S1"
            , workflowNodeTitle = "tiny step"
            , workflowNodeBody = ""
            }
        ]
    , workflowEdges = []
    }

validCompilerGraph :: CompiledGoalGraph
validCompilerGraph =
  CompiledGoalGraph
    { compiledSkill = "test"
    , compiledGoals =
        [ compilerGoal "G001" []
        , compilerGoal "G002" ["G001"]
        ]
    }

unknownPredecessorCompilerGraph :: CompiledGoalGraph
unknownPredecessorCompilerGraph =
  CompiledGoalGraph
    { compiledSkill = "test"
    , compiledGoals = [compilerGoal "G001" ["missing"]]
    }

cyclicCompilerGraph :: CompiledGoalGraph
cyclicCompilerGraph =
  CompiledGoalGraph
    { compiledSkill = "test"
    , compiledGoals =
        [ compilerGoal "G001" ["G002"]
        , compilerGoal "G002" ["G001"]
        ]
    }

compilerGoal :: Text -> [Text] -> CompiledGoal
compilerGoal nodeId predecessors =
  CompiledGoal
    { compiledGoalId = nodeId
    , compiledGoalName = "goal"
    , compiledGoalDescription = "description"
    , compiledGoalPredecessors = predecessors
    , compiledGoalEnteringPrompt = "enter"
    }

goalId :: Text -> GoalNodeId
goalId = GoalNodeId

schedulerGoal :: Text -> Int -> GoalNode
schedulerGoal nodeId serialIndex =
  GoalNode
    { goalNodeId = goalId nodeId
    , goalNodeName = nodeId
    , goalNodePrompt = "run goal"
    , goalNodeSerialIndex = serialIndex
    }

fakeAgentRunResult :: GoalNode -> AgentRunResult
fakeAgentRunResult node =
  AgentRunResult
    { agentRunResultGoal = goalNodeId node
    , agentRunResultStatus = "success"
    , agentRunResultSummaryForDependents = "done"
    , agentRunResultReads = Set.empty
    , agentRunResultWrites = Set.empty
    , agentRunResultSnapshot =
        SnapshotId ("snapshot-" <> unGoalNodeId (goalNodeId node))
    }

recordEffectTool :: ToolSpec
recordEffectTool =
  objectToolSpec
    "record_effect"
    "Record an effect."
    [ ("kind", textSchema)
    , ("resource", textSchema)
    ]
    ["kind", "resource"]
    $ \toolCall ->
      case parseArgs toolCall of
        Left err -> pure (toolResult toolCall err, [])
        Right args ->
          pure
            ( toolResult toolCall "effect recorded"
            ,
              [ EffectRecorded
                  { eventEffect =
                      EffectRecord
                        { effectKind = effectKindArg args
                        , effectResource = effectResourceArg args
                        , effectDetail = Nothing
                        }
                  , eventActiveSubgoal = Nothing
                  }
              ]
            )

shellTool :: ToolSpec
shellTool =
  objectToolSpec
    "shell"
    "Fake shell."
    [ ("command", textSchema)
    ]
    ["command"]
    $ \toolCall ->
      case parseArgs toolCall of
        Left err -> pure (toolResult toolCall err, [])
        Right args ->
          pure (toolResult toolCall ("fake shell ran: " <> shellCommand args), [])

slowTool :: IORef [Text] -> IORef [Text] -> ToolSpec
slowTool startedRef finishedRef =
  objectToolSpec
    "slow"
    "Fake slow tool."
    [("name", textSchema)]
    ["name"]
    $ \toolCall ->
      case parseArgs toolCall of
        Left err -> pure (toolResult toolCall err, [])
        Right args -> do
          atomicModifyIORef'
            startedRef
            (\names -> (slowName args : names, ()))
          threadDelay 200000
          atomicModifyIORef'
            finishedRef
            (\names -> (slowName args : names, ()))
          pure (toolResult toolCall ("slow " <> slowName args), [])

endGoalTool :: ToolSpec
endGoalTool =
  objectToolSpec
    "end_goal"
    "End a subgoal."
    [ ("id", textSchema)
    , ("status", textSchema)
    ]
    ["id", "status"]
    $ \toolCall ->
      case parseArgs toolCall of
        Left err -> pure (toolResult toolCall err, [])
        Right args ->
          pure
            ( toolResult toolCall "ended"
            ,
              [ SubgoalEnded
                  { eventSubgoalId = endId args
                  , eventStatus = endStatus args
                  , eventSummary = Nothing
                  }
              ]
            )

fakeResponses :: [LLMResponse]
fakeResponses =
  [ responseWithToolCall $
      ToolCall
        { toolCallId = "call-effect"
        , toolCallName = "record_effect"
        , toolCallArguments =
            object
              [ "kind" .= ("write" :: Text)
              , "resource" .= ("fixture/output.txt" :: Text)
              ]
        }
  , responseWithToolCall $
      ToolCall
        { toolCallId = "call-shell"
        , toolCallName = "shell"
        , toolCallArguments = object ["command" .= ("pwd" :: Text)]
        }
  , responseWithToolCall $
      ToolCall
        { toolCallId = "call-end"
        , toolCallName = "end_goal"
        , toolCallArguments =
            object ["id" .= ("S1" :: Text), "status" .= ("success" :: Text)]
        }
  , LLMResponse
      { responseModel = "fake-model"
      , responseMessage = assistantMessage "done"
      , responseToolCalls = []
      , responseOutput = []
      , responseUsage = Nothing
      , responseFinishReason = Just "stop"
      }
  ]

responseWithToolCall :: ToolCall -> LLMResponse
responseWithToolCall toolCall =
  responseWithToolCalls [toolCall]

responseWithToolCalls :: [ToolCall] -> LLMResponse
responseWithToolCalls toolCalls =
  LLMResponse
    { responseModel = "fake-model"
    , responseMessage = assistantMessage ""
    , responseToolCalls = toolCalls
    , responseOutput = []
    , responseUsage = Nothing
    , responseFinishReason = Just "tool_calls"
    }

assistantMessage :: Text -> LLMMessage
assistantMessage text =
  LLMMessage
    { messageRole = Assistant
    , messageContent = [TextPart text]
    }

newtype FakeProvider = FakeProvider (IORef [LLMResponse])

newFakeProvider :: [LLMResponse] -> IO FakeProvider
newFakeProvider responses = FakeProvider <$> newIORef responses

instance LLM FakeProvider where
  runLLM (FakeProvider responsesRef) _request = do
    responses <- readIORef responsesRef
    case responses of
      [] -> pure (Left (LLMProviderError "fake provider exhausted"))
      response : rest -> do
        modifyIORef' responsesRef (const rest)
        pure (Right response)

newtype ShellArgs = ShellArgs
  { shellCommand :: Text
  }

instance FromJSON ShellArgs where
  parseJSON =
    withObject "ShellArgs" $ \value ->
      ShellArgs <$> value .: "command"

newtype SlowArgs = SlowArgs
  { slowName :: Text
  }

instance FromJSON SlowArgs where
  parseJSON =
    withObject "SlowArgs" $ \value ->
      SlowArgs <$> value .: "name"

data EffectArgs = EffectArgs
  { effectKindArg :: Text
  , effectResourceArg :: Text
  }

instance FromJSON EffectArgs where
  parseJSON =
    withObject "EffectArgs" $ \value ->
      EffectArgs <$> value .: "kind" <*> value .: "resource"

data EndArgs = EndArgs
  { endId :: Text
  , endStatus :: Text
  }

instance FromJSON EndArgs where
  parseJSON =
    withObject "EndArgs" $ \value ->
      EndArgs <$> value .: "id" <*> value .: "status"

parseArgs :: FromJSON value => ToolCall -> Either Text value
parseArgs toolCall =
  case eitherDecode (encode (toolCallArguments toolCall)) of
    Left err -> Left (Text.pack err)
    Right value -> Right value

toolResult :: ToolCall -> Text -> ToolResult
toolResult toolCall content =
  ToolResult
    { toolResultCallId = toolCallId toolCall
    , toolResultName = Just (toolCallName toolCall)
    , toolResultContent = [TextPart content]
    }

textSchema :: Value
textSchema = object ["type" .= ("string" :: Text)]

isSubgoalStarted :: HarnessEvent -> Bool
isSubgoalStarted SubgoalStarted{eventSubgoalId = "S1"} = True
isSubgoalStarted _ = False

isAssignedGoalName :: HarnessEvent -> Bool
isAssignedGoalName SubgoalStarted{eventSubgoalId = "S1", eventSubgoalName = "tiny step"} = True
isAssignedGoalName _ = False

isSubgoalEnded :: HarnessEvent -> Bool
isSubgoalEnded SubgoalEnded{eventSubgoalId = "S1", eventStatus = "success"} = True
isSubgoalEnded _ = False

isToolCall :: Text -> HarnessEvent -> Bool
isToolCall name ToolCallObserved{eventToolName = observedName} = name == observedName
isToolCall _ _ = False

isSlowToolCall :: HarnessEvent -> Bool
isSlowToolCall ToolCallObserved{eventToolName = "slow"} = True
isSlowToolCall _ = False

isSlowToolCallForS1 :: HarnessEvent -> Bool
isSlowToolCallForS1
  ToolCallObserved
    { eventToolName = "slow"
    , eventActiveSubgoal = Just "S1"
    } = True
isSlowToolCallForS1 _ = False

isEffectForS1 :: HarnessEvent -> Bool
isEffectForS1
  EffectRecorded
    { eventEffect =
      EffectRecord
        { effectKind = "write"
        , effectResource = "fixture/output.txt"
        }
    , eventActiveSubgoal = Just "S1"
    } = True
isEffectForS1 _ = False

isWorkflowStatusForS1 :: HarnessEvent -> Bool
isWorkflowStatusForS1
  WorkflowStatusObserved
    { eventCompletedNodes = completed
    , eventLastNode = Just "S1"
    } = Set.member "S1" completed
isWorkflowStatusForS1 _ = False

isReplanEvent :: ChaseEvent -> Bool
isReplanEvent ChaseConflictReplanned{} = True
isReplanEvent _ = False

isShellResult :: HarnessEvent -> Bool
isShellResult ToolResultObserved{eventToolName = "shell", eventResult = result} =
  "fake shell ran: pwd" `Text.isInfixOf` result
isShellResult _ = False

isHarnessFinished :: HarnessEvent -> Bool
isHarnessFinished HarnessFinished{} = True
isHarnessFinished _ = False

isPreloadToolCall :: LLMInputItem -> Bool
isPreloadToolCall (ToolCallInput _) = True
isPreloadToolCall _ = False

isPreloadToolResult :: LLMInputItem -> Bool
isPreloadToolResult (ToolResultInput _) = True
isPreloadToolResult _ = False

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  assertBool
    (label <> ": expected " <> show expected <> ", got " <> show actual)
    (expected == actual)

assertBool :: String -> Bool -> IO ()
assertBool _ True = pure ()
assertBool label False = do
  putStrLn ("Assertion failed: " <> label)
  exitFailure

hasSubsequence :: Eq value => [value] -> [value] -> Bool
hasSubsequence needle haystack =
  any (needle `List.isPrefixOf`) (List.tails haystack)

withEnvVar :: String -> Maybe String -> IO a -> IO a
withEnvVar name value action = do
  oldValue <- lookupEnv name
  setMaybe value
  result <- action
  setMaybe oldValue
  pure result
 where
  setMaybe Nothing = unsetEnv name
  setMaybe (Just newValue) = setEnv name newValue
