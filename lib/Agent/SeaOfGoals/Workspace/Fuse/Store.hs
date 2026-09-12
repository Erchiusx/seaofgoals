module Agent.SeaOfGoals.Workspace.Fuse.Store
  ( Backend (..)
  , Conflict (..)
  , Handle
  , Snapshot (..)
  , Spec (..)
  , PathIdentity (..)
  , Access (..)
  , createDirectory
  , deletePath
  , listDirectory
  , localPath
  , readFile
  , readSymbolicLink
  , renamePath
  , statPath
  , touchPath
  , truncateFile
  , accessConflict
  , accessLog
  , readSet
  , writeSet
  , writeFile
  , writeFileAt
  )
where

import Agent.SeaOfGoals.Workspace.Backend
  ( BackendConflict
  , BackendHandle
  , BackendSnapshot
  , BackendSpec
  , Diff (..)
  , Mount (..)
  , PathChange (..)
  )
import Agent.SeaOfGoals.Workspace.Backend qualified as Workspace
import Control.Exception
  ( IOException
  , try
  )
import Control.Monad
  ( when
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (isAlphaNum)
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime)
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , doesPathExist
  , getFileSize
  , getModificationTime
  , makeAbsolute
  , removeFile
  )
import System.Directory qualified as Directory
import System.FilePath
  ( isAbsolute
  , normalise
  , splitDirectories
  , takeDirectory
  , (</>)
  )
import System.Posix.Files qualified as Posix
import Prelude hiding
  ( readFile
  , writeFile
  )

data Backend = Backend
  { backendRoot :: FilePath
  }
  deriving stock (Eq, Show)

data Spec = Spec
  { specTaskId :: Text
  , specBasePath :: FilePath
  , specAgentMountPath :: FilePath
  }
  deriving stock (Eq, Show)

data Handle = Handle
  { handleTaskId :: Text
  , handleBasePath :: FilePath
  , handleTaskRoot :: FilePath
  , handleFilesPath :: FilePath
  , handleTombstonesPath :: FilePath
  , handleMount :: Mount
  , handleObserved :: IORef (Map FilePath PathIdentity)
  , handleChanges :: IORef (Map FilePath PathChange)
  , handleAccesses :: IORef [Access]
  }

data Snapshot = Snapshot
  { snapshotTaskId :: Text
  , snapshotTaskRoot :: FilePath
  , snapshotDiff :: Diff
  }
  deriving stock (Eq, Show)

data Conflict = Conflict
  { conflictPath :: FilePath
  , conflictObserved :: PathIdentity
  , conflictCurrent :: PathIdentity
  }
  deriving stock (Eq, Show)

data PathIdentity
  = PathMissing
  | FileIdentity Integer UTCTime
  | DirectoryIdentity UTCTime
  deriving stock (Eq, Show)

data Access
  = ContentRead FilePath
  | MetadataRead FilePath
  | DirectoryRead FilePath
  | FileCreated FilePath
  | FileModified FilePath
  | FileDeleted FilePath
  | FileRenamed FilePath FilePath
  deriving stock (Eq, Show)

data AccessScope
  = ExactAccess FilePath
  | DirectoryAccess FilePath
  deriving stock (Eq, Show)

instance Workspace.Backend Backend where
  type BackendSpec Backend = Spec
  type BackendHandle Backend = Handle
  type BackendSnapshot Backend = Snapshot
  type BackendConflict Backend = Conflict

  prepareWorkspace backend spec = do
    backendRoot <- makeAbsolute (backendRoot backend)
    canonicalBasePath <- canonicalizePath (specBasePath spec)
    let
      taskRoot = backendRoot </> sanitizeTaskId (specTaskId spec)
      filesPath = taskRoot </> "files"
      tombstonesPath = taskRoot </> "tombstones"
      mountPath = taskRoot </> "mount"
    createDirectoryIfMissing True filesPath
    createDirectoryIfMissing True tombstonesPath
    createDirectoryIfMissing True mountPath
    observed <- newIORef Map.empty
    changes <- newIORef Map.empty
    accesses <- newIORef []
    pure
      Handle
        { handleTaskId = specTaskId spec
        , handleBasePath = canonicalBasePath
        , handleTaskRoot = taskRoot
        , handleFilesPath = filesPath
        , handleTombstonesPath = tombstonesPath
        , handleMount =
            Mount
              { mountHostPath = mountPath
              , mountAgentPath = specAgentMountPath spec
              }
        , handleObserved = observed
        , handleChanges = changes
        , handleAccesses = accesses
        }

  mount _ = handleMount

  diff _ handle = do
    changes <- Map.elems <$> readIORef (handleChanges handle)
    pure
      Diff
        { diffId = handleTaskId handle
        , diffChanges = changes
        }

  finalizeWorkspace backend handle = do
    observed <- readIORef (handleObserved handle)
    conflicts <- concat <$> traverse currentConflict (Map.toList observed)
    if null conflicts
      then do
        diffValue <- Workspace.diff backend handle
        pure
          ( Right
              Snapshot
                { snapshotTaskId = handleTaskId handle
                , snapshotTaskRoot = handleTaskRoot handle
                , snapshotDiff = diffValue
                }
          )
      else pure (Left conflicts)
   where
    currentConflict (relativePath, observedIdentity) = do
      currentIdentity <- captureBaseIdentity handle relativePath
      pure
        [ Conflict relativePath observedIdentity currentIdentity
        | currentIdentity /= observedIdentity
        ]

  cleanupWorkspace _ _ = pure ()

readFile :: Handle -> FilePath -> IO ByteString
readFile handle path = do
  relativePath <- normalizePath path
  recordAccess handle (ContentRead relativePath)
  tombstoned <- pathIsTombstoned handle relativePath
  if tombstoned
    then ioError (userError ("workspace path was deleted: " <> relativePath))
    else do
      let localPathValue = localFilePath handle relativePath
      localExists <- doesFileExist localPathValue
      if localExists
        then ByteString.readFile localPathValue
        else ByteString.readFile (basePath handle relativePath)

readSymbolicLink :: Handle -> FilePath -> IO FilePath
readSymbolicLink handle path = do
  relativePath <- normalizePath path
  recordAccess handle (MetadataRead relativePath)
  maybeRealPath <- statPath handle relativePath
  case maybeRealPath of
    Nothing -> ioError (userError ("workspace path does not exist: " <> relativePath))
    Just realPath -> Posix.readSymbolicLink realPath

writeFile :: Handle -> FilePath -> ByteString -> IO ()
writeFile handle path content = do
  relativePath <- normalizePath path
  observeBeforeChange handle relativePath
  existed <- pathExistsInView handle relativePath
  let destination = localFilePath handle relativePath
  createDirectoryIfMissing True (takeDirectory destination)
  ByteString.writeFile destination content
  removeTombstone handle relativePath
  recordAccess handle $
    if existed
      then FileModified relativePath
      else FileCreated relativePath
  recordChange handle relativePath $
    if existed
      then PathModified relativePath
      else PathCreated relativePath

writeFileAt
  :: Handle -> FilePath -> Integer -> ByteString -> IO ()
writeFileAt handle path offset content = do
  relativePath <- normalizePath path
  existing <- readFileOrEmpty handle relativePath
  let
    prefix = ByteString.take (fromInteger offset) existing
    paddingSize = fromInteger offset - ByteString.length existing
    padding =
      if paddingSize > 0
        then ByteString.replicate paddingSize 0
        else ""
    suffix = ByteString.drop (fromInteger offset + ByteString.length content) existing
  writeFile handle relativePath (prefix <> padding <> content <> suffix)

truncateFile :: Handle -> FilePath -> Integer -> IO ()
truncateFile handle path size = do
  relativePath <- normalizePath path
  existing <- readFileOrEmpty handle relativePath
  let
    currentSize = ByteString.length existing
    newContent =
      if size <= fromIntegral currentSize
        then ByteString.take (fromInteger size) existing
        else existing <> ByteString.replicate (fromInteger size - currentSize) 0
  writeFile handle relativePath newContent

touchPath :: Handle -> FilePath -> IO ()
touchPath handle path = do
  relativePath <- normalizePath path
  observeBeforeChange handle relativePath
  existed <- pathExistsInView handle relativePath
  if existed
    then do
      recordAccess handle (FileModified relativePath)
      recordChange handle relativePath (PathModified relativePath)
    else writeFile handle relativePath ""

createDirectory :: Handle -> FilePath -> IO ()
createDirectory handle path = do
  relativePath <- normalizePath path
  observeBeforeChange handle relativePath
  existed <- pathExistsInView handle relativePath
  if existed
    then ioError (userError ("workspace path already exists: " <> relativePath))
    else do
      let destination = localFilePath handle relativePath
      createDirectoryIfMissing True destination
      removeTombstone handle relativePath
      recordAccess handle (FileCreated relativePath)
      recordChange handle relativePath (PathCreated relativePath)

deletePath :: Handle -> FilePath -> IO ()
deletePath handle path = do
  relativePath <- normalizePath path
  when (relativePath == ".") $
    ioError (userError "cannot delete workspace root")
  observeBeforeChange handle relativePath
  existed <- pathExistsInView handle relativePath
  if existed
    then do
      let tombstone = tombstonePath handle relativePath
      createDirectoryIfMissing True (takeDirectory tombstone)
      ByteString.writeFile tombstone ""
      recordAccess handle (FileDeleted relativePath)
      recordChange handle relativePath (PathDeleted relativePath)
    else ioError (userError ("workspace path does not exist: " <> relativePath))

renamePath :: Handle -> FilePath -> FilePath -> IO ()
renamePath handle fromPath toPath = do
  fromRelativePath <- normalizePath fromPath
  toRelativePath <- normalizePath toPath
  observeBeforeChange handle fromRelativePath
  observeBeforeChange handle toRelativePath
  fromExists <- pathExistsInView handle fromRelativePath
  if fromExists
    then do
      content <- readFile handle fromRelativePath
      writeFile handle toRelativePath content
      deletePath handle fromRelativePath
      recordAccess handle (FileRenamed fromRelativePath toRelativePath)
      recordChange
        handle
        fromRelativePath
        (PathRenamed fromRelativePath toRelativePath)
    else ioError (userError ("workspace path does not exist: " <> fromRelativePath))

statPath :: Handle -> FilePath -> IO (Maybe FilePath)
statPath handle path = do
  relativePath <- normalizePath path
  recordAccess handle (MetadataRead relativePath)
  tombstoned <- pathIsTombstoned handle relativePath
  if tombstoned
    then pure Nothing
    else do
      let
        localPathValue = localFilePath handle relativePath
        basePathValue = basePath handle relativePath
      localExists <- doesPathExist localPathValue
      baseExists <- doesPathExist basePathValue
      pure $
        if localExists
          then Just localPathValue
          else
            if baseExists
              then Just basePathValue
              else Nothing

listDirectory :: Handle -> FilePath -> IO [FilePath]
listDirectory handle path = do
  relativePath <- normalizePath path
  recordAccess handle (DirectoryRead relativePath)
  tombstoned <- pathIsTombstoned handle relativePath
  if tombstoned
    then ioError (userError ("workspace directory was deleted: " <> relativePath))
    else do
      baseEntries <- listIfDirectory (basePath handle relativePath)
      localEntries <- listIfDirectory (localFilePath handle relativePath)
      tombstoneEntries <- listIfDirectory (tombstonePath handle relativePath)
      pure
        [ entry
        | entry <- dedupe (baseEntries <> localEntries)
        , entry `notElem` tombstoneEntries
        ]

localPath :: Handle -> FilePath -> IO FilePath
localPath handle path = localFilePath handle <$> normalizePath path

accessLog :: Handle -> IO [Access]
accessLog handle =
  reverse <$> readIORef (handleAccesses handle)

readSet :: [Access] -> Set FilePath
readSet =
  Set.fromList . concatMap accessReadPaths

writeSet :: [Access] -> Set FilePath
writeSet =
  Set.fromList . concatMap accessWritePaths

accessConflict :: [Access] -> [Access] -> Bool
accessConflict left right =
  writesOverlapAccesses left right
    || writesOverlapAccesses right left
 where
  writesOverlapAccesses writer accessor =
    or
      [ writePathMatchesScope writePath accessScope
      | writePath <- Set.toList (writeSet writer)
      , accessScope <- concatMap accessScopes accessor
      ]

normalizePath :: FilePath -> IO FilePath
normalizePath "" = pure "."
normalizePath "." = pure "."
normalizePath path
  | isAbsolute path = reject
  | any isUnsafeComponent components = reject
  | otherwise = pure normalized
 where
  normalized = normalise path
  components = splitDirectories normalized
  reject = ioError (userError ("unsafe workspace path: " <> path))

isUnsafeComponent :: FilePath -> Bool
isUnsafeComponent "" = True
isUnsafeComponent "." = False
isUnsafeComponent ".." = True
isUnsafeComponent _ = False

observeBeforeChange :: Handle -> FilePath -> IO ()
observeBeforeChange handle relativePath = do
  identity <- captureBaseIdentity handle relativePath
  modifyIORef'
    (handleObserved handle)
    (Map.insertWith keepOld relativePath identity)
 where
  keepOld old _new = old

recordChange :: Handle -> FilePath -> PathChange -> IO ()
recordChange handle relativePath change =
  modifyIORef'
    (handleChanges handle)
    (Map.insertWith combineChange relativePath change)

recordAccess :: Handle -> Access -> IO ()
recordAccess handle access =
  modifyIORef' (handleAccesses handle) (access :)

combineChange
  :: PathChange -> PathChange -> PathChange
combineChange (PathModified _) old@(PathCreated _) = old
combineChange new _old = new

pathExistsInView :: Handle -> FilePath -> IO Bool
pathExistsInView handle relativePath = do
  tombstoned <- pathIsTombstoned handle relativePath
  if tombstoned
    then pure False
    else do
      localExists <- doesPathExist (localFilePath handle relativePath)
      if localExists
        then pure True
        else doesPathExist (basePath handle relativePath)

captureBaseIdentity :: Handle -> FilePath -> IO PathIdentity
captureBaseIdentity handle relativePath = do
  let path = basePath handle relativePath
  fileExists <- doesFileExist path
  directoryExists <- doesDirectoryExist path
  case (fileExists, directoryExists) of
    (True, _) -> FileIdentity <$> getFileSize path <*> getModificationTime path
    (_, True) -> DirectoryIdentity <$> getModificationTime path
    _ -> pure PathMissing

removeTombstone :: Handle -> FilePath -> IO ()
removeTombstone handle relativePath = do
  result <-
    try (removeFile (tombstonePath handle relativePath))
      :: IO (Either IOException ())
  either (const (pure ())) pure result

pathIsTombstoned :: Handle -> FilePath -> IO Bool
pathIsTombstoned _ "." = pure False
pathIsTombstoned handle relativePath =
  doesFileExist (tombstonePath handle relativePath)

readFileOrEmpty :: Handle -> FilePath -> IO ByteString
readFileOrEmpty handle relativePath = do
  result <-
    try (readFile handle relativePath)
      :: IO (Either IOException ByteString)
  either (const (pure "")) pure result

listIfDirectory :: FilePath -> IO [FilePath]
listIfDirectory path = do
  exists <- doesDirectoryExist path
  if exists
    then Directory.listDirectory path
    else pure []

dedupe :: [FilePath] -> [FilePath]
dedupe = Map.keys . Map.fromList . fmap (,())

basePath :: Handle -> FilePath -> FilePath
basePath handle relativePath = handleBasePath handle </> relativePath

localFilePath :: Handle -> FilePath -> FilePath
localFilePath handle relativePath = handleFilesPath handle </> relativePath

tombstonePath :: Handle -> FilePath -> FilePath
tombstonePath handle relativePath = handleTombstonesPath handle </> relativePath

sanitizeTaskId :: Text -> FilePath
sanitizeTaskId =
  map sanitizeChar . Text.unpack
 where
  sanitizeChar character
    | isAlphaNum character || character `elem` ("-_." :: String) = character
    | otherwise = '_'

accessReadPaths :: Access -> [FilePath]
accessReadPaths (ContentRead path) = [path]
accessReadPaths (MetadataRead path) = [path]
accessReadPaths (DirectoryRead path) = [path]
accessReadPaths (FileCreated _) = []
accessReadPaths (FileModified _) = []
accessReadPaths (FileDeleted _) = []
accessReadPaths (FileRenamed _ _) = []

accessWritePaths :: Access -> [FilePath]
accessWritePaths (ContentRead _) = []
accessWritePaths (MetadataRead _) = []
accessWritePaths (DirectoryRead _) = []
accessWritePaths (FileCreated path) = [path]
accessWritePaths (FileModified path) = [path]
accessWritePaths (FileDeleted path) = [path]
accessWritePaths (FileRenamed fromPath toPath) = [fromPath, toPath]

accessScopes :: Access -> [AccessScope]
accessScopes (ContentRead path) = [ExactAccess path]
accessScopes (MetadataRead path) = [ExactAccess path]
accessScopes (DirectoryRead path) = [DirectoryAccess path]
accessScopes access =
  ExactAccess <$> accessWritePaths access

writePathMatchesScope :: FilePath -> AccessScope -> Bool
writePathMatchesScope writePath (ExactAccess path) =
  writePath == path
writePathMatchesScope writePath (DirectoryAccess path) =
  pathContains path writePath

pathContains :: FilePath -> FilePath -> Bool
pathContains "." _ = True
pathContains directory path =
  directoryParts == pathParts
    || directoryParts `isPrefixOf` pathParts
 where
  directoryParts = splitDirectories (normalise directory)
  pathParts = splitDirectories (normalise path)
