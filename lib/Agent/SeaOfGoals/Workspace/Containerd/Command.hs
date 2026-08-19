module Agent.SeaOfGoals.Workspace.Containerd.Command
  ( Config (..)
  , Handle (..)
  , Mount (..)
  , Root (..)
  , TaskSpec (..)
  , containerdContainerDeleteArgs
  , containerdContainerId
  , containerdCreateArgs
  , containerdExecArgs
  , containerdTaskDeleteArgs
  , containerdTaskStartArgs
  )
where

import Agent.SeaOfGoals.Workspace.Sandbox
  ( BindMode (..)
  , ExecSpec (..)
  )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

data Config = Config
  { configBinary :: FilePath
  , configNamespace :: Maybe Text
  , configAddress :: Maybe FilePath
  , configSnapshotter :: Maybe Text
  }
  deriving stock (Eq, Show)

data Mount = Mount
  { mountHostPath :: FilePath
  , mountContainerPath :: FilePath
  , mountMode :: BindMode
  }
  deriving stock (Eq, Show)

data Root
  = Image Text
  | Rootfs FilePath
  deriving stock (Eq, Show)

data TaskSpec = TaskSpec
  { taskId :: Text
  , taskRoot :: Root
  , taskMounts :: [Mount]
  , taskLabels :: Map.Map Text Text
  , taskInitArgv :: [Text]
  }
  deriving stock (Eq, Show)

data Handle = Handle
  { handleId :: Text
  , handleConfig :: Config
  }
  deriving stock (Eq, Show)

containerdContainerId :: Text -> Text
containerdContainerId taskId =
  "sog-" <> sanitizeText taskId

containerdCreateArgs :: Config -> TaskSpec -> [String]
containerdCreateArgs config spec =
  globalArgs config
    <> ["containers", "create"]
    <> snapshotterArgs config
    <> rootOptionArgs (taskRoot spec)
    <> concatMap mountArgs (taskMounts spec)
    <> concatMap labelArgs (Map.toList (taskLabels spec))
    <> [ containerdRootRef (taskRoot spec)
       , Text.unpack (containerdContainerId (taskId spec))
       ]
    <> fmap Text.unpack (taskInitArgv spec)

containerdTaskStartArgs :: Config -> Handle -> [String]
containerdTaskStartArgs config handle =
  globalArgs config
    <> ["tasks", "start", "--detach", Text.unpack (handleId handle)]

containerdExecArgs
  :: Config
  -> Handle
  -> Text
  -> ExecSpec
  -> [String]
containerdExecArgs config handle execId spec =
  globalArgs config
    <> ["tasks", "exec", "--exec-id", Text.unpack execId, "--cwd", resolvedCwd]
    <> [Text.unpack (handleId handle)]
    <> envPrefix
    <> fmap Text.unpack (execArgv spec)
 where
  resolvedCwd =
    case execCwd spec of
      "" -> "/workspace"
      "." -> "/workspace"
      path -> path
  envPrefix =
    case execEnv spec of
      [] -> []
      values -> "env" : fmap envAssignment values
  envAssignment (key, value) =
    Text.unpack (key <> "=" <> value)

containerdTaskDeleteArgs :: Config -> Handle -> [String]
containerdTaskDeleteArgs config handle =
  globalArgs config
    <> ["tasks", "delete", "--force", Text.unpack (handleId handle)]

containerdContainerDeleteArgs
  :: Config -> Handle -> [String]
containerdContainerDeleteArgs config handle =
  globalArgs config
    <> ["containers", "delete", Text.unpack (handleId handle)]

globalArgs :: Config -> [String]
globalArgs config =
  [configBinary config]
    <> maybe [] (\address -> ["--address", address]) (configAddress config)
    <> maybe
      []
      (\namespace -> ["--namespace", Text.unpack namespace])
      (configNamespace config)

snapshotterArgs :: Config -> [String]
snapshotterArgs config =
  maybe
    []
    (\snapshotter -> ["--snapshotter", Text.unpack snapshotter])
    (configSnapshotter config)

rootOptionArgs :: Root -> [String]
rootOptionArgs (Image _) = []
rootOptionArgs (Rootfs _) = ["--rootfs"]

containerdRootRef :: Root -> String
containerdRootRef (Image image) = Text.unpack image
containerdRootRef (Rootfs path) = path

mountArgs :: Mount -> [String]
mountArgs mount =
  ["--mount", mountSpec mount]

mountSpec :: Mount -> String
mountSpec mount =
  "type=bind,src="
    <> mountHostPath mount
    <> ",dst="
    <> mountContainerPath mount
    <> ",options=rbind:"
    <> bindModeText (mountMode mount)

bindModeText :: BindMode -> String
bindModeText BindReadOnly = "ro"
bindModeText BindReadWrite = "rw"

labelArgs :: (Text, Text) -> [String]
labelArgs (key, value) =
  ["--label", Text.unpack (key <> "=" <> value)]

sanitizeText :: Text -> Text
sanitizeText =
  Text.map sanitizeChar
 where
  sanitizeChar character
    | character >= 'a' && character <= 'z' = character
    | character >= 'A' && character <= 'Z' = character
    | character >= '0' && character <= '9' = character
    | character == '-' || character == '_' || character == '.' = character
    | otherwise = '-'
