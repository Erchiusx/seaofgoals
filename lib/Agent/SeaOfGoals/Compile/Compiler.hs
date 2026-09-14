module Agent.SeaOfGoals.Compile.Compiler
  ( CompiledGoal (..)
  , CompiledGoalGraph (..)
  , CompilerStrategy (..)
  , compileSkill
  , compilerCodexPromptForStrategy
  , compilerCodexPrompt
  , compilerCodexPromptWithPreloadPlanner
  , parseCompiledGoalGraphText
  , runCompilerFromArgs
  , validateCompiledGoalGraph
  )
where

import Agent.SeaOfGoals.CodexProcess
  ( CodexProcessResult (..)
  , loadCodexProcessConfigFromEnv
  , runCodexProcess
  )
import Agent.SeaOfGoals.Compile.PromptTemplate (embedTextFile)
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
  , loadGPTEndpointFromEnv
  )
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
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Process (getProcessID)

data CompiledGoal = CompiledGoal
  { compiledGoalId :: Text
  , compiledGoalName :: Text
  , compiledGoalDescription :: Text
  , compiledGoalPredecessors :: [Text]
  , compiledGoalEnteringPrompt :: Text
  }
  deriving stock (Eq, Show)

data CompilerStrategy
  = DagCompilerStrategy
  | OrderedSpeculativeCompilerStrategy
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
  runner <- lookupEnv "SOG_COMPILER_RUNNER"
  apiKey <- lookupEnv "OPENAI_API_KEY"
  skillText <- TextIO.readFile skillPath
  model <- Text.pack . fromMaybe "gpt-5.5" <$> lookupEnv "SOG_MODEL"
  endpoint <- loadGPTEndpointFromEnv
  insertPreloadPlanner <- loadCompilerPreloadPlanner
  strategy <- loadCompilerStrategy
  let skillName = fromMaybe "skill" maybeSkillName
  result <-
    case runner of
      Just "codex" ->
        compileSkillWithCodex strategy insertPreloadPlanner skillName skillText
      _ ->
        case apiKey of
          Nothing -> do
            putStrLn "OPENAI_API_KEY is not set."
            exitFailure
          Just key -> do
            let backend =
                  GPTBackend
                    { gptApiKey = key
                    , gptEndpoint = endpoint
                    }
            compileSkillWithStrategy backend model strategy skillName skillText
  case result of
    Left err -> do
      putStrLn ("Could not compile skill: " <> Text.unpack err)
      exitFailure
    Right graph -> do
      createDirectoryIfMissing True (takeDirectory outputPath)
      LazyByteString.writeFile outputPath (encode graph <> "\n")
      putStrLn ("Compiled goals written to " <> outputPath)

compileSkillWithCodex
  :: CompilerStrategy -> Bool -> Text -> Text -> IO (Either Text CompiledGoalGraph)
compileSkillWithCodex strategy insertPreloadPlanner skillName skillText = do
  config <- loadCodexProcessConfigFromEnv
  workspace <- compilerCodexWorkspace skillName
  let prompt =
        compilerCodexPromptForStrategy strategy insertPreloadPlanner skillName skillText
  result <- runCodexProcess config (\_event -> pure ()) Nothing workspace prompt
  if codexProcessTimedOut result
    then pure (Left "codex compiler run timed out")
    else
      if codexProcessExitCode result /= 0
        then
          pure
            ( Left
                ( "codex compiler run failed: "
                    <> Text.strip (codexProcessStderr result)
                )
            )
        else
          pure
            ( parseCompiledGoalGraphText
                ( firstNonEmptyText
                    (codexProcessLastMessage result)
                    (codexProcessStdout result)
                )
            )

compilerCodexWorkspace :: Text -> IO FilePath
compilerCodexWorkspace skillName = do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  now <- round . (* 1000000) <$> getPOSIXTime
  let
    safeName =
      Text.unpack
        (Text.map (\c -> if c == '/' || c == ' ' then '-' else c) skillName)
    workspace =
      tmp
        </> "sog-compiler-codex-"
          <> safeName
          <> "-"
          <> show pid
          <> "-"
          <> show (now :: Integer)
  createDirectoryIfMissing True workspace
  pure workspace

compilerCodexPrompt :: Text -> Text -> Text
compilerCodexPrompt skillName skillText =
  compilerCodexPromptForStrategy DagCompilerStrategy False skillName skillText

compilerCodexPromptWithPreloadPlanner :: Bool -> Text -> Text -> Text
compilerCodexPromptWithPreloadPlanner insertPreloadPlanner skillName skillText =
  compilerCodexPromptForStrategy DagCompilerStrategy insertPreloadPlanner skillName skillText

compilerCodexPromptForStrategy :: CompilerStrategy -> Bool -> Text -> Text -> Text
compilerCodexPromptForStrategy strategy insertPreloadPlanner skillName skillText =
  Text.replace "{{user_prompt}}" (compilerUserPrompt skillName skillText)
    . Text.replace
      "{{preload_instructions}}"
      (compilerPreloadPlannerInstructions insertPreloadPlanner)
    . Text.replace "{{system_prompt}}" (compilerSystemPrompt <> compilerStrategyInstructions strategy)
    $ $(embedTextFile "lib/Agent/SeaOfGoals/Prompts/compiler-codex-prompt.txt")

compileSkill
  :: LLM.LLM provider
  => provider
  -> Text
  -> Text
  -> Text
  -> IO (Either Text CompiledGoalGraph)
compileSkill provider model skillName skillText = do
  compileSkillWithStrategy provider model DagCompilerStrategy skillName skillText

compileSkillWithStrategy
  :: LLM.LLM provider
  => provider
  -> Text
  -> CompilerStrategy
  -> Text
  -> Text
  -> IO (Either Text CompiledGoalGraph)
compileSkillWithStrategy provider model strategy skillName skillText = do
  insertPreloadPlanner <- loadCompilerPreloadPlanner
  result <-
    LLM.runLLM
      provider
      LLMRequest
        { requestModel = model
        , requestInput =
            [ MessageInput
                LLMMessage
                  { messageRole = System
                  , messageContent =
                      [ TextPart
                          ( compilerSystemPrompt
                              <> compilerStrategyInstructions strategy
                              <> compilerPreloadPlannerInstructions insertPreloadPlanner
                          )
                      ]
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
        , requestPromptCacheKey = Nothing
        , requestPromptCacheRetention = Nothing
        }
  case result of
    Left err -> pure (Left (Text.pack (show err)))
    Right response ->
      pure (parseCompiledGoalGraph (responseMessage response))

parseCompiledGoalGraph :: LLMMessage -> Either Text CompiledGoalGraph
parseCompiledGoalGraph message = do
  parseCompiledGoalGraphText (messageText message)

parseCompiledGoalGraphText :: Text -> Either Text CompiledGoalGraph
parseCompiledGoalGraphText rawText = do
  graph <-
    case eitherDecode
      (LazyByteString.fromStrict (TextEncoding.encodeUtf8 (extractJsonObject rawText))) of
      Left err ->
        Left
          ("model response is not a compiled goal graph JSON object: " <> Text.pack err)
      Right value -> Right value
  case validateCompiledGoalGraph graph of
    [] ->
      Right
        (topologicallySortCompiledGoalGraph (transitivelyReduceCompiledGoalGraph graph))
    errors -> Left (Text.intercalate "; " errors)

transitivelyReduceCompiledGoalGraph :: CompiledGoalGraph -> CompiledGoalGraph
transitivelyReduceCompiledGoalGraph graph =
  graph
    { compiledGoals =
        fmap
          ( \goal ->
              goal
                { compiledGoalPredecessors =
                    filter
                      ( \predecessor ->
                          not
                            ( any
                                (\other -> other /= predecessor && reaches predecessor other)
                                (compiledGoalPredecessors goal)
                            )
                      )
                      (compiledGoalPredecessors goal)
                }
          )
          (compiledGoals graph)
    }
 where
  predecessorMap =
    Map.fromList
      [ (compiledGoalId goal, compiledGoalPredecessors goal)
      | goal <- compiledGoals graph
      ]

  reaches target current =
    target `elem` Map.findWithDefault [] current predecessorMap
      || any (reaches target) (Map.findWithDefault [] current predecessorMap)

topologicallySortCompiledGoalGraph :: CompiledGoalGraph -> CompiledGoalGraph
topologicallySortCompiledGoalGraph graph =
  graph{compiledGoals = reverse (go [] [] ready0)}
 where
  goals = compiledGoals graph
  goalMap = Map.fromList [(compiledGoalId goal, goal) | goal <- goals]
  goalOrder =
    Map.fromList
      [(compiledGoalId goal, index) | (index, goal) <- zip [0 :: Int ..] goals]
  successors =
    Map.fromListWith
      (<>)
      [ (predecessor, [compiledGoalId goal])
      | goal <- goals
      , predecessor <- compiledGoalPredecessors goal
      ]
  ready0 =
    sortGoalIds
      [compiledGoalId goal | goal <- goals, null (compiledGoalPredecessors goal)]

  go sorted _seen [] = sorted
  go sorted seen (current : rest) =
    let
      sorted' = Map.findWithDefault (error "missing goal") current goalMap : sorted
      seen' = current : seen
      newlyReady =
        [ successor
        | successor <- Map.findWithDefault [] current successors
        , successor `notElem` seen'
        , all (`elem` seen') (compiledGoalPredecessors (goalMap Map.! successor))
        ]
      rest' = sortGoalIds (rest <> newlyReady)
     in
      go sorted' seen' rest'

  sortGoalIds =
    sortOn (\goalId -> Map.findWithDefault maxBound goalId goalOrder) . uniqueText

uniqueText :: [Text] -> [Text]
uniqueText =
  go Set.empty
 where
  go _ [] = []
  go seen (item : rest)
    | item `Set.member` seen = go seen rest
    | otherwise = item : go (Set.insert item seen) rest

extractJsonObject :: Text -> Text
extractJsonObject text =
  case Text.findIndex (== '{') text of
    Nothing -> text
    Just start ->
      let candidate = Text.drop start text
       in fromMaybe candidate (balancedPrefix candidate)

balancedPrefix :: Text -> Maybe Text
balancedPrefix text =
  go 0 0 False False
 where
  go :: Int -> Int -> Bool -> Bool -> Maybe Text
  go index depth inString escaped
    | index >= Text.length text = Nothing
    | otherwise =
        let
          c = Text.index text index
          nextIndex = index + 1
         in
          if inString
            then
              if escaped
                then go nextIndex depth True False
                else case c of
                  '\\' -> go nextIndex depth True True
                  '"' -> go nextIndex depth False False
                  _ -> go nextIndex depth True False
            else case c of
              '"' -> go nextIndex depth True False
              '{' -> go nextIndex (depth + 1) False False
              '}' ->
                let nextDepth = depth - 1
                 in if nextDepth == 0
                      then Just (Text.take nextIndex text)
                      else go nextIndex nextDepth False False
              _ -> go nextIndex depth False False

firstNonEmptyText :: Text -> Text -> Text
firstNonEmptyText first second =
  if Text.null (Text.strip first)
    then second
    else first

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

compilerStrategyInstructions :: CompilerStrategy -> Text
compilerStrategyInstructions DagCompilerStrategy = ""
compilerStrategyInstructions OrderedSpeculativeCompilerStrategy =
  "\n\nThe runtime will launch every compiled goal immediately from the same initial workspace and commit them in list order. The list order is therefore the only execution order: make it a deliberate serial decomposition. Emit no predecessor edges. Each goal must describe a narrow, restart-safe slice of work and may be re-run after the earlier list prefix has been committed. Do not rely on predecessor summaries or a predecessor-produced workspace state at initial launch; later goals must inspect what they need themselves. Keep cross-goal file ownership as disjoint as practical, and put unavoidable integration or validation after the writers."

loadCompilerStrategy :: IO CompilerStrategy
loadCompilerStrategy = do
  value <- lookupEnv "SOG_COMPILER_STRATEGY"
  case Text.toLower . Text.pack <$> value of
    Nothing -> pure DagCompilerStrategy
    Just "dag" -> pure DagCompilerStrategy
    Just "ordered-speculative" -> pure OrderedSpeculativeCompilerStrategy
    Just other -> fail ("unknown SOG_COMPILER_STRATEGY: " <> Text.unpack other)

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

compilerPreloadPlannerInstructions :: Bool -> Text
compilerPreloadPlannerInstructions insertPreloadPlanner
  | not insertPreloadPlanner = ""
  | otherwise =
      $(embedTextFile "lib/Agent/SeaOfGoals/Prompts/compiler-preload-planner.txt")

loadCompilerPreloadPlanner :: IO Bool
loadCompilerPreloadPlanner = do
  value <- lookupEnv "SOG_COMPILER_PRELOAD_PLANNER"
  pure
    ( case Text.toLower . Text.pack <$> value of
        Just "1" -> True
        Just "true" -> True
        Just "yes" -> True
        Just "on" -> True
        _ -> False
    )
