module Agent.SeaOfGoals.CodexProcess
  ( CodexProcessConfig (..)
  , CodexProcessResult (..)
  , codexProcessExecSpec
  , codexProcessView
  , defaultCodexProcessConfig
  , loadCodexProcessConfigFromEnv
  , runCodexProcess
  )
where

import Agent.SeaOfGoals.Trace
  ( HarnessEvent (..)
  )
import Agent.SeaOfGoals.Workspace.Bwrap.Command qualified as BwrapCommand
import Agent.SeaOfGoals.Workspace.ProcessExec
  ( ProcessExecSpec (..)
  , runProcessExec
  )
import Agent.SeaOfGoals.Workspace.Sandbox
  ( BindMode (..)
  , ExecSpec (..)
  , ExecTimeout (..)
  , SandboxExecOutcome (..)
  )
import Control.Monad (forM_, when)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
  , getHomeDirectory
  )
import System.Environment
  ( lookupEnv
  )
import System.FilePath
  ( takeDirectory
  , (</>)
  )

data CodexProcessConfig = CodexProcessConfig
  { codexProcessBwrapBinary :: FilePath
  , codexProcessHostHome :: FilePath
  , codexProcessHostCodexHome :: FilePath
  , codexProcessHostCodexBinDir :: FilePath
  , codexProcessSandboxCodexHome :: FilePath
  , codexProcessSandboxCodexBinary :: FilePath
  , codexProcessModel :: Text
  , codexProcessTimeout :: ExecTimeout
  }
  deriving stock (Eq, Show)

data CodexProcessResult = CodexProcessResult
  { codexProcessExitCode :: Int
  , codexProcessTimedOut :: Bool
  , codexProcessStdout :: Text
  , codexProcessStderr :: Text
  , codexProcessLastMessage :: Text
  }
  deriving stock (Eq, Show)

defaultCodexProcessConfig :: IO CodexProcessConfig
defaultCodexProcessConfig = do
  home <- getHomeDirectory
  codexBinary <- findHostCodexBinary
  pure
    CodexProcessConfig
      { codexProcessBwrapBinary = "bwrap"
      , codexProcessHostHome = home
      , codexProcessHostCodexHome = home </> ".codex"
      , codexProcessHostCodexBinDir = takeDirectory codexBinary
      , codexProcessSandboxCodexHome = "/codex-home"
      , codexProcessSandboxCodexBinary = "/codex-bin/codex"
      , codexProcessModel = "gpt-5.5"
      , codexProcessTimeout = ExecNoTimeout
      }

loadCodexProcessConfigFromEnv :: IO CodexProcessConfig
loadCodexProcessConfigFromEnv = do
  defaults <- defaultCodexProcessConfig
  maybeBwrap <- lookupEnv "SOG_BWRAP"
  maybeCodexHome <- lookupEnv "SOG_CODEX_HOME"
  maybeCodexHomeEnv <- lookupEnv "CODEX_HOME"
  maybeCodexBinDir <- lookupEnv "SOG_CODEX_HOST_BIN_DIR"
  maybeCodexBin <- lookupEnv "SOG_CODEX_SANDBOX_BIN"
  maybeModel <- lookupEnv "SOG_CODEX_MODEL"
  maybeGenericModel <- lookupEnv "SOG_MODEL"
  pure
    defaults
      { codexProcessBwrapBinary =
          fromMaybeNonEmpty (codexProcessBwrapBinary defaults) maybeBwrap
      , codexProcessHostCodexHome =
          firstNonEmpty
            (codexProcessHostCodexHome defaults)
            [maybeCodexHome, maybeCodexHomeEnv]
      , codexProcessHostCodexBinDir =
          firstNonEmpty
            (codexProcessHostCodexBinDir defaults)
            [maybeCodexBinDir]
      , codexProcessSandboxCodexBinary =
          fromMaybeNonEmpty
            (codexProcessSandboxCodexBinary defaults)
            maybeCodexBin
      , codexProcessModel =
          Text.pack
            ( firstNonEmpty
                (Text.unpack (codexProcessModel defaults))
                [maybeModel, maybeGenericModel]
            )
      }

runCodexProcess
  :: CodexProcessConfig
  -> (HarnessEvent -> IO ())
  -> Maybe Text
  -> FilePath
  -> Text
  -> IO CodexProcessResult
runCodexProcess config eventSink goalId workspaceRoot prompt = do
  let
    promptPath = workspaceRoot </> ".sog" </> "codex-goal-prompt.txt"
    lastMessagePath = workspaceRoot </> ".sog" </> "codex-last-message.txt"
    view = codexProcessView config workspaceRoot
    spec =
      codexProcessExecSpec
        config
        "/workspace/.sog/codex-goal-prompt.txt"
        "/workspace/.sog/codex-last-message.txt"
    command = BwrapCommand.bwrapCommand (bwrapConfig config) view spec
  validateCodexHome config
  prepareCodexWorkspaceDirs workspaceRoot
  createDirectoryIfMissing True (takeDirectory promptPath)
  TextIO.writeFile promptPath prompt
  eventSink
    ProcessStarted
      { eventProcessKind = "codex"
      , eventGoalId = goalId
      , eventCommand = fmap Text.pack command
      , eventWorkspace = Just workspaceRoot
      }
  outcome <-
    runProcessExec
      ProcessExecSpec
        { processExecArgv = command
        , processExecCwd = Nothing
        , processExecEnv = Nothing
        , processExecTimeout = codexProcessTimeout config
        }
  lastMessage <- readTextFileIfExists lastMessagePath
  let result = codexProcessResultFromOutcome outcome lastMessage
  eventSink
    ProcessFinished
      { eventProcessKind = "codex"
      , eventGoalId = goalId
      , eventExitCode = codexProcessExitCode result
      , eventTimedOut = codexProcessTimedOut result
      , eventStdout = truncateTraceText (codexProcessStdout result)
      , eventStderr = truncateTraceText (codexProcessStderr result)
      }
  pure result

codexProcessView
  :: CodexProcessConfig -> FilePath -> BwrapCommand.ExecutionView
codexProcessView config workspaceRoot =
  BwrapCommand.ExecutionView
    { BwrapCommand.viewHostRoot = BwrapCommand.ReadOnlyHostRoot
    , BwrapCommand.viewMounts =
        [ BwrapCommand.Mount
            { BwrapCommand.mountHostPath = workspaceRoot
            , BwrapCommand.mountSandboxPath = "/workspace"
            , BwrapCommand.mountMode = BindReadWrite
            }
        , BwrapCommand.Mount
            { BwrapCommand.mountHostPath = codexProcessHostCodexHome config
            , BwrapCommand.mountSandboxPath = codexProcessSandboxCodexHome config
            , BwrapCommand.mountMode = BindReadWrite
            }
        , BwrapCommand.Mount
            { BwrapCommand.mountHostPath = codexProcessHostCodexBinDir config
            , BwrapCommand.mountSandboxPath = "/codex-bin"
            , BwrapCommand.mountMode = BindReadOnly
            }
        , BwrapCommand.Mount
            { BwrapCommand.mountHostPath = workspaceRoot </> ".sog" </> "codex-home"
            , BwrapCommand.mountSandboxPath = "/home/sog"
            , BwrapCommand.mountMode = BindReadWrite
            }
        , BwrapCommand.Mount
            { BwrapCommand.mountHostPath = workspaceRoot </> ".sog" </> "codex-cache"
            , BwrapCommand.mountSandboxPath = "/cache"
            , BwrapCommand.mountMode = BindReadWrite
            }
        , BwrapCommand.Mount
            { BwrapCommand.mountHostPath = workspaceRoot </> ".sog" </> "codex-tmp"
            , BwrapCommand.mountSandboxPath = "/tmp"
            , BwrapCommand.mountMode = BindReadWrite
            }
        ]
    , BwrapCommand.viewEnv =
        [ ("HOME", "/home/sog")
        , ("USER", "sog")
        , ("LOGNAME", "sog")
        , ("CODEX_HOME", Text.pack (codexProcessSandboxCodexHome config))
        , ("SOG_MODEL", codexProcessModel config)
        , ("XDG_CACHE_HOME", "/cache/xdg")
        , ("XDG_STATE_HOME", "/cache/state")
        , ("TMPDIR", "/tmp")
        ]
    , BwrapCommand.viewUnsetEnv =
        [ "OPENAI_API_KEY"
        , "CODEX_API_KEY"
        , "CODEX_ACCESS_TOKEN"
        , "SSH_AUTH_SOCK"
        , "GPG_AGENT_INFO"
        ]
    , BwrapCommand.viewDefaultCwd = "/workspace"
    }

codexProcessExecSpec :: CodexProcessConfig -> FilePath -> FilePath -> ExecSpec
codexProcessExecSpec config promptPath lastMessagePath =
  ExecSpec
    { execArgv =
        [ "/bin/sh"
        , "-lc"
        , Text.unwords
            [ "exec"
            , Text.pack (codexProcessSandboxCodexBinary config)
            , "exec"
            , "--json"
            , "--skip-git-repo-check"
            , "--ephemeral"
            , "--dangerously-bypass-approvals-and-sandbox"
            , "-C /workspace"
            , "--model \"$SOG_MODEL\""
            , "--output-last-message"
            , Text.pack lastMessagePath
            , "-"
            , "<"
            , Text.pack promptPath
            ]
        ]
    , execCwd = "/workspace"
    , execEnv = []
    , execTimeout = codexProcessTimeout config
    }

bwrapConfig :: CodexProcessConfig -> BwrapCommand.Config
bwrapConfig config =
  BwrapCommand.Config
    { BwrapCommand.configBinary = codexProcessBwrapBinary config
    }

validateCodexHome :: CodexProcessConfig -> IO ()
validateCodexHome config = do
  exists <- doesDirectoryExist (codexProcessHostCodexHome config)
  when (not exists) $
    fail ("CODEX_HOME does not exist: " <> codexProcessHostCodexHome config)
  binDirExists <- doesDirectoryExist (codexProcessHostCodexBinDir config)
  when (not binDirExists) $
    fail
      ("Codex binary directory does not exist: " <> codexProcessHostCodexBinDir config)

findHostCodexBinary :: IO FilePath
findHostCodexBinary = do
  maybeCodex <- findExecutable "codex"
  case maybeCodex of
    Nothing -> pure "codex"
    Just path -> canonicalizePath path

prepareCodexWorkspaceDirs :: FilePath -> IO ()
prepareCodexWorkspaceDirs workspaceRoot =
  forM_
    [ workspaceRoot </> ".sog" </> "codex-home"
    , workspaceRoot </> ".sog" </> "codex-cache"
    , workspaceRoot </> ".sog" </> "codex-tmp"
    ]
    (createDirectoryIfMissing True)

readTextFileIfExists :: FilePath -> IO Text
readTextFileIfExists path = do
  exists <- doesFileExist path
  if exists
    then TextEncoding.decodeUtf8 <$> ByteString.readFile path
    else pure ""

codexProcessResultFromOutcome
  :: SandboxExecOutcome -> Text -> CodexProcessResult
codexProcessResultFromOutcome outcome lastMessage =
  CodexProcessResult
    { codexProcessExitCode = sandboxExecExitCode outcome
    , codexProcessTimedOut = sandboxExecTimedOut outcome
    , codexProcessStdout =
        TextEncoding.decodeUtf8Lenient (sandboxExecStdout outcome)
    , codexProcessStderr =
        TextEncoding.decodeUtf8Lenient (sandboxExecStderr outcome)
    , codexProcessLastMessage = lastMessage
    }

truncateTraceText :: Text -> Text
truncateTraceText text
  | Text.length text <= 20000 = text
  | otherwise = Text.take 20000 text <> "\n... truncated ..."

firstNonEmpty :: String -> [Maybe String] -> String
firstNonEmpty fallback values =
  case [value | Just value <- values, not (null value)] of
    value : _ -> value
    [] -> fallback

fromMaybeNonEmpty :: String -> Maybe String -> String
fromMaybeNonEmpty _ (Just value)
  | not (null value) = value
fromMaybeNonEmpty fallback _ = fallback
