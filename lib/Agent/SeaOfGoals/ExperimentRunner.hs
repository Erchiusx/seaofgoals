module Agent.SeaOfGoals.ExperimentRunner
  ( appendEvent
  , experimentSystemPrompt
  , experimentTools
  , loadWorkflowSpecFromEnv
  , runPrompt
  , runPromptFromArgs
  )
where

import Agent.SeaOfGoals.Compile.Compiler
  ( CompiledGoalGraph (..)
  , validateCompiledGoalGraph
  )
import Agent.SeaOfGoals.Compile.PromptTemplate (embedTextFile)
import Agent.SeaOfGoals.Harness
  ( HarnessConfig (..)
  , HarnessState (..)
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
import Agent.SeaOfGoals.Scheduling.Agentic
  ( AgentRunResult (..)
  , GoalGraph (..)
  , GoalNode (..)
  , GoalNodeId (..)
  , SnapshotId (..)
  )
import Agent.SeaOfGoals.Scheduling.Compiled
  ( compiledGraphToGoalGraph
  )
import Agent.SeaOfGoals.Scheduling.SerialScheduler
  ( SerialScheduler (..)
  , SerialSchedulerResult (..)
  , goalPredecessors
  , runSerialScheduler
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
  , workflowCompletedNodes
  , workflowFailedNodes
  , workflowSkippedNodes
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
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
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
  , unsetEnv
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

data ExperimentContext = ExperimentContext
  { experimentBackend :: GPTBackend
  , experimentRequestTemplate :: LLMRequest
  , experimentTracePath :: FilePath
  , experimentSystemPromptText :: Text
  , experimentUserPromptText :: Text
  , experimentWorkflowSpec :: Maybe WorkflowSpec
  }

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
  context <- loadExperimentContext apiKey prompt
  maybeSerialGoalsText <- lookupEnv "SOG_SERIAL_GOALS_TEXT"
  maybeSerialGoals <- lookupEnv "SOG_SERIAL_GOALS"
  case maybeSerialGoalsText of
    Just goalsText | not (null goalsText) -> do
      unsetEnv "SOG_SERIAL_GOALS_TEXT"
      compiledGraph <- parseCompiledGoalGraphText goalsText
      runSerialPromptWithGraph context compiledGraph
    _ ->
      case maybeSerialGoals of
        Just path | not (null path) -> do
          unsetEnv "SOG_SERIAL_GOALS"
          loadCompiledGoalGraph path >>= runSerialPromptWithGraph context
        _ -> runSinglePrompt context

loadExperimentContext :: String -> Text -> IO ExperimentContext
loadExperimentContext apiKey prompt = do
  tracePath <- fromMaybe "sog-trace.jsonl" <$> lookupEnv "SOG_TRACE_PATH"
  model <- Text.pack . fromMaybe "gpt-5.5" <$> lookupEnv "SOG_MODEL"
  workflowSpec <- loadWorkflowSpecFromEnv
  skillContext <- loadSkillContextFromEnv
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
        , requestMaxTokens = Nothing
        , requestStopSequences = []
        , requestResponseFormat = PlainText
        , requestTools = []
        , requestConfig = Nothing
        }
    workflowPrompt = maybe "" renderWorkflowPrompt workflowSpec
    systemPrompt =
      Text.intercalate
        "\n\n"
        (filter (not . Text.null) [experimentSystemPrompt, skillContext, workflowPrompt])
  pure
    ExperimentContext
      { experimentBackend = backend
      , experimentRequestTemplate = requestTemplate
      , experimentTracePath = tracePath
      , experimentSystemPromptText = systemPrompt
      , experimentUserPromptText = prompt
      , experimentWorkflowSpec = workflowSpec
      }

runSinglePrompt :: ExperimentContext -> IO ()
runSinglePrompt context = do
  _ <-
    runHarness
      HarnessConfig
        { harnessProvider = experimentBackend context
        , harnessRequestTemplate = experimentRequestTemplate context
        , harnessSystemPrompt = experimentSystemPromptText context
        , harnessUserPrompt = experimentUserPromptText context
        , harnessTools = experimentTools
        , harnessMaxTurns = 64
        , harnessEventSink = appendEvent (experimentTracePath context)
        , harnessWorkflowSpec = experimentWorkflowSpec context
        }
  putStrLn ("Trace written to " <> experimentTracePath context)

runSerialPromptWithGraph :: ExperimentContext -> CompiledGoalGraph -> IO ()
runSerialPromptWithGraph context compiledGraph = do
  let goalGraph = compiledGraphToGoalGraph compiledGraph
  summariesRef <- newSummaries
  result <-
    runSerialScheduler
      SerialScheduler
        { serialSchedulerRunGoal =
            runSerialGoal context goalGraph summariesRef
        }
      goalGraph
  case result of
    Left err -> fail ("serial scheduler failed: " <> Text.unpack err)
    Right schedulerResult -> do
      putStrLn
        ( "Serial goals completed: "
            <> show
              ( fmap
                  (Text.unpack . unGoalNodeId)
                  (serialSchedulerRunOrder schedulerResult)
              )
        )
      putStrLn ("Trace written to " <> experimentTracePath context)

loadCompiledGoalGraph :: FilePath -> IO CompiledGoalGraph
loadCompiledGoalGraph path = do
  decoded <- eitherDecode <$> LazyByteString.readFile path
  case decoded of
    Left err -> fail ("could not parse SOG_SERIAL_GOALS: " <> err)
    Right graph -> validateLoadedCompiledGoalGraph "SOG_SERIAL_GOALS" graph

parseCompiledGoalGraphText :: String -> IO CompiledGoalGraph
parseCompiledGoalGraphText text =
  case eitherDecode
    (LazyByteString.fromStrict (TextEncoding.encodeUtf8 (Text.pack text))) of
    Left err -> fail ("could not parse SOG_SERIAL_GOALS_TEXT: " <> err)
    Right graph -> validateLoadedCompiledGoalGraph "SOG_SERIAL_GOALS_TEXT" graph

validateLoadedCompiledGoalGraph
  :: String -> CompiledGoalGraph -> IO CompiledGoalGraph
validateLoadedCompiledGoalGraph source graph =
  case validateLoadedCompiledGoalGraphPure graph of
    [] -> pure graph
    errors ->
      fail
        ( "invalid "
            <> source
            <> ": "
            <> Text.unpack (Text.intercalate "; " errors)
        )

validateLoadedCompiledGoalGraphPure :: CompiledGoalGraph -> [Text]
validateLoadedCompiledGoalGraphPure = validateCompiledGoalGraph

runSerialGoal
  :: ExperimentContext
  -> GoalGraph
  -> Summaries
  -> GoalNode
  -> IO (Either Text AgentRunResult)
runSerialGoal context goalGraph summaries node = do
  predecessorSummaries <-
    summariesFor summaries (goalPredecessors goalGraph (goalNodeId node))
  let prompt =
        serialGoalPrompt
          (experimentUserPromptText context)
          predecessorSummaries
          node
  state <-
    runHarness
      HarnessConfig
        { harnessProvider = experimentBackend context
        , harnessRequestTemplate = experimentRequestTemplate context
        , harnessSystemPrompt = experimentSystemPromptText context
        , harnessUserPrompt = prompt
        , harnessTools = experimentTools
        , harnessMaxTurns = 32
        , harnessEventSink = appendEvent (experimentTracePath context)
        , harnessWorkflowSpec = experimentWorkflowSpec context
        }
  let
    status = serialGoalStatus node state
    summary = serialGoalSummary node status
    result =
      AgentRunResult
        { agentRunResultGoal = goalNodeId node
        , agentRunResultStatus = status
        , agentRunResultSummaryForDependents = summary
        , agentRunResultReads = Set.empty
        , agentRunResultWrites = Set.empty
        , agentRunResultSnapshot = SnapshotId (unGoalNodeId (goalNodeId node))
        }
  if serialGoalStatusIsTerminal status
    then do
      rememberSummary summaries (goalNodeId node) summary
      pure (Right result)
    else
      pure
        ( Left
            ( "serial goal "
                <> unGoalNodeId (goalNodeId node)
                <> " did not complete successfully: "
                <> status
            )
        )

serialGoalPrompt :: Text -> [(GoalNodeId, Text)] -> GoalNode -> Text
serialGoalPrompt originalPrompt predecessorSummaries node =
  Text.intercalate
    "\n\n"
    ( filter
        (not . Text.null)
        [ "Original task:\n" <> originalPrompt
        , renderedSummaries
        , Text.unlines
            [ "Execute exactly this compiled goal now."
            , "Goal id: " <> unGoalNodeId (goalNodeId node)
            , "Goal name: " <> goalNodeName node
            , ""
            , goalNodePrompt node
            , ""
            , "Use the current workspace and process environment as the source of truth."
            , "If a dependency service is already available through an environment variable, use that value instead of recreating the service or assuming host ports from the original skill text."
            , "Do not call docker unless this goal explicitly requires Docker and the docker command is available."
            , "Do not read harness trajectory files such as sog-trace.jsonl; they are private experiment records, not task inputs."
            , ""
            , "Before doing work, call begin_subgoal with this exact goal id."
            , "When this goal is complete, call end_subgoal with this exact goal id and a concise summary."
            , "Do not start a different goal in this agent loop."
            ]
        ]
    )
 where
  renderedSummaries
    | null predecessorSummaries = ""
    | otherwise =
        Text.unlines
          ( "Completed predecessor summaries:"
              : fmap renderSummary predecessorSummaries
          )
  renderSummary (goalId, summary) =
    "- " <> unGoalNodeId goalId <> ": " <> summary

serialGoalStatus :: GoalNode -> HarnessState -> Text
serialGoalStatus node state
  | unGoalNodeId (goalNodeId node)
      `Set.member` workflowCompletedNodes (harnessWorkflowStatus state) =
      "success"
  | unGoalNodeId (goalNodeId node)
      `Set.member` workflowSkippedNodes (harnessWorkflowStatus state) =
      "skipped"
  | unGoalNodeId (goalNodeId node)
      `Set.member` workflowFailedNodes (harnessWorkflowStatus state) =
      "failed"
  | otherwise = "finished_without_success_status"

serialGoalStatusIsTerminal :: Text -> Bool
serialGoalStatusIsTerminal status =
  status == "success" || status == "skipped"

serialGoalSummary :: GoalNode -> Text -> Text
serialGoalSummary node status =
  goalNodeName node <> " finished with status " <> status

type Summaries = IORef (Map GoalNodeId Text)

newSummaries :: IO Summaries
newSummaries = newIORef Map.empty

rememberSummary :: Summaries -> GoalNodeId -> Text -> IO ()
rememberSummary summaries goalId summary =
  modifyIORef' summaries (Map.insert goalId summary)

summariesFor :: Summaries -> Set GoalNodeId -> IO [(GoalNodeId, Text)]
summariesFor summaries goalIds = do
  summaryMap <- readIORef summaries
  pure
    [ (goalId, summary)
    | goalId <- Set.toList goalIds
    , Just summary <- [Map.lookup goalId summaryMap]
    ]

loadWorkflowSpecFromEnv :: IO (Maybe WorkflowSpec)
loadWorkflowSpecFromEnv = do
  maybePath <- lookupEnv "SOG_WORKFLOW_SPEC"
  case maybePath of
    Nothing -> pure Nothing
    Just "" -> pure Nothing
    Just path -> do
      decoded <- eitherDecode <$> LazyByteString.readFile path
      case decoded of
        Left err -> fail ("could not parse SOG_WORKFLOW_SPEC: " <> err)
        Right spec -> pure (Just spec)

loadSkillContextFromEnv :: IO Text
loadSkillContextFromEnv = do
  maybeText <- lookupEnv "SOG_SKILL_TEXT"
  maybePath <- lookupEnv "SOG_SKILL_PATH"
  skillText <-
    case (maybeText, maybePath) of
      (Just text, _) | not (null text) -> pure (Text.pack text)
      (_, Just path) | not (null path) -> TextIO.readFile path
      _ -> pure ""
  pure
    ( if Text.null skillText
        then ""
        else
          Text.replace
            "{{skill_text}}"
            skillText
            $(embedTextFile "lib/Agent/SeaOfGoals/Prompts/skill-context.txt")
    )

experimentSystemPrompt :: Text
experimentSystemPrompt =
  $(embedTextFile "lib/Agent/SeaOfGoals/Prompts/experiment-system.txt")

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
