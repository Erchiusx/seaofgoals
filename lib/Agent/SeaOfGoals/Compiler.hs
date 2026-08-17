module Agent.SeaOfGoals.Compiler
  ( CompiledGoal (..)
  , CompiledGoalGraph (..)
  , compileSkill
  , runCompilerFromArgs
  , validateCompiledGoalGraph
  )
where

import Agent.SeaOfGoals.LLM
  ( LLMContentPart (TextPart)
  , LLMInputItem (MessageInput)
  , LLMMessage (..)
  , LLMRequest (..)
  , LLMResponse (..)
  , LLMRole (..)
  , ResponseFormat (JsonObject)
  )
import Agent.SeaOfGoals.LLM qualified as LLM
import Agent.SeaOfGoals.LLM.Backends.GPT
  ( GPTBackend (..)
  , defaultGPTEndpoint
  )
import Agent.SeaOfGoals.PromptTemplate (embedTextFile)
import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , eitherDecode
  , encode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)

data CompiledGoal = CompiledGoal
  { compiledGoalId :: Text
  , compiledGoalName :: Text
  , compiledGoalDescription :: Text
  , compiledGoalPredecessors :: [Text]
  , compiledGoalEnteringPrompt :: Text
  }
  deriving stock (Eq, Show)

instance ToJSON CompiledGoal where
  toJSON goal =
    object
      [ "id" .= compiledGoalId goal
      , "name" .= compiledGoalName goal
      , "description" .= compiledGoalDescription goal
      , "predecessors" .= compiledGoalPredecessors goal
      , "goal_entering_prompt" .= compiledGoalEnteringPrompt goal
      ]

instance FromJSON CompiledGoal where
  parseJSON =
    withObject "CompiledGoal" $ \value ->
      CompiledGoal
        <$> value .: "id"
        <*> value .: "name"
        <*> value .: "description"
        <*> value .: "predecessors"
        <*> value .: "goal_entering_prompt"

data CompiledGoalGraph = CompiledGoalGraph
  { compiledSkill :: Text
  , compiledGoals :: [CompiledGoal]
  }
  deriving stock (Eq, Show)

instance ToJSON CompiledGoalGraph where
  toJSON graph =
    object
      [ "skill" .= compiledSkill graph
      , "goals" .= compiledGoals graph
      ]

instance FromJSON CompiledGoalGraph where
  parseJSON =
    withObject "CompiledGoalGraph" $ \value ->
      CompiledGoalGraph
        <$> value .: "skill"
        <*> value .: "goals"

runCompilerFromArgs :: IO ()
runCompilerFromArgs = do
  args <- getArgs
  case args of
    [skillPath, outputPath] -> runCompiler skillPath outputPath Nothing
    [skillPath, outputPath, skillName] ->
      runCompiler skillPath outputPath (Just (Text.pack skillName))
    _ -> do
      putStrLn
        "Usage: SeaOfGoals-compiler <skill.md> <compiled-goals.json> [skill-name]"
      exitFailure

runCompiler :: FilePath -> FilePath -> Maybe Text -> IO ()
runCompiler skillPath outputPath maybeSkillName = do
  apiKey <- lookupEnv "OPENAI_API_KEY"
  case apiKey of
    Nothing -> do
      putStrLn "OPENAI_API_KEY is not set."
      exitFailure
    Just key -> do
      skillText <- TextIO.readFile skillPath
      model <- Text.pack . fromMaybe "gpt-5.5" <$> lookupEnv "SOG_MODEL"
      let backend =
            GPTBackend
              { gptApiKey = key
              , gptEndpoint = defaultGPTEndpoint
              }
      result <-
        compileSkill backend model (fromMaybe "skill" maybeSkillName) skillText
      case result of
        Left err -> do
          putStrLn ("Could not compile skill: " <> Text.unpack err)
          exitFailure
        Right graph -> do
          createDirectoryIfMissing True (takeDirectory outputPath)
          LazyByteString.writeFile outputPath (encode graph <> "\n")
          putStrLn ("Compiled goals written to " <> outputPath)

compileSkill
  :: LLM.LLM provider
  => provider
  -> Text
  -> Text
  -> Text
  -> IO (Either Text CompiledGoalGraph)
compileSkill provider model skillName skillText = do
  result <-
    LLM.runLLM
      provider
      LLMRequest
        { requestModel = model
        , requestInput =
            [ MessageInput
                LLMMessage
                  { messageRole = System
                  , messageContent = [TextPart compilerSystemPrompt]
                  }
            , MessageInput
                LLMMessage
                  { messageRole = User
                  , messageContent =
                      [ TextPart
                          ( compilerUserPrompt
                              skillName
                              skillText
                          )
                      ]
                  }
            ]
        , requestTemperature =
            if "gpt-5" `Text.isPrefixOf` model
              then Nothing
              else Just 0.1
        , requestMaxTokens = Just 4096
        , requestStopSequences = []
        , requestResponseFormat = JsonObject
        , requestTools = []
        , requestConfig = Nothing
        }
  case result of
    Left err -> pure (Left (Text.pack (show err)))
    Right response ->
      pure (parseCompiledGoalGraph (responseMessage response))

parseCompiledGoalGraph :: LLMMessage -> Either Text CompiledGoalGraph
parseCompiledGoalGraph message = do
  graph <-
    case eitherDecode
      (LazyByteString.fromStrict (TextEncoding.encodeUtf8 (messageText message))) of
      Left err ->
        Left
          ("model response is not a compiled goal graph JSON object: " <> Text.pack err)
      Right value -> Right value
  case validateCompiledGoalGraph graph of
    [] -> Right graph
    errors -> Left (Text.intercalate "; " errors)

validateCompiledGoalGraph :: CompiledGoalGraph -> [Text]
validateCompiledGoalGraph graph =
  duplicateErrors
    <> unknownPredecessorErrors
    <> selfDependencyErrors
    <> cycleErrors
 where
  goals = compiledGoals graph
  ids = fmap compiledGoalId goals
  idSet = Set.fromList ids
  duplicateIds =
    Map.keys
      (Map.filter (> 1) (Map.fromListWith (+) [(goalId, 1 :: Int) | goalId <- ids]))
  duplicateErrors =
    fmap ("duplicate goal id: " <>) duplicateIds
  unknownPredecessorErrors =
    [ "unknown predecessor "
        <> predecessor
        <> " for goal "
        <> compiledGoalId goal
    | goal <- goals
    , predecessor <- compiledGoalPredecessors goal
    , predecessor `Set.notMember` idSet
    ]
  selfDependencyErrors =
    [ "goal depends on itself: " <> compiledGoalId goal
    | goal <- goals
    , compiledGoalId goal `elem` compiledGoalPredecessors goal
    ]
  cycleErrors =
    ["compiled goal graph contains a cycle" | hasCycle graph]

hasCycle :: CompiledGoalGraph -> Bool
hasCycle graph =
  any startsCycle (compiledGoals graph)
 where
  predecessorMap =
    Map.fromList
      [ (compiledGoalId goal, compiledGoalPredecessors goal)
      | goal <- compiledGoals graph
      ]

  startsCycle goal =
    visit Set.empty (compiledGoalId goal) (compiledGoalId goal)

  visit seen start current =
    any
      ( \predecessor ->
          predecessor == start
            || ( predecessor `Set.notMember` seen
                   && visit (Set.insert predecessor seen) start predecessor
               )
      )
      (Map.findWithDefault [] current predecessorMap)

compilerSystemPrompt :: Text
compilerSystemPrompt =
  $(embedTextFile "lib/Agent/SeaOfGoals/Prompts/compiler-system.txt")

compilerUserPrompt :: Text -> Text -> Text
compilerUserPrompt skillName skillText =
  Text.replace "{{skill_text}}" skillText $
    Text.replace
      "{{skill_name}}"
      skillName
      $(embedTextFile "lib/Agent/SeaOfGoals/Prompts/compiler-user.txt")

messageText :: LLMMessage -> Text
messageText message =
  foldMap contentPartText (messageContent message)

contentPartText :: LLMContentPart -> Text
contentPartText (TextPart text) = text
contentPartText _ = ""
