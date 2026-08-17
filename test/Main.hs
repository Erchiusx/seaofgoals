module Main (main) where

import Agent.LLM.Transport
  ( TransportResponse (..)
  )
import Agent.SeaOfGoals.Compiler
  ( CompiledGoal (..)
  , CompiledGoalGraph (..)
  , validateCompiledGoalGraph
  )
import Agent.SeaOfGoals.Harness
  ( HarnessConfig (..)
  , HarnessState (..)
  , runHarness
  )
import Agent.SeaOfGoals.LLM
  ( LLM (..)
  , LLMContentPart (TextPart)
  , LLMError (LLMProviderError)
  , LLMMessage (..)
  , LLMRequest (..)
  , LLMResponse (..)
  , LLMRole (..)
  , ResponseFormat (PlainText)
  , ToolCall (..)
  , ToolResult (..)
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
  ( WorkflowNode (..)
  , WorkflowSpec (..)
  , workflowCompletedNodes
  , workflowLastNode
  , workflowTransitionWarnings
  )
import Data.Aeson
  ( FromJSON (..)
  , Value
  , eitherDecode
  , encode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import System.Exit (exitFailure)

main :: IO ()
main = do
  unicodeTransportResponseBodyTest
  compilerGraphValidationTest
  eventsRef <- newIORef []
  provider <- newFakeProvider fakeResponses
  finalState <-
    runHarness
      HarnessConfig
        { harnessProvider = provider
        , harnessRequestTemplate = requestTemplate
        , harnessSystemPrompt = "Use tools."
        , harnessUserPrompt = "Run a tiny tool-call loop."
        , harnessTools = testTools
        , harnessMaxTurns = 8
        , harnessEventSink = \event -> modifyIORef' eventsRef (event :)
        , harnessWorkflowSpec = Just testWorkflow
        }
  events <- reverse <$> readIORef eventsRef
  assertEqual
    "active subgoal is cleared"
    Nothing
    (harnessActiveSubgoal finalState)
  assertEqual
    "workflow completed node"
    (Set.singleton "S1")
    (workflowCompletedNodes (harnessWorkflowStatus finalState))
  assertEqual
    "workflow last node"
    (Just "S1")
    (workflowLastNode (harnessWorkflowStatus finalState))
  assertEqual
    "workflow warning for undeclared transition"
    []
    (workflowTransitionWarnings (harnessWorkflowStatus finalState))
  assertBool "subgoal started" (any isSubgoalStarted events)
  assertBool "subgoal name is canonicalized" (any isCanonicalSubgoalName events)
  assertBool "effect was assigned to active subgoal" (any isEffectForS1 events)
  assertBool "workflow status was observed" (any isWorkflowStatusForS1 events)
  assertBool "shell tool was called" (any (isToolCall "shell") events)
  assertBool "shell output was observed" (any isShellResult events)
  assertBool "subgoal ended" (any isSubgoalEnded events)
  assertBool "harness finished" (any isHarnessFinished events)
  putStrLn "Harness tool-call loop test passed."

unicodeTransportResponseBodyTest :: IO ()
unicodeTransportResponseBodyTest = do
  let
    payload = object ["name" .= ("迁移安全检查清单" :: Text)]
    response =
      TransportResponse
        { transportStatus = 200
        , transportResponseHeaders = []
        , transportResponseBody = encode payload
        , transportResponseJSON = Just payload
        }
  assertEqual
    "transport response body keeps UTF-8 JSON bytes"
    (Right payload)
    (eitherDecode (transportResponseBody response) :: Either String Value)

compilerGraphValidationTest :: IO ()
compilerGraphValidationTest = do
  assertEqual
    "valid compiler DAG"
    []
    (validateCompiledGoalGraph validCompilerGraph)
  assertBool
    "compiler DAG rejects unknown predecessor"
    (not (null (validateCompiledGoalGraph unknownPredecessorCompilerGraph)))
  assertBool
    "compiler DAG rejects cycle"
    (not (null (validateCompiledGoalGraph cyclicCompilerGraph)))

requestTemplate :: LLMRequest
requestTemplate =
  LLMRequest
    { requestModel = "fake-model"
    , requestInput = []
    , requestTemperature = Nothing
    , requestMaxTokens = Nothing
    , requestStopSequences = []
    , requestResponseFormat = PlainText
    , requestTools = []
    , requestConfig = Nothing
    }

testTools :: [ToolSpec]
testTools =
  [ beginSubgoalTool
  , recordEffectTool
  , shellTool
  , endSubgoalTool
  ]

testWorkflow :: WorkflowSpec
testWorkflow =
  WorkflowSpec
    { workflowName = "test workflow"
    , workflowNodes =
        [ WorkflowNode
            { workflowNodeId = "S1"
            , workflowNodeTitle = "tiny step"
            , workflowNodeBody = ""
            }
        ]
    , workflowEdges = []
    }

validCompilerGraph :: CompiledGoalGraph
validCompilerGraph =
  CompiledGoalGraph
    { compiledSkill = "test"
    , compiledGoals =
        [ compilerGoal "G001" []
        , compilerGoal "G002" ["G001"]
        ]
    }

unknownPredecessorCompilerGraph :: CompiledGoalGraph
unknownPredecessorCompilerGraph =
  CompiledGoalGraph
    { compiledSkill = "test"
    , compiledGoals = [compilerGoal "G001" ["missing"]]
    }

cyclicCompilerGraph :: CompiledGoalGraph
cyclicCompilerGraph =
  CompiledGoalGraph
    { compiledSkill = "test"
    , compiledGoals =
        [ compilerGoal "G001" ["G002"]
        , compilerGoal "G002" ["G001"]
        ]
    }

compilerGoal :: Text -> [Text] -> CompiledGoal
compilerGoal goalId predecessors =
  CompiledGoal
    { compiledGoalId = goalId
    , compiledGoalName = "goal"
    , compiledGoalDescription = "description"
    , compiledGoalPredecessors = predecessors
    , compiledGoalEnteringPrompt = "enter"
    }

beginSubgoalTool :: ToolSpec
beginSubgoalTool =
  objectToolSpec
    "begin_subgoal"
    "Start a subgoal."
    [ ("id", textSchema)
    , ("name", textSchema)
    ]
    ["id", "name"]
    $ \toolCall ->
      case parseArgs toolCall of
        Left err -> pure (toolResult toolCall err, [])
        Right args ->
          pure
            ( toolResult toolCall "started"
            ,
              [ SubgoalStarted
                  { eventSubgoalId = beginId args
                  , eventSubgoalName = beginName args
                  }
              ]
            )

recordEffectTool :: ToolSpec
recordEffectTool =
  objectToolSpec
    "record_effect"
    "Record an effect."
    [ ("kind", textSchema)
    , ("resource", textSchema)
    ]
    ["kind", "resource"]
    $ \toolCall ->
      case parseArgs toolCall of
        Left err -> pure (toolResult toolCall err, [])
        Right args ->
          pure
            ( toolResult toolCall "effect recorded"
            ,
              [ EffectRecorded
                  { eventEffect =
                      EffectRecord
                        { effectKind = effectKindArg args
                        , effectResource = effectResourceArg args
                        , effectDetail = Nothing
                        }
                  , eventActiveSubgoal = Nothing
                  }
              ]
            )

shellTool :: ToolSpec
shellTool =
  objectToolSpec
    "shell"
    "Fake shell."
    [ ("command", textSchema)
    ]
    ["command"]
    $ \toolCall ->
      case parseArgs toolCall of
        Left err -> pure (toolResult toolCall err, [])
        Right args ->
          pure (toolResult toolCall ("fake shell ran: " <> shellCommand args), [])

endSubgoalTool :: ToolSpec
endSubgoalTool =
  objectToolSpec
    "end_subgoal"
    "End a subgoal."
    [ ("id", textSchema)
    , ("status", textSchema)
    ]
    ["id", "status"]
    $ \toolCall ->
      case parseArgs toolCall of
        Left err -> pure (toolResult toolCall err, [])
        Right args ->
          pure
            ( toolResult toolCall "ended"
            ,
              [ SubgoalEnded
                  { eventSubgoalId = endId args
                  , eventStatus = endStatus args
                  , eventSummary = Nothing
                  }
              ]
            )

fakeResponses :: [LLMResponse]
fakeResponses =
  [ responseWithToolCall $
      ToolCall
        { toolCallId = "call-begin"
        , toolCallName = "begin_subgoal"
        , toolCallArguments =
            object ["id" .= ("S1" :: Text), "name" .= ("mojibake step" :: Text)]
        }
  , responseWithToolCall $
      ToolCall
        { toolCallId = "call-effect"
        , toolCallName = "record_effect"
        , toolCallArguments =
            object
              [ "kind" .= ("write" :: Text)
              , "resource" .= ("fixture/output.txt" :: Text)
              ]
        }
  , responseWithToolCall $
      ToolCall
        { toolCallId = "call-shell"
        , toolCallName = "shell"
        , toolCallArguments = object ["command" .= ("pwd" :: Text)]
        }
  , responseWithToolCall $
      ToolCall
        { toolCallId = "call-end"
        , toolCallName = "end_subgoal"
        , toolCallArguments =
            object ["id" .= ("S1" :: Text), "status" .= ("success" :: Text)]
        }
  , LLMResponse
      { responseModel = "fake-model"
      , responseMessage = assistantMessage "done"
      , responseToolCalls = []
      , responseOutput = []
      , responseUsage = Nothing
      , responseFinishReason = Just "stop"
      }
  ]

responseWithToolCall :: ToolCall -> LLMResponse
responseWithToolCall toolCall =
  LLMResponse
    { responseModel = "fake-model"
    , responseMessage = assistantMessage ""
    , responseToolCalls = [toolCall]
    , responseOutput = []
    , responseUsage = Nothing
    , responseFinishReason = Just "tool_calls"
    }

assistantMessage :: Text -> LLMMessage
assistantMessage text =
  LLMMessage
    { messageRole = Assistant
    , messageContent = [TextPart text]
    }

newtype FakeProvider = FakeProvider (IORef [LLMResponse])

newFakeProvider :: [LLMResponse] -> IO FakeProvider
newFakeProvider responses = FakeProvider <$> newIORef responses

instance LLM FakeProvider where
  runLLM (FakeProvider responsesRef) _request = do
    responses <- readIORef responsesRef
    case responses of
      [] -> pure (Left (LLMProviderError "fake provider exhausted"))
      response : rest -> do
        modifyIORef' responsesRef (const rest)
        pure (Right response)

data BeginArgs = BeginArgs
  { beginId :: Text
  , beginName :: Text
  }

instance FromJSON BeginArgs where
  parseJSON =
    withObject "BeginArgs" $ \value ->
      BeginArgs <$> value .: "id" <*> value .: "name"

newtype ShellArgs = ShellArgs
  { shellCommand :: Text
  }

instance FromJSON ShellArgs where
  parseJSON =
    withObject "ShellArgs" $ \value ->
      ShellArgs <$> value .: "command"

data EffectArgs = EffectArgs
  { effectKindArg :: Text
  , effectResourceArg :: Text
  }

instance FromJSON EffectArgs where
  parseJSON =
    withObject "EffectArgs" $ \value ->
      EffectArgs <$> value .: "kind" <*> value .: "resource"

data EndArgs = EndArgs
  { endId :: Text
  , endStatus :: Text
  }

instance FromJSON EndArgs where
  parseJSON =
    withObject "EndArgs" $ \value ->
      EndArgs <$> value .: "id" <*> value .: "status"

parseArgs :: FromJSON value => ToolCall -> Either Text value
parseArgs toolCall =
  case eitherDecode (encode (toolCallArguments toolCall)) of
    Left err -> Left (Text.pack err)
    Right value -> Right value

toolResult :: ToolCall -> Text -> ToolResult
toolResult toolCall content =
  ToolResult
    { toolResultCallId = toolCallId toolCall
    , toolResultName = Just (toolCallName toolCall)
    , toolResultContent = [TextPart content]
    }

textSchema :: Value
textSchema = object ["type" .= ("string" :: Text)]

isSubgoalStarted :: HarnessEvent -> Bool
isSubgoalStarted SubgoalStarted{eventSubgoalId = "S1"} = True
isSubgoalStarted _ = False

isCanonicalSubgoalName :: HarnessEvent -> Bool
isCanonicalSubgoalName SubgoalStarted{eventSubgoalId = "S1", eventSubgoalName = "tiny step"} = True
isCanonicalSubgoalName _ = False

isSubgoalEnded :: HarnessEvent -> Bool
isSubgoalEnded SubgoalEnded{eventSubgoalId = "S1", eventStatus = "success"} = True
isSubgoalEnded _ = False

isToolCall :: Text -> HarnessEvent -> Bool
isToolCall name ToolCallObserved{eventToolName = observedName} = name == observedName
isToolCall _ _ = False

isEffectForS1 :: HarnessEvent -> Bool
isEffectForS1
  EffectRecorded
    { eventEffect =
      EffectRecord
        { effectKind = "write"
        , effectResource = "fixture/output.txt"
        }
    , eventActiveSubgoal = Just "S1"
    } = True
isEffectForS1 _ = False

isWorkflowStatusForS1 :: HarnessEvent -> Bool
isWorkflowStatusForS1
  WorkflowStatusObserved
    { eventCompletedNodes = completed
    , eventLastNode = Just "S1"
    } = Set.member "S1" completed
isWorkflowStatusForS1 _ = False

isShellResult :: HarnessEvent -> Bool
isShellResult ToolResultObserved{eventToolName = "shell", eventResult = result} =
  "fake shell ran: pwd" `Text.isInfixOf` result
isShellResult _ = False

isHarnessFinished :: HarnessEvent -> Bool
isHarnessFinished HarnessFinished{} = True
isHarnessFinished _ = False

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  assertBool
    (label <> ": expected " <> show expected <> ", got " <> show actual)
    (expected == actual)

assertBool :: String -> Bool -> IO ()
assertBool _ True = pure ()
assertBool label False = do
  putStrLn ("Assertion failed: " <> label)
  exitFailure
