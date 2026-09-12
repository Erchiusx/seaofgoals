module Agent.SeaOfGoals.Workspace.ConflictPolicy
  ( AccessSets (..)
  , ConflictMode (..)
  , conflictingPaths
  , loadConflictModeFromEnv
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import System.Environment (lookupEnv)

data ConflictMode
  = StrictAccessConflicts
  | FileWriteConflictsOnly
  deriving stock (Eq, Show)

data AccessSets = AccessSets
  { accessReads :: Set FilePath
  , accessWrites :: Set FilePath
  , accessRegularFileWrites :: Set FilePath
  }
  deriving stock (Eq, Show)

conflictingPaths :: ConflictMode -> AccessSets -> AccessSets -> Set FilePath
conflictingPaths StrictAccessConflicts current accepted =
  Set.unions
    [ Set.intersection (accessWrites current) (accessWrites accepted)
    , Set.intersection (accessWrites current) (accessReads accepted)
    , Set.intersection (accessReads current) (accessWrites accepted)
    ]
conflictingPaths FileWriteConflictsOnly current accepted =
  Set.unions
    [ Set.intersection
        (accessRegularFileWrites current)
        (accessRegularFileWrites accepted)
    , Set.intersection
        (accessRegularFileWrites current)
        (accessReads accepted)
    , Set.intersection
        (accessReads current)
        (accessRegularFileWrites accepted)
    ]

loadConflictModeFromEnv :: IO ConflictMode
loadConflictModeFromEnv = do
  value <- lookupEnv "SOG_CONFLICT_MODE"
  case value of
    Nothing -> pure StrictAccessConflicts
    Just "" -> pure StrictAccessConflicts
    Just "strict" -> pure StrictAccessConflicts
    Just "file-writes-only" -> pure FileWriteConflictsOnly
    Just other -> fail ("unknown SOG_CONFLICT_MODE: " <> other)
