module Agent.SeaOfGoals.Workspace.Effects
  ( EffectScope (..)
  , ScopedEffects (..)
  , normalizeAccessEffects
  , scopeAccesses
  , scopedAccessConflict
  )
where

import Agent.SeaOfGoals.Workspace.Fuse.Store
  ( Access (..)
  , accessConflict
  )
import Data.List qualified as List
import Data.Maybe (maybeToList)
import System.FilePath
  ( isAbsolute
  , makeRelative
  , normalise
  , splitDirectories
  )

data EffectScope
  = FullObserved
  | RootOnly FilePath
  deriving stock (Eq, Show)

data ScopedEffects = ScopedEffects
  { scopedAccesses :: [Access]
  , scopedIgnoredExternalAccesses :: [Access]
  }
  deriving stock (Eq, Show)

scopeAccesses
  :: EffectScope -> [Access] -> ScopedEffects
scopeAccesses scope =
  normalizeScopedEffects . foldMap (scopeAccess scope)

scopedAccessConflict
  :: EffectScope -> [Access] -> [Access] -> Bool
scopedAccessConflict scope left right =
  accessConflict
    (scopedAccesses (scopeAccesses scope left))
    (scopedAccesses (scopeAccesses scope right))

normalizeAccessEffects :: [Access] -> [Access]
normalizeAccessEffects =
  concatMap normalizeAccessEffect

normalizeAccessEffect :: Access -> [Access]
normalizeAccessEffect access =
  case access of
    FileRenamed fromPath toPath ->
      [FileDeleted fromPath, FileCreated toPath]
    _ ->
      [access]

normalizeScopedEffects
  :: ScopedEffects -> ScopedEffects
normalizeScopedEffects scoped =
  scoped
    { scopedAccesses =
        normalizeAccessEffects (scopedAccesses scoped)
    }

scopeAccess :: EffectScope -> Access -> ScopedEffects
scopeAccess FullObserved access =
  ScopedEffects [access] []
scopeAccess scope@(RootOnly _) access =
  case scoped of
    [] -> ScopedEffects [] [access]
    _ -> ScopedEffects scoped []
 where
  scoped =
    case access of
      ContentRead path ->
        maybeToList (ContentRead <$> scopePath scope path)
      MetadataRead path ->
        maybeToList (MetadataRead <$> scopePath scope path)
      DirectoryRead path ->
        maybeToList (DirectoryRead <$> scopePath scope path)
      FileCreated path ->
        maybeToList (FileCreated <$> scopePath scope path)
      FileModified path ->
        maybeToList (FileModified <$> scopePath scope path)
      FileDeleted path ->
        maybeToList (FileDeleted <$> scopePath scope path)
      FileRenamed fromPath toPath ->
        scopeRename scope fromPath toPath

scopeRename :: EffectScope -> FilePath -> FilePath -> [Access]
scopeRename scope fromPath toPath =
  case (scopePath scope fromPath, scopePath scope toPath) of
    (Just scopedFrom, Just scopedTo) ->
      [FileRenamed scopedFrom scopedTo]
    (Just scopedFrom, Nothing) ->
      [FileDeleted scopedFrom]
    (Nothing, Just scopedTo) ->
      [FileCreated scopedTo]
    (Nothing, Nothing) ->
      []

scopePath :: EffectScope -> FilePath -> Maybe FilePath
scopePath FullObserved path =
  Just path
scopePath (RootOnly root) path
  | not (isAbsolute normalizedPath) =
      Just normalizedPath
  | normalizedPath == normalizedRoot =
      Just "."
  | normalizedRoot `pathContains` normalizedPath =
      Just (normalise (makeRelative normalizedRoot normalizedPath))
  | otherwise =
      Nothing
 where
  normalizedPath = normalise path
  normalizedRoot = normalise root

pathContains :: FilePath -> FilePath -> Bool
pathContains directory path =
  directoryParts `List.isPrefixOf` pathParts
 where
  directoryParts = splitDirectories (normalise directory)
  pathParts = splitDirectories (normalise path)

instance Semigroup ScopedEffects where
  left <> right =
    ScopedEffects
      { scopedAccesses =
          scopedAccesses left <> scopedAccesses right
      , scopedIgnoredExternalAccesses =
          scopedIgnoredExternalAccesses left <> scopedIgnoredExternalAccesses right
      }

instance Monoid ScopedEffects where
  mempty =
    ScopedEffects
      { scopedAccesses = []
      , scopedIgnoredExternalAccesses = []
      }
