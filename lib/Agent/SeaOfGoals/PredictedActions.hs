module Agent.SeaOfGoals.PredictedActions
  ( PredictedAction (..)
  , PredictedActionsPlan (..)
  , loadPredictedActionsPlanFromEnv
  , mergePredictedActionsPlans
  , readPredictedActionsPlanFile
  , runPredictedActions
  )
where

import Agent.SeaOfGoals.LLM
  ( LLMContentPart (TextPart)
  , LLMInputItem (ToolCallInput, ToolResultInput)
  , ToolCall (..)
  , ToolResult (..)
  )
import Agent.SeaOfGoals.Workspace.ProcessExec
  ( ProcessExecSpec (..)
  , runProcessExec
  )
import Agent.SeaOfGoals.Workspace.Sandbox
  ( ExecTimeout (..)
  , SandboxExecOutcome (..)
  )
import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , eitherDecode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Encoding.Error qualified as TextEncodingError
import System.Environment (lookupEnv)

data PredictedAction = PredictedAction
  { predictedActionCommand :: Text
  }
  deriving stock (Eq, Show)

newtype PredictedActionsPlan = PredictedActionsPlan
  { predictedActionsPlanGoals :: Map Text [PredictedAction]
  }
  deriving stock (Eq, Show)

instance FromJSON PredictedAction where
  parseJSON = withObject "PredictedAction" $ \value ->
    PredictedAction <$> value .: "command"

instance ToJSON PredictedAction where
  toJSON action = object ["command" .= predictedActionCommand action]

instance FromJSON PredictedActionsPlan where
  parseJSON = withObject "PredictedActionsPlan" $ \value ->
    PredictedActionsPlan <$> value .: "goals"

instance ToJSON PredictedActionsPlan where
  toJSON plan = object ["goals" .= predictedActionsPlanGoals plan]

mergePredictedActionsPlans
  :: PredictedActionsPlan -> PredictedActionsPlan -> PredictedActionsPlan
mergePredictedActionsPlans (PredictedActionsPlan left) (PredictedActionsPlan right) =
  PredictedActionsPlan (Map.unionWith (<>) left right)

readPredictedActionsPlanFile
  :: FilePath -> IO (Either String PredictedActionsPlan)
readPredictedActionsPlanFile path = eitherDecode <$> LazyByteString.readFile path

loadPredictedActionsPlanFromEnv :: IO PredictedActionsPlan
loadPredictedActionsPlanFromEnv = do
  maybePath <- lookupEnv "SOG_PREDICTED_ACTIONS_PLAN"
  case maybePath of
    Just path
      | not (null path) ->
          either fail pure =<< eitherDecode <$> LazyByteString.readFile path
    _ -> pure (PredictedActionsPlan Map.empty)

runPredictedActions
  :: Maybe [PredictedAction]
  -> FilePath
  -> IO [LLMInputItem]
runPredictedActions Nothing _ = pure []
runPredictedActions (Just actions) workspace = do
  results <-
    mapM (uncurry (runPredictedAction workspace)) (zip [1 :: Int ..] actions)
  pure (concat results)

runPredictedAction :: FilePath -> Int -> PredictedAction -> IO [LLMInputItem]
runPredictedAction workspace actionNumber action
  | not (readOnlyCommand command) = pure (invalidAction command)
  | otherwise = do
      outcome <-
        runProcessExec
          ProcessExecSpec
            { processExecArgv = ["bash", "-lc", Text.unpack command]
            , processExecCwd = Just workspace
            , processExecEnv = Nothing
            , processExecTimeout = ExecTimeoutSeconds 120
            , processExecStdin = Nothing
            }
      let call = predictedCall actionNumber command
      pure
        [ ToolCallInput call
        , ToolResultInput
            ToolResult
              { toolResultCallId = toolCallId call
              , toolResultName = Just "bash"
              , toolResultContent =
                  [ TextPart
                      ( Text.unlines
                          [ "exit_code: " <> Text.pack (show (sandboxExecExitCode outcome))
                          , "timed_out: " <> Text.pack (show (sandboxExecTimedOut outcome))
                          , "stdout:"
                          , decode (sandboxExecStdout outcome)
                          , "stderr:"
                          , decode (sandboxExecStderr outcome)
                          ]
                      )
                  ]
              }
        ]
 where
  command = Text.strip (predictedActionCommand action)
  decode = TextEncoding.decodeUtf8With TextEncodingError.lenientDecode

predictedCall :: Int -> Text -> ToolCall
predictedCall actionNumber command =
  ToolCall
    { toolCallId = "sog_predicted_bash_" <> Text.pack (show actionNumber)
    , toolCallName = "bash"
    , toolCallArguments = object ["command" .= command]
    }

invalidAction :: Text -> [LLMInputItem]
invalidAction command =
  [ ToolCallInput call
  , ToolResultInput
      ToolResult
        { toolResultCallId = toolCallId call
        , toolResultName = Just "bash"
        , toolResultContent =
            [TextPart "predicted action rejected: only read-only commands are allowed"]
        }
  ]
 where
  call = predictedCall 0 command

readOnlyCommand :: Text -> Bool
readOnlyCommand command =
  not (any (`Text.isInfixOf` Text.toLower command) forbidden)
 where
  forbidden =
    [ " >"
    , ">>"
    , " rm "
    , " mv "
    , " cp "
    , " mkdir "
    , " touch "
    , " chmod "
    , " sed -i"
    , " perl -i"
    , " tee "
    , "npm install"
    , "pnpm install"
    , "yarn add"
    , "git checkout"
    , "git reset"
    ]
