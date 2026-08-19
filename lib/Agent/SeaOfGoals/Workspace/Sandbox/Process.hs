module Agent.SeaOfGoals.Workspace.Sandbox.Process
  ( ProcessSandboxHandle (..)
  , ProcessSandboxRunner (..)
  , ProcessSandboxSpec (..)
  )
where

import Agent.SeaOfGoals.Workspace.ProcessExec
  ( ProcessExecSpec (..)
  , runProcessExec
  )
import Agent.SeaOfGoals.Workspace.Sandbox
  ( ExecSpec (..)
  , SandboxExecOutcome
  , SandboxRunner (..)
  )
import Data.Text (Text)
import Data.Text qualified as Text

data ProcessSandboxRunner = ProcessSandboxRunner
  deriving stock (Eq, Show)

data ProcessSandboxSpec = ProcessSandboxSpec
  { processSandboxId :: Text
  , processSandboxWorkspace :: FilePath
  }
  deriving stock (Eq, Show)

data ProcessSandboxHandle = ProcessSandboxHandle
  { processSandboxHandleId :: Text
  , processSandboxHandleWorkspace :: FilePath
  }
  deriving stock (Eq, Show)

instance SandboxRunner ProcessSandboxRunner where
  type SandboxSpec ProcessSandboxRunner = ProcessSandboxSpec
  type SandboxHandle ProcessSandboxRunner = ProcessSandboxHandle
  type SandboxExecSpec ProcessSandboxRunner = ExecSpec

  createSandbox _ spec =
    pure
      ProcessSandboxHandle
        { processSandboxHandleId = processSandboxId spec
        , processSandboxHandleWorkspace = processSandboxWorkspace spec
        }

  execInSandbox _ handle spec =
    runProcessWithTimeout handle spec

  destroySandbox _ _ =
    pure ()

  sandboxId _ =
    processSandboxHandleId

runProcessWithTimeout
  :: ProcessSandboxHandle -> ExecSpec -> IO SandboxExecOutcome
runProcessWithTimeout handle spec =
  runProcessExec
    ProcessExecSpec
      { processExecArgv = Text.unpack <$> execArgv spec
      , processExecCwd = Just (resolveCwd handle spec)
      , processExecEnv = sandboxEnv spec
      , processExecTimeout = execTimeout spec
      }

resolveCwd :: ProcessSandboxHandle -> ExecSpec -> FilePath
resolveCwd handle spec =
  case execCwd spec of
    "" -> processSandboxHandleWorkspace handle
    "." -> processSandboxHandleWorkspace handle
    path -> path

sandboxEnv :: ExecSpec -> Maybe [(String, String)]
sandboxEnv spec =
  case execEnv spec of
    [] -> Nothing
    values -> Just (fmap (\(key, value) -> (Text.unpack key, Text.unpack value)) values)
