module Agent.SeaOfGoals.PiProcess
  ( PiProcessConfig (..)
  , PiProcessResult (..)
  , defaultPiProcessConfig
  , loadPiProcessConfigFromEnv
  , runPiProcess
  , runPiSdkProcess
  , piExpectedVersion
  )
where

import Agent.SeaOfGoals.LLM
  ( LLMContentPart (..)
  , LLMInputItem (..)
  , LLMMessage (..)
  , LLMRole (..)
  , ToolCall (..)
  , ToolResult (..)
  )
import Agent.SeaOfGoals.Trace
  ( HarnessEvent
      ( AssistantMessageObserved
      , CodexEventObserved
      , ModelUsageObserved
      , ProcessFinished
      , ProcessStarted
      , ToolCallObserved
      , ToolResultObserved
      , UserMessageObserved
      )
  )
import Agent.SeaOfGoals.Workspace.Bwrap.Command qualified as BwrapCommand
import Agent.SeaOfGoals.Workspace.ProcessExec
  ( ProcessExecSpec (..)
  , runProcessExecWithStdoutLineSink
  )
import Agent.SeaOfGoals.Workspace.Sandbox
  ( BindMode (..)
  , ExecSpec (..)
  , ExecTimeout (..)
  , SandboxExecOutcome (..)
  )
import Control.Exception (SomeException, try)
import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.Vector qualified as Vector
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , findExecutable
  , getCurrentDirectory
  )
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.Process (readProcess)

piExpectedVersion :: Text
piExpectedVersion = "0.85.1"

data PiProcessConfig = PiProcessConfig
  { piProcessBinary :: FilePath
  , piProcessExtension :: Maybe FilePath
  , piProcessNodeBinary :: FilePath
  , piProcessSdkRunner :: Maybe FilePath
  , piProcessModel :: Maybe Text
  , piProcessTimeout :: ExecTimeout
  , piProcessBwrapBinary :: Maybe FilePath
  }
  deriving stock (Eq, Show)

data PiProcessResult = PiProcessResult
  { piProcessExitCode :: Int
  , piProcessTimedOut :: Bool
  , piProcessStdout :: Text
  , piProcessStderr :: Text
  }
  deriving stock (Eq, Show)

defaultPiProcessConfig :: IO PiProcessConfig
defaultPiProcessConfig = do
  home <- lookupEnv "HOME"
  workingDirectory <- getCurrentDirectory
  pathBinary <- findExecutable "pi"
  nodeBinary <- findExecutable "node"
  bwrapBinary <- findExecutable "bwrap"
  let localBinary =
        (\directory -> directory </> "development/pi/packages/coding-agent/dist/cli.js")
          <$> home
  binary <-
    case localBinary of
      Just candidate -> do
        exists <- doesFileExist candidate
        pure (if exists then candidate else maybe "pi" id pathBinary)
      Nothing -> pure (maybe "pi" id pathBinary)
  let extensionCandidate = workingDirectory </> "pi/sog-goal-extension.mjs"
  extensionExists <- doesFileExist extensionCandidate
  pure
    PiProcessConfig
      { piProcessBinary = binary
      , piProcessExtension =
          if extensionExists then Just extensionCandidate else Nothing
      , piProcessNodeBinary = maybe "node" id nodeBinary
      , piProcessSdkRunner =
          if extensionExists
            then Just (workingDirectory </> "pi/sog-sdk-runner.mjs")
            else Nothing
      , piProcessModel = Nothing
      , piProcessTimeout = ExecNoTimeout
      , piProcessBwrapBinary = bwrapBinary
      }

loadPiProcessConfigFromEnv :: IO PiProcessConfig
loadPiProcessConfigFromEnv = do
  defaults <- defaultPiProcessConfig
  maybeBinary <- lookupEnv "SOG_PI_BINARY"
  maybeExtension <- lookupEnv "SOG_PI_EXTENSION"
  maybeNode <- lookupEnv "SOG_PI_NODE"
  maybeSdkRunner <- lookupEnv "SOG_PI_SDK_RUNNER"
  maybeModel <- lookupEnv "SOG_PI_MODEL"
  maybeBwrap <- lookupEnv "SOG_BWRAP"
  pure
    defaults
      { piProcessBinary = maybe (piProcessBinary defaults) id maybeBinary
      , piProcessExtension = maybe (piProcessExtension defaults) Just maybeExtension
      , piProcessNodeBinary = maybe (piProcessNodeBinary defaults) id maybeNode
      , piProcessSdkRunner = maybe (piProcessSdkRunner defaults) Just maybeSdkRunner
      , piProcessModel = Text.pack <$> maybeModel
      , piProcessBwrapBinary =
          case maybeBwrap of
            Just value | not (null value) -> Just value
            _ -> piProcessBwrapBinary defaults
      }

runPiProcess
  :: PiProcessConfig
  -> (HarnessEvent -> IO ())
  -> Maybe Text
  -> FilePath
  -> Text
  -> IO PiProcessResult
runPiProcess config eventSink goalId workspace prompt = do
  versionCheck <- ensurePiVersion config
  case versionCheck of
    Left message -> pure (failedResult message)
    Right () -> runChecked
 where
  failedResult message =
    PiProcessResult
      { piProcessExitCode = 126
      , piProcessTimedOut = False
      , piProcessStdout = ""
      , piProcessStderr = message
      }

  runChecked = do
    let command =
          [ piProcessBinary config
          , "--mode"
          , "json"
          , "--print"
          , "--no-session"
          ]
            <> maybe [] (\extension -> ["--extension", extension]) (piProcessExtension config)
            <> maybe [] (\model -> ["--model", Text.unpack model]) (piProcessModel config)
            <> [Text.unpack prompt]
    eventSink (ProcessStarted "pi" goalId (fmap Text.pack command) (Just workspace))
    outcome <-
      runProcessExecWithStdoutLineSink
        ProcessExecSpec
          { processExecArgv = command
          , processExecCwd = Just workspace
          , processExecEnv = Nothing
          , processExecTimeout = piProcessTimeout config
          , processExecStdin = Nothing
          }
        (emitPiEvent eventSink goalId)
    let result =
          PiProcessResult
            { piProcessExitCode = sandboxExecExitCode outcome
            , piProcessTimedOut = sandboxExecTimedOut outcome
            , piProcessStdout = decode (sandboxExecStdout outcome)
            , piProcessStderr = decode (sandboxExecStderr outcome)
            }
    eventSink
      ( ProcessFinished
          "pi"
          goalId
          (piProcessExitCode result)
          (piProcessTimedOut result)
          (piProcessStdout result)
          (piProcessStderr result)
      )
    pure result
   where
    decode = TextEncoding.decodeUtf8With lenientDecode

runPiSdkProcess
  :: PiProcessConfig
  -> (HarnessEvent -> IO ())
  -> Maybe Text
  -> FilePath
  -> FilePath
  -> Text
  -> [LLMInputItem]
  -> IO PiProcessResult
runPiSdkProcess config eventSink goalId workspace controlRoot prompt history = do
  versionCheck <- ensurePiVersion config
  case versionCheck of
    Left message -> pure (sdkFailure message)
    Right () -> runSdk
 where
  runSdk = do
    let
      requestPath = controlRoot </> "pi-sdk-request.json"
      request =
        object
          [ "cwd" .= ("/workspace" :: Text)
          , "agentDir" .= ("/pi-agent" :: Text)
          , "prompt" .= prompt
          , "model" .= piProcessModel config
          , "messages" .= fmap piMessage (filter isPiHistoryItem history)
          ]
    createDirectoryIfMissing True controlRoot
    createDirectoryIfMissing True (controlRoot </> "pi-agent")
    LazyByteString.writeFile requestPath (Aeson.encode request)
    case piProcessSdkRunner config of
      Nothing -> pure (sdkFailure "Pi SDK runner is not configured")
      Just runner -> do
        eventSink
          ( ProcessStarted
              "pi-sdk"
              goalId
              ["node", Text.pack runner, Text.pack requestPath]
              (Just workspace)
          )
        outcome <-
          runProcessExecWithStdoutLineSink
            ProcessExecSpec
              { processExecArgv = sdkCommand config runner workspace
              , processExecCwd = Nothing
              , processExecEnv = Nothing
              , processExecTimeout = piProcessTimeout config
              , processExecStdin =
                  Just (LazyByteString.toStrict (Aeson.encode request) <> "\n")
              }
            (emitPiEvent eventSink goalId)
        let result =
              PiProcessResult
                { piProcessExitCode = sandboxExecExitCode outcome
                , piProcessTimedOut = sandboxExecTimedOut outcome
                , piProcessStdout = decode (sandboxExecStdout outcome)
                , piProcessStderr = decode (sandboxExecStderr outcome)
                }
        eventSink
          ( ProcessFinished
              "pi-sdk"
              goalId
              (piProcessExitCode result)
              (piProcessTimedOut result)
              (piProcessStdout result)
              (piProcessStderr result)
          )
        pure result

  sdkCommand config runner workspace =
    case piProcessBwrapBinary config of
      Nothing ->
        [ "sh"
        , "-c"
        , "printf '%s\\n' 'bwrap is required for Pi SDK execution' >&2; exit 126"
        ]
      Just bwrap ->
        BwrapCommand.bwrapCommand
          (BwrapCommand.Config bwrap)
          BwrapCommand.ExecutionView
            { BwrapCommand.viewHostRoot = BwrapCommand.ReadOnlyHostRoot
            , BwrapCommand.viewMounts =
                [ BwrapCommand.Mount workspace "/workspace" BindReadWrite
                , BwrapCommand.Mount
                    (controlRoot </> "pi-agent")
                    "/pi-agent"
                    BindReadWrite
                , BwrapCommand.Mount
                    (takeDirectory runner)
                    "/sog-pi"
                    BindReadOnly
                , BwrapCommand.Mount
                    (piRootFromBinary (piProcessBinary config))
                    "/pi-root"
                    BindReadOnly
                , BwrapCommand.Mount
                    (takeDirectory (piProcessNodeBinary config))
                    "/node-bin"
                    BindReadOnly
                ]
            , BwrapCommand.viewEnv = [("SOG_PI_ROOT", "/pi-root")]
            , BwrapCommand.viewUnsetEnv = []
            , BwrapCommand.viewDefaultCwd = "/workspace"
            }
          ExecSpec
            { execArgv =
                [ "/node-bin/" <> Text.pack (takeFileName (piProcessNodeBinary config))
                , "/sog-pi/sog-sdk-runner.mjs"
                ]
            , execCwd = "/workspace"
            , execEnv = []
            , execTimeout = piProcessTimeout config
            }

  piRootFromBinary binary =
    takeDirectory
      ( takeDirectory
          ( takeDirectory
              (takeDirectory binary)
          )
      )

  decode = TextEncoding.decodeUtf8With lenientDecode
  sdkFailure message = PiProcessResult 126 False "" message

ensurePiVersion :: PiProcessConfig -> IO (Either Text ())
ensurePiVersion config = do
  versionResult <- try (readProcess (piProcessBinary config) ["--version"] "")
  pure $
    case versionResult of
      Left (err :: SomeException) ->
        Left ("unable to start pi: " <> Text.pack (show err))
      Right versionOutput
        | Text.strip (Text.pack versionOutput) /= piExpectedVersion ->
            Left
              ( "unsupported pi version: expected "
                  <> piExpectedVersion
                  <> ", got "
                  <> Text.strip (Text.pack versionOutput)
              )
        | otherwise -> Right ()

isPiHistoryItem :: LLMInputItem -> Bool
isPiHistoryItem (MessageInput message) = messageRole message /= System
isPiHistoryItem (ToolCallInput _) = True
isPiHistoryItem (ToolResultInput _) = True
isPiHistoryItem (ReasoningInput _) = False
isPiHistoryItem _ = False

piMessage :: LLMInputItem -> Value
piMessage (MessageInput message) =
  object
    [ "role" .= piRole (messageRole message)
    , "content"
        .= [ object
               [ "type" .= ("text" :: Text)
               , "text" .= messageText message
               ]
           ]
    , "api" .= ("openai-responses" :: Text)
    , "provider" .= ("openai" :: Text)
    , "model" .= ("sog-history" :: Text)
    , "usage" .= piZeroUsage
    , "stopReason" .= ("stop" :: Text)
    , "timestamp" .= (0 :: Int)
    ]
piMessage (ToolCallInput call) =
  object
    [ "role" .= ("assistant" :: Text)
    , "content"
        .= [ object
               [ "type" .= ("toolCall" :: Text)
               , "id" .= toolCallId call
               , "name" .= toolCallName call
               , "arguments" .= toolCallArguments call
               ]
           ]
    , "api" .= ("openai-responses" :: Text)
    , "provider" .= ("openai" :: Text)
    , "model" .= ("sog-history" :: Text)
    , "usage"
        .= object
          [ "input" .= (0 :: Int)
          , "output" .= (0 :: Int)
          , "cacheRead" .= (0 :: Int)
          , "cacheWrite" .= (0 :: Int)
          , "reasoning" .= (0 :: Int)
          , "totalTokens" .= (0 :: Int)
          , "cost"
              .= object
                [ "input" .= (0 :: Int)
                , "output" .= (0 :: Int)
                , "cacheRead" .= (0 :: Int)
                , "cacheWrite" .= (0 :: Int)
                , "total" .= (0 :: Int)
                ]
          ]
    , "stopReason" .= ("toolUse" :: Text)
    , "timestamp" .= (0 :: Int)
    ]
piMessage (ToolResultInput result) =
  object
    [ "role" .= ("toolResult" :: Text)
    , "toolCallId" .= toolResultCallId result
    , "toolName" .= toolResultName result
    , "content" .= fmap contentPartText (toolResultContent result)
    , "usage" .= piZeroUsage
    , "isError" .= False
    , "timestamp" .= (0 :: Int)
    ]
piMessage (ReasoningInput _) = object []
piMessage (ArtifactInput _) = object []

piRole :: LLMRole -> Text
piRole User = "user"
piRole Assistant = "assistant"
piRole Tool = "toolResult"
piRole System = "user"

piZeroUsage :: Value
piZeroUsage =
  object
    [ "input" .= (0 :: Int)
    , "output" .= (0 :: Int)
    , "cacheRead" .= (0 :: Int)
    , "cacheWrite" .= (0 :: Int)
    , "reasoning" .= (0 :: Int)
    , "totalTokens" .= (0 :: Int)
    , "cost"
        .= object
          [ "input" .= (0 :: Int)
          , "output" .= (0 :: Int)
          , "cacheRead" .= (0 :: Int)
          , "cacheWrite" .= (0 :: Int)
          , "total" .= (0 :: Int)
          ]
    ]

messageText :: LLMMessage -> Text
messageText = Text.concat . fmap contentPartText . messageContent

contentPartText :: LLMContentPart -> Text
contentPartText (TextPart value) = value
contentPartText _ = "[non-text content omitted]"

emitPiEvent
  :: (HarnessEvent -> IO ()) -> Maybe Text -> ByteString.ByteString -> IO ()
emitPiEvent eventSink goalId line =
  case eitherDecodeStrict line of
    Right value -> do
      eventSink (CodexEventObserved goalId (value :: Value))
      mapPiEvent eventSink goalId value
    Left _ -> pure ()

mapPiEvent :: (HarnessEvent -> IO ()) -> Maybe Text -> Value -> IO ()
mapPiEvent eventSink goalId (Object objectValue) =
  case textField "type" objectValue of
    Just "message_end" ->
      case KeyMap.lookup (Key.fromString "message") objectValue of
        Just (Object message) ->
          case textField "role" message of
            Just "assistant" -> emitText AssistantMessageObserved message
            Just "user" -> eventSink (UserMessageObserved (textContent message))
            _ -> pure ()
        _ -> pure ()
    Just "tool_execution_start" ->
      case (textField "toolCallId" objectValue, textField "toolName" objectValue) of
        (Just callId, Just toolName) ->
          eventSink
            ( ToolCallObserved
                callId
                toolName
                (maybe Null id (KeyMap.lookup (Key.fromString "args") objectValue))
                goalId
            )
        _ -> pure ()
    Just "tool_execution_end" ->
      case (textField "toolCallId" objectValue, textField "toolName" objectValue) of
        (Just callId, Just toolName) ->
          eventSink
            ( ToolResultObserved
                callId
                toolName
                (maybe "" valueText (KeyMap.lookup (Key.fromString "result") objectValue))
                goalId
            )
        _ -> pure ()
    Just "message_update" ->
      case KeyMap.lookup (Key.fromString "usage") objectValue of
        Just (Object usage) ->
          eventSink
            ( ModelUsageObserved
                (integerField "input" usage)
                (optionalIntegerField "cacheRead" usage)
                (integerField "output" usage)
                (optionalIntegerField "reasoning" usage)
                (integerField "totalTokens" usage)
            )
        _ -> pure ()
    _ -> pure ()
 where
  emitText constructor message = do
    let content = textContent message
    if Text.null content then pure () else eventSink (constructor content)
mapPiEvent _ _ _ = pure ()

textField :: Text -> KeyMap.KeyMap Value -> Maybe Text
textField name objectValue =
  KeyMap.lookup (Key.fromText name) objectValue >>= valueTextMaybe

valueTextMaybe :: Value -> Maybe Text
valueTextMaybe (String value) = Just value
valueTextMaybe _ = Nothing

integerField :: Text -> KeyMap.KeyMap Value -> Int
integerField name objectValue = maybe 0 valueInt (KeyMap.lookup (Key.fromText name) objectValue)

optionalIntegerField :: Text -> KeyMap.KeyMap Value -> Maybe Int
optionalIntegerField name objectValue = valueInt <$> KeyMap.lookup (Key.fromText name) objectValue

valueInt :: Value -> Int
valueInt (Number value) = round value
valueInt _ = 0

valueText :: Value -> Text
valueText (String value) = value
valueText value =
  TextEncoding.decodeUtf8With
    lenientDecode
    (LazyByteString.toStrict (Aeson.encode value))

textContent :: KeyMap.KeyMap Value -> Text
textContent objectValue =
  case KeyMap.lookup (Key.fromString "content") objectValue of
    Just (String content) -> content
    Just (Array parts) ->
      Text.concat
        [ content
        | Object part <- Vector.toList parts
        , Just content <- [textField "text" part]
        ]
    _ -> ""
