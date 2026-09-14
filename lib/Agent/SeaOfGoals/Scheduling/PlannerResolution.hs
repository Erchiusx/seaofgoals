module Agent.SeaOfGoals.Scheduling.PlannerResolution
  ( Kind (..)
  , Resolution (..)
  , decodeResolution
  )
where

import Data.Aeson
  ( FromJSON (..)
  , eitherDecodeStrict'
  , withObject
  , withText
  , (.:)
  )
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding

data Kind
  = CompletedByPlanner
  | NoAction
  deriving stock (Eq, Show)

instance FromJSON Kind where
  parseJSON = withText "planner resolution kind" $ \case
    "completed_by_planner" -> pure CompletedByPlanner
    "no_action" -> pure NoAction
    other -> fail ("unknown planner resolution kind: " <> show other)

data Resolution = Resolution
  { resolutionGoalId :: Text
  , resolutionKind :: Kind
  , resolutionContext :: Text
  }
  deriving stock (Eq, Show)

instance FromJSON Resolution where
  parseJSON =
    withObject "planner goal resolution" $ \value ->
      Resolution
        <$> value .: "goal_id"
        <*> value .: "kind"
        <*> value .: "context"

decodeResolution :: Text -> Either String Resolution
decodeResolution = eitherDecodeStrict' . TextEncoding.encodeUtf8
