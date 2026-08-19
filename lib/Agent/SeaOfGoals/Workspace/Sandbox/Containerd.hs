module Agent.SeaOfGoals.Workspace.Sandbox.Containerd
  ( ContainerdSandboxHandle
  , ContainerdSandboxRunner (..)
  , ContainerdSandboxSpec (..)
  )
where

import Agent.SeaOfGoals.Workspace.Containerd.Command
  ( Config (..)
  , Handle (..)
  , Mount (..)
  , Root (..)
  , TaskSpec (..)
  , containerdContainerDeleteArgs
  , containerdContainerId
  , containerdCreateArgs
  , containerdExecArgs
  , containerdTaskDeleteArgs
  , containerdTaskStartArgs
  )
import Agent.SeaOfGoals.Workspace.Sandbox
  ( ExecSpec (..)
  , ExecTimeout (..)
  , SandboxExecOutcome (..)
  , SandboxRunner (..)
  )
import Control.Concurrent
  ( forkIO
  , threadDelay
  )
import Control.Concurrent.MVar
  ( newEmptyMVar
  , putMVar
  , takeMVar
  )
import Control.Exception
  ( SomeException
  , try
  )
import Data.ByteString qualified as ByteString
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (..)
  , StdStream (CreatePipe)
  , createProcess
  , proc
  , terminateProcess
  , waitForProcess
  )

data ContainerdSandboxRunner = ContainerdSandboxRunner
  { containerdSandboxConfig :: Config
  }
  deriving stock (Eq, Show)

data ContainerdSandboxSpec = ContainerdSandboxSpec
  { containerdSandboxId :: Text
  , containerdSandboxRoot :: Root
  , containerdSandboxMounts :: [Mount]
  , containerdSandboxInitArgv :: [Text]
  }
  deriving stock (Eq, Show)

data ContainerdSandboxHandle = ContainerdSandboxHandle
  { containerdSandboxHandleContainer :: Handle
  , containerdSandboxHandleNextExec :: IORef Int
  }

instance SandboxRunner ContainerdSandboxRunner where
  type SandboxSpec ContainerdSandboxRunner = ContainerdSandboxSpec
  type SandboxHandle ContainerdSandboxRunner = ContainerdSandboxHandle
  type SandboxExecSpec ContainerdSandboxRunner = ExecSpec

  createSandbox runner spec = do
    let
      config = containerdSandboxConfig runner
      containerId = containerdContainerId (containerdSandboxId spec)
      handle =
        Handle
          { handleId = containerId
          , handleConfig = config
          }
      taskSpec =
        TaskSpec
          { taskId = containerdSandboxId spec
          , taskRoot = containerdSandboxRoot spec
          , taskMounts = containerdSandboxMounts spec
          , taskLabels = mempty
          , taskInitArgv =
              case containerdSandboxInitArgv spec of
                [] -> ["sleep", "infinity"]
                argv -> argv
          }
    runContainerd_ config (containerdCreateArgs config taskSpec)
    runContainerd_ config (containerdTaskStartArgs config handle)
    nextExec <- newIORef 0
    pure
      ContainerdSandboxHandle
        { containerdSandboxHandleContainer = handle
        , containerdSandboxHandleNextExec = nextExec
        }

  execInSandbox runner handle spec =
    do
      execId <- nextExecId handle
      runContainerdExec
        (containerdSandboxConfig runner)
        ( containerdExecArgs
            (containerdSandboxConfig runner)
            (containerdSandboxHandleContainer handle)
            execId
            spec
        )
        (execTimeout spec)
   where
    nextExecId handleValue =
      atomicModifyIORef'
        (containerdSandboxHandleNextExec handleValue)
        ( \counter ->
            let nextCounter = counter + 1
             in ( nextCounter
                , handleId (containerdSandboxHandleContainer handleValue)
                    <> "-exec-"
                    <> Text.pack (show nextCounter)
                )
        )

  destroySandbox runner handle = do
    let
      config = containerdSandboxConfig runner
      container = containerdSandboxHandleContainer handle
    _ <- runContainerd config (containerdTaskDeleteArgs config container)
    _ <- runContainerd config (containerdContainerDeleteArgs config container)
    pure ()

  sandboxId _ =
    handleId . containerdSandboxHandleContainer

runContainerd_ :: Config -> [String] -> IO ()
runContainerd_ config args = do
  outcome <- runContainerdExec config args ExecNoTimeout
  if sandboxExecExitCode outcome == 0
    then pure ()
    else
      ioError
        ( userError
            ( "containerd command failed: "
                <> Text.unpack (decodeUtf8 (sandboxExecStderr outcome))
            )
        )

runContainerd :: Config -> [String] -> IO SandboxExecOutcome
runContainerd config args =
  runContainerdExec config args ExecNoTimeout

runContainerdExec
  :: Config -> [String] -> ExecTimeout -> IO SandboxExecOutcome
runContainerdExec _ [] _ =
  pure
    SandboxExecOutcome
      { sandboxExecExitCode = 127
      , sandboxExecStdout = ""
      , sandboxExecStderr = "empty containerd argv"
      , sandboxExecTimedOut = False
      }
runContainerdExec _ (command : args) timeoutSpec =
  case timeoutSpec of
    ExecNoTimeout -> runNoTimeout command args
    ExecTimeoutSeconds seconds -> runWithTimeout seconds command args

runNoTimeout :: String -> [String] -> IO SandboxExecOutcome
runNoTimeout command args = do
  (exitCode, stdoutBytes, stderrBytes) <- runProcess command args
  pure (toOutcome False exitCode stdoutBytes stderrBytes)

runWithTimeout
  :: Integral seconds => seconds -> String -> [String] -> IO SandboxExecOutcome
runWithTimeout seconds command args = do
  done <- newEmptyMVar
  timedOutRef <- newIORef False
  let process = proc command args
  (_, Just stdoutHandle, Just stderrHandle, processHandle) <-
    createProcess process{std_out = CreatePipe, std_err = CreatePipe}
  _ <-
    forkIO $ do
      stdoutBytes <- ByteString.hGetContents stdoutHandle
      stderrBytes <- ByteString.hGetContents stderrHandle
      result <-
        try (waitForProcess processHandle) :: IO (Either SomeException ExitCode)
      putMVar done (result, stdoutBytes, stderrBytes)
  _ <-
    forkIO $ do
      threadDelay (fromIntegral seconds * 1000000)
      writeIORef timedOutRef True
      terminateProcess processHandle
  (result, stdoutBytes, stderrBytes) <- takeMVar done
  case result of
    Right exitCode -> do
      timedOut <- readIORef timedOutRef
      pure
        ( toOutcome
            timedOut
            exitCode
            stdoutBytes
            stderrBytes
        )
    Left err ->
      pure
        SandboxExecOutcome
          { sandboxExecExitCode = 124
          , sandboxExecStdout = stdoutBytes
          , sandboxExecStderr = TextEncoding.encodeUtf8 (Text.pack (show err))
          , sandboxExecTimedOut = True
          }

runProcess
  :: String
  -> [String]
  -> IO (ExitCode, ByteString.ByteString, ByteString.ByteString)
runProcess command args = do
  (_, Just stdoutHandle, Just stderrHandle, processHandle) <-
    createProcess (proc command args){std_out = CreatePipe, std_err = CreatePipe}
  stdoutBytes <- ByteString.hGetContents stdoutHandle
  stderrBytes <- ByteString.hGetContents stderrHandle
  exitCode <- waitForProcess processHandle
  pure (exitCode, stdoutBytes, stderrBytes)

toOutcome
  :: Bool
  -> ExitCode
  -> ByteString.ByteString
  -> ByteString.ByteString
  -> SandboxExecOutcome
toOutcome timedOut exitCode stdoutBytes stderrBytes =
  SandboxExecOutcome
    { sandboxExecExitCode = exitCodeToInt exitCode
    , sandboxExecStdout = stdoutBytes
    , sandboxExecStderr = stderrBytes
    , sandboxExecTimedOut = timedOut
    }

exitCodeToInt :: ExitCode -> Int
exitCodeToInt ExitSuccess = 0
exitCodeToInt (ExitFailure code) = code

decodeUtf8 :: ByteString.ByteString -> Text
decodeUtf8 = TextEncoding.decodeUtf8
