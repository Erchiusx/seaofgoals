module Agent.SeaOfGoals.Workspace.ProcessExec
  ( ProcessExecSpec (..)
  , runProcessExec
  )
where

import Agent.SeaOfGoals.Workspace.Sandbox
  ( ExecTimeout (..)
  , SandboxExecOutcome (..)
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
  ( newIORef
  , readIORef
  , writeIORef
  )
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import System.Exit
  ( ExitCode (..)
  )
import System.Process
  ( CreateProcess (..)
  , StdStream (CreatePipe)
  , createProcess
  , proc
  , terminateProcess
  , waitForProcess
  )

data ProcessExecSpec = ProcessExecSpec
  { processExecArgv :: [String]
  , processExecCwd :: Maybe FilePath
  , processExecEnv :: Maybe [(String, String)]
  , processExecTimeout :: ExecTimeout
  }
  deriving stock (Eq, Show)

runProcessExec :: ProcessExecSpec -> IO SandboxExecOutcome
runProcessExec spec =
  case processExecArgv spec of
    [] ->
      pure
        SandboxExecOutcome
          { sandboxExecExitCode = 127
          , sandboxExecStdout = ""
          , sandboxExecStderr = "empty argv"
          , sandboxExecTimedOut = False
          }
    command : args ->
      case processExecTimeout spec of
        ExecNoTimeout -> runNoTimeout command args
        ExecTimeoutSeconds seconds -> runWithTimeout seconds command args
 where
  runNoTimeout command args = do
    (exitCode, stdoutBytes, stderrBytes) <- runProcess command args
    pure (toOutcome False exitCode stdoutBytes stderrBytes)

  runWithTimeout seconds command args = do
    done <- newEmptyMVar
    timedOutRef <- newIORef False
    let process = mkProcess command args
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
    timedOut <- readIORef timedOutRef
    case result of
      Right exitCode ->
        pure (toOutcome timedOut exitCode stdoutBytes stderrBytes)
      Left err ->
        pure
          SandboxExecOutcome
            { sandboxExecExitCode = 124
            , sandboxExecStdout = stdoutBytes
            , sandboxExecStderr = TextEncoding.encodeUtf8 (Text.pack (show err))
            , sandboxExecTimedOut = True
            }

  runProcess command args = do
    (_, Just stdoutHandle, Just stderrHandle, processHandle) <-
      createProcess
        (mkProcess command args){std_out = CreatePipe, std_err = CreatePipe}
    stdoutBytes <- ByteString.hGetContents stdoutHandle
    stderrBytes <- ByteString.hGetContents stderrHandle
    exitCode <- waitForProcess processHandle
    pure (exitCode, stdoutBytes, stderrBytes)

  mkProcess command args =
    (proc command args)
      { cwd = processExecCwd spec
      , env = processExecEnv spec
      }

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
