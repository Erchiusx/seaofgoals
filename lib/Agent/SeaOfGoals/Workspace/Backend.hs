module Agent.SeaOfGoals.Workspace.Backend
  ( Backend (..)
  , Diff (..)
  , Mount (..)
  , PathChange (..)
  )
where

import Data.Text (Text)

data Mount = Mount
  { mountHostPath :: FilePath
  , mountAgentPath :: FilePath
  }
  deriving stock (Eq, Show)

data PathChange
  = PathCreated FilePath
  | PathModified FilePath
  | PathDeleted FilePath
  | PathRenamed FilePath FilePath
  deriving stock (Eq, Show)

data Diff = Diff
  { diffId :: Text
  , diffChanges :: [PathChange]
  }
  deriving stock (Eq, Show)

class Backend backend where
  type BackendSpec backend
  type BackendHandle backend
  type BackendSnapshot backend
  type BackendConflict backend

  prepareWorkspace
    :: backend -> BackendSpec backend -> IO (BackendHandle backend)
  mount :: backend -> BackendHandle backend -> Mount
  diff :: backend -> BackendHandle backend -> IO Diff
  finalizeWorkspace
    :: backend
    -> BackendHandle backend
    -> IO (Either [BackendConflict backend] (BackendSnapshot backend))
  cleanupWorkspace :: backend -> BackendHandle backend -> IO ()
