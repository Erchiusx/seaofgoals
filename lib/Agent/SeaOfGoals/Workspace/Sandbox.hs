module Agent.SeaOfGoals.Workspace.Sandbox
  ( BindMode (..)
  , ExecTimeout (..)
  , SandboxExecOutcome (..)
  , SandboxMount (..)
  , ExecSpec (..)
  , SandboxRunner (..)
  )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Numeric.Natural (Natural)

data BindMode
  = BindReadOnly
  | BindReadWrite
  deriving stock (Eq, Show)

data SandboxMount = SandboxMount
  { sandboxMountHostPath :: FilePath
  , sandboxMountAgentPath :: FilePath
  , sandboxMountMode :: BindMode
  }
  deriving stock (Eq, Show)

data ExecTimeout
  = ExecNoTimeout
  | ExecTimeoutSeconds Natural
  deriving stock (Eq, Show)

data SandboxExecOutcome = SandboxExecOutcome
  { sandboxExecExitCode :: Int
  , sandboxExecStdout :: ByteString
  , sandboxExecStderr :: ByteString
  , sandboxExecTimedOut :: Bool
  }
  deriving stock (Eq, Show)

data ExecSpec = ExecSpec
  { execArgv :: [Text]
  , execCwd :: FilePath
  , execEnv :: [(Text, Text)]
  , execTimeout :: ExecTimeout
  }
  deriving stock (Eq, Show)

class SandboxRunner runner where
  type SandboxSpec runner
  type SandboxHandle runner
  type SandboxExecSpec runner

  createSandbox :: runner -> SandboxSpec runner -> IO (SandboxHandle runner)
  execInSandbox
    :: runner
    -> SandboxHandle runner
    -> SandboxExecSpec runner
    -> IO SandboxExecOutcome
  destroySandbox :: runner -> SandboxHandle runner -> IO ()
  sandboxId :: runner -> SandboxHandle runner -> Text
