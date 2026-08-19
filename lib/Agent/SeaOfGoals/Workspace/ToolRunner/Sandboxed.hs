module Agent.SeaOfGoals.Workspace.ToolRunner.Sandboxed
  ( SandboxedToolCall (..)
  , SandboxedToolError (..)
  , SandboxedToolRunner (..)
  , SandboxedToolRunnerEnv (..)
  , commandResponseToToolResult
  , parseCommandToolCall
  )
where

import Agent.SeaOfGoals.LLM
  ( LLMContentPart (TextPart)
  , ToolCall (..)
  , ToolResult (..)
  )
import Agent.SeaOfGoals.Workspace.Sandbox
  ( ExecSpec (..)
  , SandboxExecOutcome (..)
  , SandboxRunner (..)
  )
import Agent.SeaOfGoals.Workspace.ToolRunner
  ( CommandToolRequest (..)
  , CommandToolResponse (..)
  , ToolRunner (..)
  )
import Data.Aeson
  ( Result (..)
  , fromJSON
  )
import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding

data SandboxedToolCall = SandboxedToolCall
  { sandboxedToolOriginalCall :: ToolCall
  , sandboxedToolRequest :: CommandToolRequest
  }
  deriving stock (Eq, Show)

data SandboxedToolRunner runner = SandboxedToolRunner
  { sandboxedToolSandboxRunner :: runner
  }

data SandboxedToolRunnerEnv runner = SandboxedToolRunnerEnv
  { sandboxedToolSandboxHandle :: SandboxHandle runner
  }

data SandboxedToolError
  = SandboxedToolInvalidArguments Text
  deriving stock (Eq, Show)

instance
  ( SandboxRunner runner
  , SandboxExecSpec runner ~ ExecSpec
  )
  => ToolRunner (SandboxedToolRunner runner)
  where
  type ToolRunnerEnv (SandboxedToolRunner runner) = SandboxedToolRunnerEnv runner
  type ToolRequest (SandboxedToolRunner runner) = SandboxedToolCall
  type ToolResponse (SandboxedToolRunner runner) = CommandToolResponse

  runTool runner env toolCall = do
    outcome <-
      execInSandbox
        (sandboxedToolSandboxRunner runner)
        (sandboxedToolSandboxHandle env)
        (toSandboxExecSpec (sandboxedToolRequest toolCall))
    pure (fromSandboxOutcome outcome)

parseCommandToolCall :: ToolCall -> Either SandboxedToolError SandboxedToolCall
parseCommandToolCall toolCall =
  case fromJSON (toolCallArguments toolCall) of
    Success request ->
      Right
        SandboxedToolCall
          { sandboxedToolOriginalCall = toolCall
          , sandboxedToolRequest = request
          }
    Error err ->
      Left (SandboxedToolInvalidArguments (Text.pack err))

commandResponseToToolResult
  :: SandboxedToolCall -> CommandToolResponse -> ToolResult
commandResponseToToolResult toolCall response =
  ToolResult
    { toolResultCallId = toolCallId (sandboxedToolOriginalCall toolCall)
    , toolResultName = Just (toolCallName (sandboxedToolOriginalCall toolCall))
    , toolResultContent =
        [ TextPart
            ( Text.unlines
                [ "exit_code: " <> Text.pack (show (commandToolExitCode response))
                , "timed_out: " <> boolText (commandToolTimedOut response)
                , "stdout:"
                , decodeUtf8 (commandToolStdout response)
                , "stderr:"
                , decodeUtf8 (commandToolStderr response)
                ]
            )
        ]
    }

toSandboxExecSpec :: CommandToolRequest -> ExecSpec
toSandboxExecSpec request =
  ExecSpec
    { execArgv = commandToolArgv request
    , execCwd = commandToolCwd request
    , execEnv = Map.toList (commandToolEnv request)
    , execTimeout = commandToolTimeout request
    }

fromSandboxOutcome :: SandboxExecOutcome -> CommandToolResponse
fromSandboxOutcome outcome =
  CommandToolResponse
    { commandToolExitCode = sandboxExecExitCode outcome
    , commandToolStdout = sandboxExecStdout outcome
    , commandToolStderr = sandboxExecStderr outcome
    , commandToolTimedOut = sandboxExecTimedOut outcome
    }

decodeUtf8 :: ByteString.ByteString -> Text
decodeUtf8 = TextEncoding.decodeUtf8

boolText :: Bool -> Text
boolText True = "true"
boolText False = "false"
