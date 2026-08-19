module Agent.SeaOfGoals.Workspace.Bwrap.Command
  ( Config (..)
  , ExecutionView (..)
  , HostRoot (..)
  , Mount (..)
  , bwrapCommand
  )
where

import Agent.SeaOfGoals.Workspace.Sandbox
  ( BindMode (..)
  , ExecSpec (..)
  )
import Data.Text (Text)
import Data.Text qualified as Text

data Config = Config
  { configBinary :: FilePath
  }
  deriving stock (Eq, Show)

data HostRoot
  = ReadOnlyHostRoot
  | NoHostRoot
  deriving stock (Eq, Show)

data Mount = Mount
  { mountHostPath :: FilePath
  , mountSandboxPath :: FilePath
  , mountMode :: BindMode
  }
  deriving stock (Eq, Show)

data ExecutionView = ExecutionView
  { viewHostRoot :: HostRoot
  , viewMounts :: [Mount]
  , viewEnv :: [(Text, Text)]
  , viewUnsetEnv :: [Text]
  , viewDefaultCwd :: FilePath
  }
  deriving stock (Eq, Show)

bwrapCommand
  :: Config -> ExecutionView -> ExecSpec -> [String]
bwrapCommand config view spec =
  [configBinary config]
    <> ["--die-with-parent"]
    <> hostRootArgs (viewHostRoot view)
    <> concatMap mountPointDirArgs (viewMounts view)
    <> concatMap mountArgs (viewMounts view)
    <> concatMap setEnvArgs (viewEnv view <> execEnv spec)
    <> concatMap unsetEnvArgs (viewUnsetEnv view)
    <> ["--chdir", executionCwd view spec]
    <> ["--"]
    <> fmap Text.unpack (execArgv spec)

hostRootArgs :: HostRoot -> [String]
hostRootArgs ReadOnlyHostRoot =
  [ "--tmpfs"
  , "/"
  , "--dir"
  , "/usr"
  , "--ro-bind"
  , "/usr"
  , "/usr"
  , "--dir"
  , "/etc"
  , "--ro-bind"
  , "/etc"
  , "/etc"
  , "--symlink"
  , "usr/bin"
  , "/bin"
  , "--symlink"
  , "usr/lib"
  , "/lib"
  , "--symlink"
  , "usr/lib64"
  , "/lib64"
  , "--proc"
  , "/proc"
  , "--dev"
  , "/dev"
  ]
hostRootArgs NoHostRoot =
  []

mountPointDirArgs :: Mount -> [String]
mountPointDirArgs mount =
  ["--dir", mountSandboxPath mount]

mountArgs :: Mount -> [String]
mountArgs mount =
  [ bindFlag (mountMode mount)
  , mountHostPath mount
  , mountSandboxPath mount
  ]

bindFlag :: BindMode -> String
bindFlag BindReadOnly = "--ro-bind"
bindFlag BindReadWrite = "--bind"

setEnvArgs :: (Text, Text) -> [String]
setEnvArgs (key, value) =
  ["--setenv", Text.unpack key, Text.unpack value]

unsetEnvArgs :: Text -> [String]
unsetEnvArgs key =
  ["--unsetenv", Text.unpack key]

executionCwd :: ExecutionView -> ExecSpec -> FilePath
executionCwd view spec =
  case execCwd spec of
    "" -> viewDefaultCwd view
    "." -> viewDefaultCwd view
    path -> path
