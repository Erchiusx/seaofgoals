module Agent.SeaOfGoals.Workspace.ProcessExec
  ( ProcessExecSpec (..)
  , runProcessExec
  , runProcessExecWithStdoutLineSink
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
  ( IOException
  , SomeException
  , try
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteStringChar8
import Data.IORef
  ( modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import System.Exit
  ( ExitCode (..)
  )
import System.IO
  ( Handle
  , hClose
  , hIsEOF
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
  , processExecStdin :: Maybe ByteString
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
    (Just stdinHandle, Just stdoutHandle, Just stderrHandle, processHandle) <-
      createProcess
        process{std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
    writeProcessInput stdinHandle (processExecStdin spec)
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
    (Just stdinHandle, Just stdoutHandle, Just stderrHandle, processHandle) <-
      createProcess
        (mkProcess command args)
          { std_in = CreatePipe
          , std_out = CreatePipe
          , std_err = CreatePipe
          }
    writeProcessInput stdinHandle (processExecStdin spec)
    stdoutBytes <- ByteString.hGetContents stdoutHandle
    stderrBytes <- ByteString.hGetContents stderrHandle
    exitCode <- waitForProcess processHandle
    pure (exitCode, stdoutBytes, stderrBytes)

  mkProcess command args =
    (proc command args)
      { cwd = processExecCwd spec
      , env = processExecEnv spec
      }

runProcessExecWithStdoutLineSink
  :: ProcessExecSpec -> (ByteString -> IO ()) -> IO SandboxExecOutcome
runProcessExecWithStdoutLineSink spec stdoutLineSink =
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
    (exitCode, stdoutBytes, stderrBytes) <-
      runStreamingProcess command args stdoutLineSink
    pure (toOutcome False exitCode stdoutBytes stderrBytes)

  runWithTimeout seconds command args = do
    done <- newEmptyMVar
    timedOutRef <- newIORef False
    let process = mkProcess command args
    (Just stdinHandle, Just stdoutHandle, Just stderrHandle, processHandle) <-
      createProcess
        process{std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
    writeProcessInput stdinHandle (processExecStdin spec)
    stdoutRef <- newIORef []
    stderrDone <- newEmptyMVar
    _ <-
      forkIO $ do
        stderrBytes <- ByteString.hGetContents stderrHandle
        putMVar stderrDone stderrBytes
    _ <-
      forkIO $ do
        streamStdout stdoutHandle stdoutRef stdoutLineSink
        result <-
          try (waitForProcess processHandle) :: IO (Either SomeException ExitCode)
        stderrBytes <- takeMVar stderrDone
        stdoutChunks <- readIORef stdoutRef
        putMVar done (result, ByteString.concat (reverse stdoutChunks), stderrBytes)
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

  runStreamingProcess command args sink = do
    (Just stdinHandle, Just stdoutHandle, Just stderrHandle, processHandle) <-
      createProcess
        (mkProcess command args)
          { std_in = CreatePipe
          , std_out = CreatePipe
          , std_err = CreatePipe
          }
    writeProcessInput stdinHandle (processExecStdin spec)
    stdoutRef <- newIORef []
    stderrDone <- newEmptyMVar
    _ <-
      forkIO $ do
        stderrBytes <- ByteString.hGetContents stderrHandle
        putMVar stderrDone stderrBytes
    streamStdout stdoutHandle stdoutRef sink
    exitCode <- waitForProcess processHandle
    stderrBytes <- takeMVar stderrDone
    stdoutChunks <- readIORef stdoutRef
    pure (exitCode, ByteString.concat (reverse stdoutChunks), stderrBytes)

  streamStdout stdoutHandle stdoutRef sink = do
    eof <- hIsEOF stdoutHandle
    if eof
      then pure ()
      else do
        lineResult <-
          try (ByteStringChar8.hGetLine stdoutHandle)
            :: IO (Either IOException ByteString)
        case lineResult of
          Left _ -> pure ()
          Right line -> do
            modifyIORef' stdoutRef ((line <> "\n") :)
            _ <- sink line
            streamStdout stdoutHandle stdoutRef sink

  mkProcess command args =
    (proc command args)
      { cwd = processExecCwd spec
      , env = processExecEnv spec
      }

writeProcessInput :: Handle -> Maybe ByteString -> IO ()
writeProcessInput handle maybeInput = do
  maybe (pure ()) (ByteString.hPut handle) maybeInput
  hClose handle

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
