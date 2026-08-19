module Agent.SeaOfGoals.Workspace.Fuse.Merge
  ( FuseMergeInput (..)
  , MergeConflict (..)
  , MergeResult (..)
  , mergeFuseSnapshots
  )
where

import Agent.SeaOfGoals.Workspace.Backend
  ( Diff (..)
  , PathChange (..)
  )
import Agent.SeaOfGoals.Workspace.Effects
  ( EffectScope
  , scopedAccessConflict
  )
import Agent.SeaOfGoals.Workspace.Fuse.Store
  ( Access
  , Snapshot (..)
  )
import Control.Monad
  ( when
  )
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , doesPathExist
  , removeFile
  , removePathForcibly
  )
import System.FilePath
  ( takeDirectory
  , (</>)
  )

data FuseMergeInput = FuseMergeInput
  { fuseMergeInputSnapshot :: Snapshot
  , fuseMergeInputAccesses :: [Access]
  }
  deriving stock (Eq, Show)

data MergeConflict
  = AccessConflict
  { mergeFormerTask :: Text
  , mergeLatterTask :: Text
  }
  deriving stock (Eq, Show)

data MergeResult = MergeResult
  { mergeTargetPath :: FilePath
  , mergeAppliedTasks :: [Text]
  }
  deriving stock (Eq, Show)

mergeFuseSnapshots
  :: EffectScope
  -> FilePath
  -> [FuseMergeInput]
  -> IO (Either MergeConflict MergeResult)
mergeFuseSnapshots scope target inputs =
  case firstAccessConflict scope inputs of
    Just conflict ->
      pure (Left conflict)
    Nothing -> do
      createDirectoryIfMissing True target
      mapM_ (applyFuseSnapshot target . fuseMergeInputSnapshot) inputs
      pure
        ( Right
            MergeResult
              { mergeTargetPath = target
              , mergeAppliedTasks =
                  fmap
                    (snapshotTaskId . fuseMergeInputSnapshot)
                    inputs
              }
        )

firstAccessConflict
  :: EffectScope -> [FuseMergeInput] -> Maybe MergeConflict
firstAccessConflict scope inputs =
  case [ AccessConflict
           { mergeFormerTask = snapshotId former
           , mergeLatterTask = snapshotId latter
           }
       | (former, rest) <- suffixes inputs
       , latter <- rest
       , scopedAccessConflict
           scope
           (fuseMergeInputAccesses former)
           (fuseMergeInputAccesses latter)
       ] of
    conflict : _ -> Just conflict
    [] -> Nothing
 where
  snapshotId = snapshotTaskId . fuseMergeInputSnapshot

suffixes :: [value] -> [(value, [value])]
suffixes [] = []
suffixes (value : rest) =
  (value, rest) : suffixes rest

applyFuseSnapshot :: FilePath -> Snapshot -> IO ()
applyFuseSnapshot target snapshot =
  mapM_ (applyChange target snapshot) changes
 where
  changes = diffChanges (snapshotDiff snapshot)

applyChange :: FilePath -> Snapshot -> PathChange -> IO ()
applyChange target snapshot change =
  case change of
    PathCreated path ->
      copySnapshotFile target snapshot path
    PathModified path ->
      copySnapshotFile target snapshot path
    PathDeleted path ->
      removeTargetPath target path
    PathRenamed fromPath toPath -> do
      removeTargetPath target fromPath
      copySnapshotFile target snapshot toPath

copySnapshotFile :: FilePath -> Snapshot -> FilePath -> IO ()
copySnapshotFile target snapshot path = do
  let
    source = snapshotFilePath snapshot path
    destination = target </> path
  sourceExists <- doesFileExist source
  if sourceExists
    then do
      createDirectoryIfMissing True (takeDirectory destination)
      ByteString.readFile source >>= ByteString.writeFile destination
    else ioError (userError ("snapshot file is missing: " <> source))

removeTargetPath :: FilePath -> FilePath -> IO ()
removeTargetPath target path = do
  let destination = target </> path
  exists <- doesPathExist destination
  when exists $ do
    isFile <- doesFileExist destination
    if isFile
      then removeFile destination
      else removePathForcibly destination

snapshotFilePath :: Snapshot -> FilePath -> FilePath
snapshotFilePath snapshot path =
  snapshotTaskRoot snapshot </> "files" </> path
