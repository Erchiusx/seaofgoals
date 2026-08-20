module Agent.SeaOfGoals.Workspace.Bwrap.ToolBinding
  ( BwrapToolBinding (..)
  , bwrapShellTool
  )
where

import Agent.SeaOfGoals.LLM
  ( LLMContentPart (TextPart)
  , ToolCall (..)
  , ToolResult (..)
  )
import Agent.SeaOfGoals.Tools
  ( ToolSpec
  , objectToolSpec
  )
import Agent.SeaOfGoals.Workspace.Sandbox
  ( ExecSpec (..)
  , ExecTimeout (..)
  , SandboxExecOutcome (..)
  , SandboxRunner (..)
  )
import Agent.SeaOfGoals.Workspace.Sandbox.Bwrap
  ( BwrapSandboxHandle
  , BwrapSandboxRunner
  )
import Data.Aeson
  ( FromJSON (..)
  , Result (..)
  , Value
  , fromJSON
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding

data BwrapToolBinding = BwrapToolBinding
  { bwrapToolRunner :: BwrapSandboxRunner
  , bwrapToolHandle :: BwrapSandboxHandle
  }

newtype ShellArgs = ShellArgs
  { shellCommand :: Text
  }

instance FromJSON ShellArgs where
  parseJSON =
    withObject "ShellArgs" $ \value ->
      ShellArgs <$> value .: "command"

bwrapShellTool :: BwrapToolBinding -> ToolSpec
bwrapShellTool binding =
  objectToolSpec
    "shell"
    "Run a shell command inside the configured bwrap workspace view and return stdout, stderr, and exit code."
    [ ("command", textSchema "Shell command to run inside /workspace")
    ]
    ["command"]
    $ \toolCall ->
      case parseShellArgs toolCall of
        Left err -> pure (textResult toolCall err, [])
        Right args -> do
          outcome <-
            execInSandbox
              (bwrapToolRunner binding)
              (bwrapToolHandle binding)
              ExecSpec
                { execArgv = ["/bin/sh", "-lc", shellCommand args]
                , execCwd = "."
                , execEnv = []
                , execTimeout = ExecNoTimeout
                }
          pure (textResult toolCall (renderOutcome outcome), [])

parseShellArgs :: ToolCall -> Either Text ShellArgs
parseShellArgs toolCall =
  case fromJSON (toolCallArguments toolCall) of
    Success args -> Right args
    Error err -> Left (Text.pack err)

renderOutcome :: SandboxExecOutcome -> Text
renderOutcome outcome =
  Text.unlines
    [ "exit_code: " <> Text.pack (show (sandboxExecExitCode outcome))
    , "timed_out: " <> boolText (sandboxExecTimedOut outcome)
    , "stdout:"
    , decodeUtf8 (sandboxExecStdout outcome)
    , "stderr:"
    , decodeUtf8 (sandboxExecStderr outcome)
    ]

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

decodeUtf8 :: ByteString.ByteString -> Text
decodeUtf8 = TextEncoding.decodeUtf8

boolText :: Bool -> Text
boolText True = "true"
boolText False = "false"
