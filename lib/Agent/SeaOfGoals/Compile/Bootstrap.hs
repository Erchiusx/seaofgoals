module Agent.SeaOfGoals.Compile.Bootstrap
  ( runBootstrappedCompilerFromArgs
  )
where

import Agent.SeaOfGoals.Compile.Compiler
  ( CompiledGoal (..)
  , CompiledGoalGraph (..)
  , compilerCodexPromptWithPreloadPlanner
  , parseCompiledGoalGraphText
  )
import Agent.SeaOfGoals.ExperimentRunner
  ( runPrompt
  )
import Control.Exception
  ( bracket
  )
import Data.Aeson
  ( encode
  )
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Maybe
  ( fromMaybe
  )
import Data.Text
  ( Text
  )
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX
  ( getPOSIXTime
  )
import System.Directory
  ( createDirectoryIfMissing
  , getCurrentDirectory
  , getTemporaryDirectory
  , setCurrentDirectory
  )
import System.Environment
  ( getArgs
  , lookupEnv
  , setEnv
  , unsetEnv
  )
import System.Exit
  ( exitFailure
  )
import System.FilePath
  ( takeDirectory
  , (</>)
  )
import System.Posix.Process
  ( getProcessID
  )

runBootstrappedCompilerFromArgs :: IO ()
runBootstrappedCompilerFromArgs = do
  args <- getArgs
  case args of
    [skillPath, outputPath] -> runBootstrappedCompiler skillPath outputPath Nothing
    [skillPath, outputPath, skillName] ->
      runBootstrappedCompiler skillPath outputPath (Just (Text.pack skillName))
    _ -> do
      putStrLn
        "Usage: SeaOfGoals-compiler-bootstrap <skill.md> <compiled-goals.json> [skill-name]"
      exitFailure

runBootstrappedCompiler :: FilePath -> FilePath -> Maybe Text -> IO ()
runBootstrappedCompiler skillPath outputPath maybeSkillName = do
  skillText <- TextIO.readFile skillPath
  let skillName = fromMaybe "skill" maybeSkillName
  insertPreloadPlanner <- loadCompilerPreloadPlanner
  workspace <- compilerBootstrapWorkspace skillName
  let controlRoot = workspace <> ".sog"
  createDirectoryIfMissing True workspace
  createDirectoryIfMissing True controlRoot
  withCurrentDirectory workspace $ do
    runCompilerNode controlRoot insertPreloadPlanner skillName skillText
    rawOutput <- TextIO.readFile (workspace </> "compiled-goals.json")
    case parseCompiledGoalGraphText rawOutput of
      Left err -> do
        putStrLn ("Bootstrapped compiler produced invalid graph: " <> Text.unpack err)
        putStrLn ("Workspace retained at " <> workspace)
        exitFailure
      Right graph -> do
        createDirectoryIfMissing True (takeDirectory outputPath)
        LazyByteString.writeFile outputPath (encode graph <> "\n")
        putStrLn ("Compiled goals written to " <> outputPath)
        putStrLn ("Bootstrap trace written to " <> controlRoot </> "sog-trace.jsonl")

runCompilerNode :: FilePath -> Bool -> Text -> Text -> IO ()
runCompilerNode controlRoot insertPreloadPlanner skillName skillText =
  withEnv "SOG_AGENT_RUNNER" (Just "codex")
    $ withEnv "SOG_SCHEDULER" (Just "serial")
    $ withEnv
      "SOG_SERIAL_GOALS_TEXT"
      (Just (bootstrapGraphJson insertPreloadPlanner skillName skillText))
    $ withEnv "SOG_CONTROL_ROOT" (Just controlRoot)
    $ withEnv "SOG_TRACE_PATH" (Just (controlRoot </> "sog-trace.jsonl"))
    $ runPrompt "" bootstrapTaskPrompt

bootstrapGraphJson :: Bool -> Text -> Text -> String
bootstrapGraphJson insertPreloadPlanner skillName skillText =
  Text.unpack
    ( TextEncoding.decodeUtf8
        ( LazyByteString.toStrict
            (encode (bootstrapGraph insertPreloadPlanner skillName skillText))
        )
    )

bootstrapGraph :: Bool -> Text -> Text -> CompiledGoalGraph
bootstrapGraph insertPreloadPlanner skillName skillText =
  CompiledGoalGraph
    { compiledSkill = skillName <> "-compiler-bootstrap"
    , compiledGoals =
        [ CompiledGoal
            { compiledGoalId = "G001"
            , compiledGoalName = "Compile skill graph"
            , compiledGoalDescription =
                "Compile the source skill into a SeaOfGoals goal graph."
            , compiledGoalPredecessors = []
            , compiledGoalEnteringPrompt =
                Text.intercalate
                  "\n\n"
                  [ "Run the SeaOfGoals compiler for the skill below."
                  , "Write the compiled JSON object to /workspace/compiled-goals.json."
                  , "The file must contain only one JSON object with keys `skill` and `goals`."
                  , "After writing the file, inspect it once and report a concise summary."
                  , compilerCodexPromptWithPreloadPlanner
                      insertPreloadPlanner
                      skillName
                      skillText
                  ]
            }
        ]
    }

bootstrapTaskPrompt :: Text
bootstrapTaskPrompt =
  Text.unlines
    [ "Compile the provided skill into a SeaOfGoals DAG."
    , "The compiled result must be written by the goal process to /workspace/compiled-goals.json."
    ]

compilerBootstrapWorkspace :: Text -> IO FilePath
compilerBootstrapWorkspace skillName = do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  now <- round . (* 1000000) <$> getPOSIXTime
  let safeName =
        Text.unpack
          (Text.map (\c -> if c == '/' || c == ' ' then '-' else c) skillName)
  pure
    ( tmp
        </> "sog-compiler-bootstrap-"
          <> safeName
          <> "-"
          <> show pid
          <> "-"
          <> show (now :: Integer)
    )

withCurrentDirectory :: FilePath -> IO a -> IO a
withCurrentDirectory path =
  bracket getCurrentDirectory setCurrentDirectory . const . go
 where
  go action = do
    setCurrentDirectory path
    action

withEnv :: String -> Maybe String -> IO a -> IO a
withEnv name value =
  bracket (lookupEnv name) restore . const . setAndRun
 where
  restore Nothing = unsetEnv name
  restore (Just oldValue) = setEnv name oldValue

  setAndRun action = do
    case value of
      Nothing -> unsetEnv name
      Just newValue -> setEnv name newValue
    action

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
