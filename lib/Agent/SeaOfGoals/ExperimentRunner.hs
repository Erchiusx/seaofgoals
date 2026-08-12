module Agent.SeaOfGoals.ExperimentRunner
  ( appendEvent
  , experimentSystemPrompt
  , experimentTools
  , loadWorkflowSpecFromEnv
  , runPrompt
  , runPromptFromArgs
  )
where

import Agent.SeaOfGoals.Harness
  ( HarnessConfig (..)
  , runHarness
  )
import Agent.SeaOfGoals.LLM
  ( LLMContentPart (TextPart)
  , LLMRequest (..)
  , ResponseFormat (PlainText)
  , ToolCall (..)
  , ToolResult (..)
  )
import Agent.SeaOfGoals.LLM.Backends.GPT
  ( GPTBackend (..)
  , defaultGPTEndpoint
  )
import Agent.SeaOfGoals.Tools
  ( ToolSpec
  , objectToolSpec
  )
import Agent.SeaOfGoals.Trace
  ( EffectRecord (..)
  , HarnessEvent (..)
  )
import Agent.SeaOfGoals.Workflow
  ( WorkflowSpec
  , renderWorkflowPrompt
  )
import Data.Aeson
  ( FromJSON (..)
  , Value
  , eitherDecode
  , encode
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import System.Directory
  ( createDirectoryIfMissing
  , getCurrentDirectory
  )
import System.Environment
  ( getArgs
  , lookupEnv
  )
import System.Exit (ExitCode (..))
import System.FilePath
  ( addTrailingPathSeparator
  , isAbsolute
  , normalise
  , takeDirectory
  , (</>)
  )
import System.Process
  ( readCreateProcessWithExitCode
  , shell
  )

runPromptFromArgs :: IO ()
runPromptFromArgs = do
  apiKey <- lookupEnv "OPENAI_API_KEY"
  case apiKey of
    Nothing ->
      putStrLn "OPENAI_API_KEY is not set."
    Just key -> do
      args <- getArgs
      let prompt = Text.pack (unwords args)
      if Text.null prompt
        then putStrLn "Usage: SeaOfGoals-agent-runner <prompt>"
        else runPrompt key prompt

runPrompt :: String -> Text -> IO ()
runPrompt apiKey prompt = do
  tracePath <- fromMaybe "sog-trace.jsonl" <$> lookupEnv "SOG_TRACE_PATH"
  model <- Text.pack . fromMaybe "gpt-5.5" <$> lookupEnv "SOG_MODEL"
  workflowSpec <- loadWorkflowSpecFromEnv
  createDirectoryIfMissing True (takeDirectory tracePath)
  let
    backend =
      GPTBackend
        { gptApiKey = apiKey
        , gptEndpoint = defaultGPTEndpoint
        }
    requestTemplate =
      LLMRequest
        { requestModel = model
        , requestInput = []
        , requestTemperature =
            if "gpt-5" `Text.isPrefixOf` model
              then Nothing
              else Just 0.2
        , requestMaxTokens = Just 1024
        , requestStopSequences = []
        , requestResponseFormat = PlainText
        , requestTools = []
        , requestConfig = Nothing
        }
    workflowPrompt = maybe "" renderWorkflowPrompt workflowSpec
  _ <-
    runHarness
      HarnessConfig
        { harnessProvider = backend
        , harnessRequestTemplate = requestTemplate
        , harnessSystemPrompt =
            Text.intercalate
              "\n\n"
              (filter (not . Text.null) [experimentSystemPrompt, workflowPrompt])
        , harnessUserPrompt = prompt
        , harnessTools = experimentTools
        , harnessMaxTurns = 64
        , harnessEventSink = appendEvent tracePath
        , harnessWorkflowSpec = workflowSpec
        }
  putStrLn ("Trace written to " <> tracePath)

loadWorkflowSpecFromEnv :: IO (Maybe WorkflowSpec)
loadWorkflowSpecFromEnv = do
  maybePath <- lookupEnv "SOG_WORKFLOW_SPEC"
  case maybePath of
    Nothing -> pure Nothing
    Just path -> do
      decoded <- eitherDecode <$> LazyByteString.readFile path
      case decoded of
        Left err -> fail ("could not parse SOG_WORKFLOW_SPEC: " <> err)
        Right spec -> pure (Just spec)

experimentSystemPrompt :: Text
experimentSystemPrompt =
  Text.unlines
    [ "You are running inside the SeaOfGoals agent harness."
    , "Before starting any meaningful task step, call begin_subgoal."
    , "Do not run shell commands or record effects before begin_subgoal."
    , "When the step is complete, call end_subgoal."
    , "Use shell commands such as cat, sed, find, and rg to read or inspect files."
    , "Use shell commands to actually inspect and modify local files."
    , "Prefer write_file over shell commands for file edits."
    , "Never use write_file to read files or to modify /skill, /seed, or mounted instruction files."
    , "record_effect only records observed side effects; it does not modify anything."
    , "Call record_effect after confirming a file, database, or artifact was actually changed."
    , "Use shell for local commands only."
    ]

experimentTools :: [ToolSpec]
experimentTools =
  [ beginSubgoalTool
  , endSubgoalTool
  , recordEffectTool
  , writeFileTool
  , shellTool
  ]

beginSubgoalTool :: ToolSpec
beginSubgoalTool =
  objectToolSpec
    "begin_subgoal"
    "Mark the beginning of a concrete subgoal before doing work."
    [ ("id", textSchema "Stable subgoal id, such as an SCFG node id N001")
    , ("name", textSchema "Short human-readable subgoal name")
    ]
    ["id", "name"]
    $ \toolCall -> do
      case parseArgs toolCall of
        Left err -> pure (textResult toolCall err, [])
        Right args ->
          pure
            ( textResult toolCall "subgoal started"
            ,
              [ SubgoalStarted
                  { eventSubgoalId = beginId args
                  , eventSubgoalName = beginName args
                  }
              ]
            )

endSubgoalTool :: ToolSpec
endSubgoalTool =
  objectToolSpec
    "end_subgoal"
    "Mark the end of the current subgoal."
    [ ("id", textSchema "Subgoal id being ended")
    , ("status", textSchema "success, failed, skipped, or blocked")
    , ("summary", textSchema "Short result summary")
    ]
    ["id", "status"]
    $ \toolCall -> do
      case parseArgs toolCall of
        Left err -> pure (textResult toolCall err, [])
        Right args ->
          pure
            ( textResult toolCall "subgoal ended"
            ,
              [ SubgoalEnded
                  { eventSubgoalId = endId args
                  , eventStatus = endStatus args
                  , eventSummary = endSummary args
                  }
              ]
            )

recordEffectTool :: ToolSpec
recordEffectTool =
  objectToolSpec
    "record_effect"
    "Record a side effect observed by the agent."
    [
      ( "kind"
      , textSchema "read, write, delete, spawn, network, db, docker, or artifact"
      )
    , ("resource", textSchema "Resource identifier affected by this step")
    , ("detail", textSchema "Optional short detail")
    ]
    ["kind", "resource"]
    $ \toolCall -> do
      case parseArgs toolCall of
        Left err -> pure (textResult toolCall err, [])
        Right args ->
          pure
            ( textResult toolCall "effect recorded"
            ,
              [ EffectRecorded
                  { eventEffect =
                      EffectRecord
                        { effectKind = effectKindArg args
                        , effectResource = effectResourceArg args
                        , effectDetail = effectDetailArg args
                        }
                  , eventActiveSubgoal = Nothing
                  }
              ]
            )

writeFileTool :: ToolSpec
writeFileTool =
  objectToolSpec
    "write_file"
    "Write complete UTF-8 text content to a local file."
    [ ("path", textSchema "Path to write, such as /workspace/application.yml")
    , ("content", textSchema "Complete file content to write")
    ]
    ["path", "content"]
    $ \toolCall -> do
      case parseArgs toolCall of
        Left err -> pure (textResult toolCall err, [])
        Right args -> do
          resolved <- resolveWorkspaceWritePath (writePath args)
          case resolved of
            Left err -> pure (textResult toolCall err, [])
            Right path -> do
              createDirectoryIfMissing True (takeDirectory path)
              TextIO.writeFile path (writeContent args)
              pure
                ( textResult toolCall "file written"
                ,
                  [ EffectRecorded
                      { eventEffect =
                          EffectRecord
                            { effectKind = "write"
                            , effectResource = Text.pack path
                            , effectDetail = Just "write_file"
                            }
                      , eventActiveSubgoal = Nothing
                      }
                  ]
                )

resolveWorkspaceWritePath :: Text -> IO (Either Text FilePath)
resolveWorkspaceWritePath requestedPath = do
  currentDirectory <- normalise <$> getCurrentDirectory
  let
    rawPath = Text.unpack requestedPath
    absolutePath =
      normalise $
        if isAbsolute rawPath
          then rawPath
          else currentDirectory </> rawPath
    currentPrefix = addTrailingPathSeparator currentDirectory
  pure $
    if absolutePath == currentDirectory || currentPrefix `isPrefixOf` absolutePath
      then Right absolutePath
      else
        Left
          ( "write_file path must stay under "
              <> Text.pack currentDirectory
              <> ": "
              <> requestedPath
          )

shellTool :: ToolSpec
shellTool =
  objectToolSpec
    "shell"
    "Run a local shell command and return stdout, stderr, and exit code."
    [ ("command", textSchema "Shell command to run")
    ]
    ["command"]
    $ \toolCall -> do
      case parseArgs toolCall of
        Left err -> pure (textResult toolCall err, [])
        Right args -> do
          (exitCode, stdoutText, stderrText) <-
            readCreateProcessWithExitCode (shell (Text.unpack (shellCommand args))) ""
          let resultText =
                Text.unlines
                  [ "exit_code: " <> exitCodeText exitCode
                  , "stdout:"
                  , Text.pack stdoutText
                  , "stderr:"
                  , Text.pack stderrText
                  ]
          pure (textResult toolCall resultText, [])

appendEvent :: FilePath -> HarnessEvent -> IO ()
appendEvent path event = do
  timestamp <- getCurrentTime
  LazyByteString.appendFile
    path
    ( encode
        ( object
            [ "timestamp" .= iso8601Show timestamp
            , "event" .= event
            ]
        )
        <> "\n"
    )

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

parseArgs :: FromJSON value => ToolCall -> Either Text value
parseArgs toolCall =
  case eitherDecode (encode (toolCallArguments toolCall)) of
    Left err -> Left ("invalid tool arguments: " <> Text.pack err)
    Right value -> Right value

data BeginSubgoalArgs = BeginSubgoalArgs
  { beginId :: Text
  , beginName :: Text
  }

instance FromJSON BeginSubgoalArgs where
  parseJSON =
    withObject "BeginSubgoalArgs" $ \value ->
      BeginSubgoalArgs
        <$> value .: "id"
        <*> value .: "name"

data EndSubgoalArgs = EndSubgoalArgs
  { endId :: Text
  , endStatus :: Text
  , endSummary :: Maybe Text
  }

instance FromJSON EndSubgoalArgs where
  parseJSON =
    withObject "EndSubgoalArgs" $ \value ->
      EndSubgoalArgs
        <$> value .: "id"
        <*> value .: "status"
        <*> value .:? "summary"

data EffectArgs = EffectArgs
  { effectKindArg :: Text
  , effectResourceArg :: Text
  , effectDetailArg :: Maybe Text
  }

instance FromJSON EffectArgs where
  parseJSON =
    withObject "EffectArgs" $ \value ->
      EffectArgs
        <$> value .: "kind"
        <*> value .: "resource"
        <*> value .:? "detail"

data WriteFileArgs = WriteFileArgs
  { writePath :: Text
  , writeContent :: Text
  }

instance FromJSON WriteFileArgs where
  parseJSON =
    withObject "WriteFileArgs" $ \value ->
      WriteFileArgs
        <$> value .: "path"
        <*> value .: "content"

newtype ShellArgs = ShellArgs
  { shellCommand :: Text
  }

instance FromJSON ShellArgs where
  parseJSON =
    withObject "ShellArgs" $ \value ->
      ShellArgs <$> value .: "command"

exitCodeText :: ExitCode -> Text
exitCodeText ExitSuccess = "0"
exitCodeText (ExitFailure code) = Text.pack (show code)
