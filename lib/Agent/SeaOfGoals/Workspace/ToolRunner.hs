module Agent.SeaOfGoals.Workspace.ToolRunner
  ( CommandToolRequest (..)
  , CommandToolResponse (..)
  , ToolRunner (..)
  )
where

import Agent.SeaOfGoals.Workspace.Sandbox (ExecTimeout (..))
import Data.Aeson
  ( FromJSON (..)
  , Value
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  )
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

data CommandToolRequest = CommandToolRequest
  { commandToolName :: Text
  , commandToolArgv :: [Text]
  , commandToolCwd :: FilePath
  , commandToolEnv :: Map Text Text
  , commandToolTimeout :: ExecTimeout
  }
  deriving stock (Eq, Show)

instance FromJSON CommandToolRequest where
  parseJSON =
    withObject "CommandToolRequest" $ \value -> do
      timeoutValue <- value .:? "timeout"
      parsedTimeout <-
        case timeoutValue of
          Nothing -> pure ExecNoTimeout
          Just rawTimeout -> parseExecTimeout rawTimeout
      CommandToolRequest
        <$> value .: "name"
        <*> value .: "argv"
        <*> value .:? "cwd" .!= "."
        <*> value .:? "env" .!= Map.empty
        <*> pure parsedTimeout

parseExecTimeout :: Value -> AesonTypes.Parser ExecTimeout
parseExecTimeout =
  withObject "ExecTimeout" $ \value ->
    ExecTimeoutSeconds <$> value .: "seconds"

data CommandToolResponse = CommandToolResponse
  { commandToolExitCode :: Int
  , commandToolStdout :: ByteString
  , commandToolStderr :: ByteString
  , commandToolTimedOut :: Bool
  }
  deriving stock (Eq, Show)

class ToolRunner runner where
  type ToolRunnerEnv runner
  type ToolRequest runner
  type ToolResponse runner

  runTool
    :: runner -> ToolRunnerEnv runner -> ToolRequest runner -> IO (ToolResponse runner)
