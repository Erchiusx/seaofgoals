module Agent.SeaOfGoals.Workspace.Bwrap.Profile
  ( DemoPaths (..)
  , demoWorkspaceOnlyView
  )
where

import Agent.SeaOfGoals.Workspace.Bwrap.Command
  ( ExecutionView (..)
  , HostRoot (..)
  , Mount (..)
  )
import Agent.SeaOfGoals.Workspace.Sandbox
  ( BindMode (..)
  )

data DemoPaths = DemoPaths
  { demoWorkspaceHostPath :: FilePath
  , demoCacheHostPath :: FilePath
  , demoHomeHostPath :: FilePath
  , demoTmpHostPath :: FilePath
  }
  deriving stock (Eq, Show)

demoWorkspaceOnlyView :: DemoPaths -> ExecutionView
demoWorkspaceOnlyView paths =
  ExecutionView
    { viewHostRoot = ReadOnlyHostRoot
    , viewMounts =
        [ Mount
            { mountHostPath = demoWorkspaceHostPath paths
            , mountSandboxPath = "/workspace"
            , mountMode = BindReadWrite
            }
        , Mount
            { mountHostPath = demoCacheHostPath paths
            , mountSandboxPath = "/cache"
            , mountMode = BindReadWrite
            }
        , Mount
            { mountHostPath = demoHomeHostPath paths
            , mountSandboxPath = "/home/sog"
            , mountMode = BindReadWrite
            }
        , Mount
            { mountHostPath = demoTmpHostPath paths
            , mountSandboxPath = "/tmp"
            , mountMode = BindReadWrite
            }
        ]
    , viewEnv =
        [ ("HOME", "/home/sog")
        , ("USER", "sog")
        , ("LOGNAME", "sog")
        , ("XDG_CACHE_HOME", "/cache/xdg")
        , ("XDG_STATE_HOME", "/cache/state")
        , ("XDG_CONFIG_HOME", "/workspace/.sog/config")
        , ("TMPDIR", "/tmp")
        , ("CABAL_DIR", "/workspace/.sog/cabal-home")
        , ("CABAL_CONFIG", "/workspace/.sog/cabal-home/config")
        , ("CABAL_STORE_DIR", "/workspace/.sog/cabal-store")
        , ("CARGO_HOME", "/workspace/.sog/cargo")
        , ("NPM_CONFIG_CACHE", "/cache/npm")
        , ("PIP_CACHE_DIR", "/cache/pip")
        ]
    , viewUnsetEnv =
        [ "SSH_AUTH_SOCK"
        , "GPG_AGENT_INFO"
        ]
    , viewDefaultCwd = "/workspace"
    }
