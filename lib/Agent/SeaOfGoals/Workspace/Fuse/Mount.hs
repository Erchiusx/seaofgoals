module Agent.SeaOfGoals.Workspace.Fuse.Mount
  ( FuseMountHandle (..)
  , fuseWorkspaceOperations
  , mountFuseWorkspace
  , unmountFuseWorkspace
  )
where

import Agent.SeaOfGoals.Workspace.Backend
  ( Mount (..)
  )
import Agent.SeaOfGoals.Workspace.Fuse.Store
  ( Handle
  )
import Agent.SeaOfGoals.Workspace.Fuse.Store qualified as Store
import Control.Concurrent
  ( MVar
  , ThreadId
  , forkIO
  , killThread
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , threadDelay
  , tryPutMVar
  , withMVar
  )
import Control.Exception
  ( IOException
  , SomeException
  , onException
  , throwIO
  , toException
  , try
  )
import Data.ByteString qualified as ByteString
import Data.Foldable (traverse_)
import Foreign.C.Error
  ( Errno
  , eACCES
  , eIO
  , eNOENT
  , eOK
  )
import Foreign.C.Types (CInt)
import System.Environment
  ( lookupEnv
  , withArgs
  )
import System.Exit (ExitCode (..))
import System.FilePath
  ( dropDrive
  , normalise
  , splitDirectories
  )
import System.IO
  ( hFlush
  , hPutStrLn
  , stderr
  )
import System.IO.Unsafe (unsafePerformIO)
import System.LibFuse3
  ( FileStat
  , FuseOperations (..)
  , defaultExceptionHandler
  , defaultFuseOperations
  , fuseMain
  , getFileStat
  )
import System.Posix.IO
  ( OpenFileFlags
  , OpenMode
  )
import System.Posix.Types
  ( ByteCount
  , FileMode
  , FileOffset
  )
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

data FuseMountHandle = FuseMountHandle
  { fuseMountThreadId :: ThreadId
  , fuseMountHostPath :: FilePath
  }

mountFuseWorkspace :: Handle -> Mount -> IO FuseMountHandle
mountFuseWorkspace handle mount = do
  ready <- newEmptyMVar
  threadId <-
    withMVar fuseArgsLock $ \() ->
      withArgs [mountHostPath mount, "-f"] $ do
        threadId <-
          forkIO $ do
            result <-
              try
                ( fuseMain
                    (fuseWorkspaceOperationsWithReady (Just ready) handle)
                    defaultExceptionHandler
                )
            case result of
              Right () -> do
                _ <-
                  tryPutMVar
                    ready
                    (Left (toException (userError "FUSE exited before mount became ready")))
                pure ()
              Left err -> do
                _ <- tryPutMVar ready (Left err)
                pure ()
        readiness <- timeout 5000000 (readMVar ready)
        ( case readiness of
            Just (Right ()) -> waitForMountPoint (mountHostPath mount)
            Just (Left err) -> throwIO err
            Nothing ->
              ioError
                ( userError
                    ("timed out mounting FUSE workspace: " <> mountHostPath mount)
                )
          )
          `onException` cleanupFuseThread threadId (mountHostPath mount)
        pure threadId
  pure
    FuseMountHandle
      { fuseMountThreadId = threadId
      , fuseMountHostPath = mountHostPath mount
      }

fuseArgsLock :: MVar ()
fuseArgsLock = unsafePerformIO (newMVar ())
{-# NOINLINE fuseArgsLock #-}

waitForMountPoint :: FilePath -> IO ()
waitForMountPoint path = do
  ready <- timeout 5000000 (go)
  case ready of
    Just () -> pure ()
    Nothing ->
      ioError (userError ("timed out waiting for FUSE mountpoint: " <> path))
 where
  go = do
    mounted <- isMountPoint path
    if mounted
      then pure ()
      else threadDelay 50000 >> go

isMountPoint :: FilePath -> IO Bool
isMountPoint path = do
  result <-
    try (readProcessWithExitCode "findmnt" ["-rn", "--mountpoint", path] "")
      :: IO (Either IOException (ExitCode, String, String))
  pure $ case result of
    Right (ExitSuccess, _, _) -> True
    _ -> False

cleanupFuseThread :: ThreadId -> FilePath -> IO ()
cleanupFuseThread threadId path = do
  _ <-
    try (readProcessWithExitCode "fusermount3" ["-u", path] "")
      :: IO (Either IOException (ExitCode, String, String))
  killThread threadId

unmountFuseWorkspace :: FuseMountHandle -> IO ()
unmountFuseWorkspace handle = do
  result <-
    try (readProcessWithExitCode "fusermount3" ["-u", fuseMountHostPath handle] "")
      :: IO (Either IOException (ExitCode, String, String))
  case result of
    Right (ExitSuccess, _, _) -> killThread (fuseMountThreadId handle)
    _ -> killThread (fuseMountThreadId handle)

fuseWorkspaceOperations :: Handle -> FuseOperations FilePath ()
fuseWorkspaceOperations = fuseWorkspaceOperationsWithReady Nothing

fuseWorkspaceOperationsWithReady
  :: Maybe (MVar (Either SomeException ()))
  -> Handle
  -> FuseOperations FilePath ()
fuseWorkspaceOperationsWithReady ready handle =
  defaultFuseOperations
    { fuseGetattr = Just (getattr handle)
    , fuseReadlink = Just (readlink handle)
    , fuseOpendir = Just (opendir handle)
    , fuseReaddir = Just (readdir handle)
    , fuseReleasedir = Just (\_ _ -> pure eOK)
    , fuseMkdir = Just (makeDirectory handle)
    , fuseRmdir = Just (removeDirectory handle)
    , fuseOpen = Just (openFile handle)
    , fuseCreate = Just (createFile handle)
    , fuseRead = Just (readFileAt handle)
    , fuseWrite = Just (writeFileAt handle)
    , fuseTruncate = Just (truncateFile handle)
    , fuseUnlink = Just (unlinkFile handle)
    , fuseRename = Just (renameFile handle)
    , fuseUtimens = Just (updateTimes handle)
    , fuseAccess = Just (accessPath handle)
    , fuseInit =
        Just
          ( \config -> traverse_ (\readyVar -> putMVar readyVar (Right ())) ready >> pure config
          )
    }

getattr
  :: Handle -> FilePath -> Maybe FilePath -> IO (Either Errno FileStat)
getattr handle path _ = do
  debugFuse ("getattr " <> path)
  storePath <- fusePathToStorePath path
  maybeRealPath <- Store.statPath handle storePath
  case maybeRealPath of
    Nothing -> pure (Left eNOENT)
    Just realPath -> Right <$> getFileStat realPath

readlink :: Handle -> FilePath -> IO (Either Errno FilePath)
readlink handle path = do
  debugFuse ("readlink " <> path)
  tryErrno $ do
    storePath <- fusePathToStorePath path
    Store.readSymbolicLink handle storePath

opendir :: Handle -> FilePath -> IO (Either Errno ())
opendir handle path = do
  debugFuse ("opendir " <> path)
  result <- tryErrno $ do
    storePath <- fusePathToStorePath path
    _ <- Store.listDirectory handle storePath
    pure ()
  pure (either Left (const (Right ())) result)

readdir
  :: Handle
  -> FilePath
  -> ()
  -> IO (Either Errno [(FilePath, Maybe FileStat)])
readdir handle path _ = do
  debugFuse ("readdir " <> path)
  result <- tryErrno $ do
    storePath <- fusePathToStorePath path
    entries <- Store.listDirectory handle storePath
    pure ((".", Nothing) : ("..", Nothing) : fmap (,Nothing) entries)
  pure result

openFile
  :: Handle
  -> FilePath
  -> OpenMode
  -> OpenFileFlags
  -> IO (Either Errno FilePath)
openFile handle path _ _ = do
  debugFuse ("open " <> path)
  storePath <- fusePathToStorePath path
  maybeRealPath <- Store.statPath handle storePath
  pure $
    case maybeRealPath of
      Nothing -> Left eNOENT
      Just _ -> Right storePath

createFile
  :: Handle
  -> FilePath
  -> OpenMode
  -> FileMode
  -> OpenFileFlags
  -> IO (Either Errno FilePath)
createFile handle path _ _ _ = do
  debugFuse ("create " <> path)
  result <- tryErrno $ do
    storePath <- fusePathToStorePath path
    Store.writeFile handle storePath ""
    pure storePath
  pure result

makeDirectory :: Handle -> FilePath -> FileMode -> IO Errno
makeDirectory handle path _ =
  debugFuse ("mkdir " <> path)
    >> either id (const eOK)
      <$> tryErrno
        ( do
            storePath <- fusePathToStorePath path
            Store.createDirectory handle storePath
        )

removeDirectory :: Handle -> FilePath -> IO Errno
removeDirectory handle path =
  debugFuse ("rmdir " <> path)
    >> either id (const eOK)
      <$> tryErrno
        ( do
            storePath <- fusePathToStorePath path
            Store.deletePath handle storePath
        )

updateTimes :: Handle -> FilePath -> Maybe FilePath -> a -> b -> IO Errno
updateTimes handle path _ _ _ =
  debugFuse ("utimens " <> path)
    >> either id (const eOK)
      <$> tryErrno
        ( do
            storePath <- fusePathToStorePath path
            Store.touchPath handle storePath
        )

readFileAt
  :: Handle
  -> FilePath
  -> FilePath
  -> ByteCount
  -> FileOffset
  -> IO (Either Errno ByteString.ByteString)
readFileAt handle path _ byteCount offset = do
  debugFuse ("read " <> path)
  result <- tryErrno $ do
    storePath <- fusePathToStorePath path
    content <- Store.readFile handle storePath
    pure
      ( ByteString.take
          (fromIntegral byteCount)
          (ByteString.drop (fromIntegral offset) content)
      )
  pure result

writeFileAt
  :: Handle
  -> FilePath
  -> FilePath
  -> ByteString.ByteString
  -> FileOffset
  -> IO (Either Errno CInt)
writeFileAt handle path _ content offset = do
  debugFuse ("write " <> path)
  result <- tryErrno $ do
    storePath <- fusePathToStorePath path
    Store.writeFileAt handle storePath (fromIntegral offset) content
    pure (fromIntegral (ByteString.length content))
  pure result

truncateFile
  :: Handle -> FilePath -> Maybe FilePath -> FileOffset -> IO Errno
truncateFile handle path _ size =
  debugFuse ("truncate " <> path)
    >> either id (const eOK)
      <$> tryErrno
        ( do
            storePath <- fusePathToStorePath path
            Store.truncateFile handle storePath (fromIntegral size)
        )

unlinkFile :: Handle -> FilePath -> IO Errno
unlinkFile handle path =
  debugFuse ("unlink " <> path)
    >> either id (const eOK)
      <$> tryErrno
        ( do
            storePath <- fusePathToStorePath path
            Store.deletePath handle storePath
        )

renameFile :: Handle -> FilePath -> FilePath -> IO Errno
renameFile handle fromPath toPath =
  debugFuse ("rename " <> fromPath <> " " <> toPath)
    >> either id (const eOK)
      <$> tryErrno
        ( do
            fromStorePath <- fusePathToStorePath fromPath
            toStorePath <- fusePathToStorePath toPath
            Store.renamePath handle fromStorePath toStorePath
        )

accessPath :: Handle -> FilePath -> mode -> IO Errno
accessPath handle path _ = do
  debugFuse ("access " <> path)
  storePath <- fusePathToStorePath path
  maybeRealPath <- Store.statPath handle storePath
  pure $
    case maybeRealPath of
      Nothing -> eACCES
      Just _ -> eOK

fusePathToStorePath :: FilePath -> IO FilePath
fusePathToStorePath path
  | any (== "..") components = pureError
  | normalized == "/" = pure "."
  | otherwise =
      case dropWhile (== '/') (dropDrive normalized) of
        "" -> pure "."
        relativePath -> pure relativePath
 where
  normalized = normalise path
  components = splitDirectories normalized
  pureError = ioError (userError ("unsafe FUSE path: " <> path))

tryErrno :: forall a. IO a -> IO (Either Errno a)
tryErrno action = do
  result <- try action :: IO (Either SomeException a)
  case result of
    Right value -> pure (Right value)
    Left err -> do
      debugFuse ("callback error: " <> show err)
      pure (Left eIO)

debugFuse :: String -> IO ()
debugFuse message = do
  enabled <- lookupEnv "SOG_FUSE_DEBUG"
  case enabled of
    Just "1" -> hPutStrLn stderr ("sog-fuse: " <> message) >> hFlush stderr
    _ -> pure ()
