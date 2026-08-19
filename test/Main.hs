module Main (main) where

import Agent.LLM.Transport
  ( TransportResponse (..)
  )
import Agent.SeaOfGoals.Compile.Compiler
  ( CompiledGoal (..)
  , CompiledGoalGraph (..)
  , validateCompiledGoalGraph
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
  , LLMMessage (..)
  , LLMRequest (..)
  , LLMResponse (..)
  , LLMRole (..)
  , ResponseFormat (PlainText)
  , ToolCall (..)
  , ToolResult (..)
  )
import Agent.SeaOfGoals.Scheduling.Agentic
  ( GoalGraph (..)
  , GoalNode (..)
  , GoalNodeId (..)
  )
import Agent.SeaOfGoals.Scheduling.MergeScheduler
  ( MergeDependencyUpdate (..)
  , applyMergeConflict
  , goalGraphDescendants
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
import Agent.SeaOfGoals.Workspace.Sandbox
  ( BindMode (..)
  , ExecSpec (..)
  , ExecTimeout (..)
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
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getTemporaryDirectory
  , removePathForcibly
  )
import System.Exit (exitFailure)
import System.FilePath ((</>))

main :: IO ()
main = do
  unicodeTransportResponseBodyTest
  compilerGraphValidationTest
  bwrapCommandRenderingTest
  containerdCommandRenderingTest
  fuseStoreWorkspaceTest
  fuseStoreAccessConflictTest
  fuseWorkspaceMergeTest
  rootOnlyEffectsTest
  accessNormalizationTest
  mergeSchedulerConflictTest
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
        , harnessTools = testTools
        , harnessMaxTurns = 8
        , harnessEventSink = \event -> modifyIORef' eventsRef (event :)
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
  assertBool "subgoal name is canonicalized" (any isCanonicalSubgoalName events)
  assertBool "effect was assigned to active subgoal" (any isEffectForS1 events)
  assertBool "workflow status was observed" (any isWorkflowStatusForS1 events)
  assertBool "shell tool was called" (any (isToolCall "shell") events)
  assertBool "shell output was observed" (any isShellResult events)
  assertBool "subgoal ended" (any isSubgoalEnded events)
  assertBool "harness finished" (any isHarnessFinished events)
  putStrLn "Harness tool-call loop test passed."

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

compilerGraphValidationTest :: IO ()
compilerGraphValidationTest = do
  assertEqual
    "valid compiler DAG"
    []
    (validateCompiledGoalGraph validCompilerGraph)
  assertBool
    "compiler DAG rejects unknown predecessor"
    (not (null (validateCompiledGoalGraph unknownPredecessorCompilerGraph)))
  assertBool
    "compiler DAG rejects cycle"
    (not (null (validateCompiledGoalGraph cyclicCompilerGraph)))

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
    "bwrap command redirects cabal store into workspace"
    ( hasSubsequence
        ["--setenv", "CABAL_STORE_DIR", "/workspace/.sog/cabal-store"]
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
    }

testTools :: [ToolSpec]
testTools =
  [ beginSubgoalTool
  , recordEffectTool
  , shellTool
  , endSubgoalTool
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

beginSubgoalTool :: ToolSpec
beginSubgoalTool =
  objectToolSpec
    "begin_subgoal"
    "Start a subgoal."
    [ ("id", textSchema)
    , ("name", textSchema)
    ]
    ["id", "name"]
    $ \toolCall ->
      case parseArgs toolCall of
        Left err -> pure (toolResult toolCall err, [])
        Right args ->
          pure
            ( toolResult toolCall "started"
            ,
              [ SubgoalStarted
                  { eventSubgoalId = beginId args
                  , eventSubgoalName = beginName args
                  }
              ]
            )

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

endSubgoalTool :: ToolSpec
endSubgoalTool =
  objectToolSpec
    "end_subgoal"
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
        { toolCallId = "call-begin"
        , toolCallName = "begin_subgoal"
        , toolCallArguments =
            object ["id" .= ("S1" :: Text), "name" .= ("mojibake step" :: Text)]
        }
  , responseWithToolCall $
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
        , toolCallName = "end_subgoal"
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
  LLMResponse
    { responseModel = "fake-model"
    , responseMessage = assistantMessage ""
    , responseToolCalls = [toolCall]
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

data BeginArgs = BeginArgs
  { beginId :: Text
  , beginName :: Text
  }

instance FromJSON BeginArgs where
  parseJSON =
    withObject "BeginArgs" $ \value ->
      BeginArgs <$> value .: "id" <*> value .: "name"

newtype ShellArgs = ShellArgs
  { shellCommand :: Text
  }

instance FromJSON ShellArgs where
  parseJSON =
    withObject "ShellArgs" $ \value ->
      ShellArgs <$> value .: "command"

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

isCanonicalSubgoalName :: HarnessEvent -> Bool
isCanonicalSubgoalName SubgoalStarted{eventSubgoalId = "S1", eventSubgoalName = "tiny step"} = True
isCanonicalSubgoalName _ = False

isSubgoalEnded :: HarnessEvent -> Bool
isSubgoalEnded SubgoalEnded{eventSubgoalId = "S1", eventStatus = "success"} = True
isSubgoalEnded _ = False

isToolCall :: Text -> HarnessEvent -> Bool
isToolCall name ToolCallObserved{eventToolName = observedName} = name == observedName
isToolCall _ _ = False

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

isShellResult :: HarnessEvent -> Bool
isShellResult ToolResultObserved{eventToolName = "shell", eventResult = result} =
  "fake shell ran: pwd" `Text.isInfixOf` result
isShellResult _ = False

isHarnessFinished :: HarnessEvent -> Bool
isHarnessFinished HarnessFinished{} = True
isHarnessFinished _ = False

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
