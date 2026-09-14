module Agent.SeaOfGoals.Workspace.Bwrap.Visibility
  ( maskedWorkspaceMountsFromEnv
  )
where

import Agent.SeaOfGoals.Workspace.Bwrap.Command
  ( Mount (..)
  )
import Agent.SeaOfGoals.Workspace.Sandbox
  ( BindMode (BindReadOnly)
  )
import Control.Monad (forM)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath
  ( isRelative
  , normalise
  , splitDirectories
  , (</>)
  )

maskedWorkspaceMountsFromEnv :: FilePath -> Maybe Text -> IO [Mount]
maskedWorkspaceMountsFromEnv controlRoot goalId = do
  paths <- splitEnv ":" <$> lookupEnvText "SOG_BWRAP_MASK_WORKSPACE_PATHS"
  goals <- splitEnv "," <$> lookupEnvText "SOG_BWRAP_MASK_GOALS"
  if shouldMask goals goalId
    then forM (zip [0 :: Int ..] paths) (prepareMount controlRoot)
    else pure []

lookupEnvText :: String -> IO Text
lookupEnvText name = maybe "" Text.pack <$> lookupEnv name

splitEnv :: Text -> Text -> [Text]
splitEnv separator = filter (not . Text.null) . fmap Text.strip . Text.splitOn separator

shouldMask :: [Text] -> Maybe Text -> Bool
shouldMask [] _ = True
shouldMask goals (Just goalId) = goalId `elem` goals
shouldMask _ Nothing = False

prepareMount :: FilePath -> (Int, Text) -> IO Mount
prepareMount controlRoot (index, rawPath) = do
  relativePath <- validateRelativePath rawPath
  let emptyDirectory = controlRoot </> "masked-workspace" </> show index
  createDirectoryIfMissing True emptyDirectory
  pure
    Mount
      { mountHostPath = emptyDirectory
      , mountSandboxPath = "/workspace" </> relativePath
      , mountMode = BindReadOnly
      }

validateRelativePath :: Text -> IO FilePath
validateRelativePath rawPath =
  let
    path = normalise (Text.unpack rawPath)
    components = splitDirectories path
   in
    if isRelative path && path /= "." && ".." `notElem` components
      then pure path
      else fail ("invalid masked workspace path: " <> Text.unpack rawPath)
