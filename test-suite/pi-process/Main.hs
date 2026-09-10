module Main (main) where

import Agent.SeaOfGoals.PiProcess
  ( PiProcessConfig (..)
  , PiProcessResult (..)
  , piExpectedVersion
  , runPiProcess
  )
import Agent.SeaOfGoals.Trace (HarnessEvent (..))
import Agent.SeaOfGoals.Workspace.Sandbox (ExecTimeout (ExecNoTimeout))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import System.Directory
  ( createDirectoryIfMissing
  , getTemporaryDirectory
  , removePathForcibly
  )
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

main :: IO ()
main = do
  temporaryDirectory <- getTemporaryDirectory
  let root = temporaryDirectory </> "sog-pi-process-test"
      binary = root </> "fake-pi"
  removePathForcibly root
  createDirectoryIfMissing True root
  writeFile
    binary
    ( "#!/bin/sh\n"
        <> "if [ \"$1\" = \"--version\" ]; then printf '"
        <> Text.unpack piExpectedVersion
        <> "\\n'; exit 0; fi\n"
        <> "printf '{\"type\":\"agent_start\"}\\n'\n"
        <> "printf '%s\\n' '{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}'\n"
        <> "printf '%s\\n' '{\"type\":\"tool_execution_start\",\"toolCallId\":\"call-1\",\"toolName\":\"end_goal\",\"args\":{\"status\":\"success\"}}'\n"
        <> "printf '%s\\n' '{\"type\":\"tool_execution_end\",\"toolCallId\":\"call-1\",\"toolName\":\"end_goal\",\"result\":{\"status\":\"success\"}}'\n"
        <> "printf '%s\\n' '{\"type\":\"message_update\",\"usage\":{\"input\":10,\"output\":4,\"reasoning\":2,\"totalTokens\":14,\"cacheRead\":3}}'\n"
    )
  setFileMode binary 0o755
  events <- newIORef []
  result <-
    runPiProcess
      PiProcessConfig
        { piProcessBinary = binary
        , piProcessExtension = Nothing
        , piProcessNodeBinary = "node"
        , piProcessSdkRunner = Nothing
        , piProcessModel = Nothing
        , piProcessTimeout = ExecNoTimeout
        }
      (\event -> modifyIORef' events (event :))
      (Just "G-test")
      root
      "run the smoke test"
  recorded <- readIORef events
  assertEqual "exit code" 0 (piProcessExitCode result)
  assertEqual "timeout" False (piProcessTimedOut result)
  assertTrue "process started" (any isProcessStarted recorded)
  assertTrue "raw Pi event" (any isPiEvent recorded)
  assertTrue "assistant event" (any isAssistant recorded)
  assertTrue "tool call event" (any isToolCall recorded)
  assertTrue "tool result event" (any isToolResult recorded)
  assertTrue "usage event" (any isUsage recorded)
  assertTrue "process finished" (any isProcessFinished recorded)
  putStrLn "Pi process smoke test passed."

isProcessStarted :: HarnessEvent -> Bool
isProcessStarted ProcessStarted{} = True
isProcessStarted _ = False

isPiEvent :: HarnessEvent -> Bool
isPiEvent CodexEventObserved{} = True
isPiEvent _ = False

isAssistant :: HarnessEvent -> Bool
isAssistant AssistantMessageObserved{} = True
isAssistant _ = False

isToolCall :: HarnessEvent -> Bool
isToolCall ToolCallObserved{} = True
isToolCall _ = False

isToolResult :: HarnessEvent -> Bool
isToolResult ToolResultObserved{} = True
isToolResult _ = False

isUsage :: HarnessEvent -> Bool
isUsage ModelUsageObserved{} = True
isUsage _ = False

isProcessFinished :: HarnessEvent -> Bool
isProcessFinished ProcessFinished{} = True
isProcessFinished _ = False

assertTrue :: String -> Bool -> IO ()
assertTrue label condition =
  if condition then pure () else fail label

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
  if expected == actual
    then pure ()
    else fail (label <> ": expected " <> show expected <> ", got " <> show actual)
