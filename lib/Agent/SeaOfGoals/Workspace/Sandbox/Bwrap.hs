module Agent.SeaOfGoals.Workspace.Sandbox.Bwrap
  ( BwrapSandboxHandle (..)
  , BwrapSandboxRunner (..)
  , BwrapSandboxSpec (..)
  )
where

import Agent.SeaOfGoals.Workspace.Bwrap.Command
  ( Config
  , ExecutionView
  , bwrapCommand
  )
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

data BwrapSandboxRunner = BwrapSandboxRunner
  { bwrapSandboxConfig :: Config
  }
  deriving stock (Eq, Show)

data BwrapSandboxSpec = BwrapSandboxSpec
  { bwrapSandboxId :: Text
  , bwrapSandboxView :: ExecutionView
  }
  deriving stock (Eq, Show)

data BwrapSandboxHandle = BwrapSandboxHandle
  { bwrapSandboxHandleId :: Text
  , bwrapSandboxHandleView :: ExecutionView
  }
  deriving stock (Eq, Show)

instance SandboxRunner BwrapSandboxRunner where
  type SandboxSpec BwrapSandboxRunner = BwrapSandboxSpec
  type SandboxHandle BwrapSandboxRunner = BwrapSandboxHandle
  type SandboxExecSpec BwrapSandboxRunner = ExecSpec

  createSandbox _ spec =
    pure
      BwrapSandboxHandle
        { bwrapSandboxHandleId = bwrapSandboxId spec
        , bwrapSandboxHandleView = bwrapSandboxView spec
        }

  execInSandbox runner handle spec =
    runBwrapCommand (bwrapSandboxConfig runner) handle spec

  destroySandbox _ _ =
    pure ()

  sandboxId _ =
    bwrapSandboxHandleId

runBwrapCommand
  :: Config
  -> BwrapSandboxHandle
  -> ExecSpec
  -> IO SandboxExecOutcome
runBwrapCommand config handle spec =
  runProcessExec
    ProcessExecSpec
      { processExecArgv =
          bwrapCommand config (bwrapSandboxHandleView handle) spec
      , processExecCwd = Nothing
      , processExecEnv = Nothing
      , processExecTimeout = execTimeout spec
      }
