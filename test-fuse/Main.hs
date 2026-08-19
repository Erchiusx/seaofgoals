module Main (main) where

import Agent.SeaOfGoals.Workspace.Backend
  ( Backend (..)
  , Diff (..)
  , PathChange (..)
  )
import Agent.SeaOfGoals.Workspace.Fuse.Mount
  ( fuseWorkspaceOperations
  )
import Agent.SeaOfGoals.Workspace.Fuse.Store qualified as Store
import Data.ByteString qualified as ByteString
import Foreign.C.Error (eOK)
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getTemporaryDirectory
  , removePathForcibly
  )
import System.FilePath ((</>))
import System.LibFuse3
  ( FileStat (..)
  , FuseOperations (..)
  , getFileStat
  )

main :: IO ()
main = do
  tempRoot <- getTemporaryDirectory
  let
    root = tempRoot </> "sog-fuse-callback-test"
    base = root </> "base"
    store = root </> "store"
    backend = Store.Backend store
  removePathForcibly root
  createDirectoryIfMissing True (base </> "src")
  ByteString.writeFile (base </> "src" </> "Main.hs") "main = putStrLn \"old\"\n"
  ByteString.writeFile (base </> "src" </> "Obsolete.hs") "obsolete\n"
  ByteString.writeFile (base </> "src" </> "Untouched.hs") "untouched\n"

  handle <-
    prepareWorkspace
      backend
      Store.Spec
        { specTaskId = "callback-test"
        , specBasePath = base
        , specAgentMountPath = "/workspace"
        }
  let operations = fuseWorkspaceOperations handle

  readFromFuse operations "/src/Main.hs"
    `assertIOEqual` "main = putStrLn \"old\"\n"
  assertUntouchedTimestamp
    operations
    (base </> "src" </> "Untouched.hs")
    "/src/Untouched.hs"

  writeThroughFuse operations "/README.md" "hello\n"
  writeThroughFuse operations "/src/Main.hs" "main = putStrLn \"new\"\n"
  unlinkThroughFuse operations "/src/Obsolete.hs"

  ByteString.readFile (base </> "src" </> "Main.hs")
    `assertIOEqual` "main = putStrLn \"old\"\n"
  localCreated <-
    doesFileExist (store </> "callback-test" </> "files" </> "README.md")
  assertBool "FUSE callbacks store created file locally" localCreated

  finalized <- finalizeWorkspace backend handle
  case finalized of
    Left conflicts -> fail ("expected no workspace conflicts, got " <> show conflicts)
    Right snapshot ->
      assertEqual
        "FUSE callbacks record writes and deletion"
        [ PathCreated "README.md"
        , PathModified ("src" </> "Main.hs")
        , PathDeleted ("src" </> "Obsolete.hs")
        ]
        (diffChanges (Store.snapshotDiff snapshot))

  putStrLn "FUSE callback workspace test passed."

assertUntouchedTimestamp
  :: FuseOperations FilePath () -> FilePath -> FilePath -> IO ()
assertUntouchedTimestamp operations basePath fusePath = do
  baseStat <- getFileStat basePath
  callbackStat <- callGetattr operations fusePath
  assertEqual
    "FUSE getattr preserves timestamp for untouched file"
    (modificationTimeHiRes baseStat)
    (modificationTimeHiRes callbackStat)

readFromFuse
  :: FuseOperations FilePath () -> FilePath -> IO ByteString.ByteString
readFromFuse operations path =
  case fuseRead operations of
    Nothing -> fail "fuseRead callback is not installed"
    Just callback -> do
      result <- callback path path 4096 0
      either (const (fail ("FUSE read failed: " <> path))) pure result

writeThroughFuse
  :: FuseOperations FilePath () -> FilePath -> ByteString.ByteString -> IO ()
writeThroughFuse operations path content =
  case fuseWrite operations of
    Nothing -> fail "fuseWrite callback is not installed"
    Just callback -> do
      result <- callback path path content 0
      written <- either (const (fail ("FUSE write failed: " <> path))) pure result
      assertEqual
        "FUSE write byte count"
        (ByteString.length content)
        (fromIntegral written)

unlinkThroughFuse :: FuseOperations FilePath () -> FilePath -> IO ()
unlinkThroughFuse operations path =
  case fuseUnlink operations of
    Nothing -> fail "fuseUnlink callback is not installed"
    Just callback -> do
      errno <- callback path
      if errno == eOK
        then pure ()
        else fail ("FUSE unlink failed: " <> path)

callGetattr :: FuseOperations FilePath () -> FilePath -> IO FileStat
callGetattr operations path =
  case fuseGetattr operations of
    Nothing -> fail "fuseGetattr callback is not installed"
    Just callback -> do
      result <- callback path Nothing
      either (const (fail ("FUSE getattr failed: " <> path))) pure result

assertIOEqual :: (Eq a, Show a) => IO a -> a -> IO ()
assertIOEqual actualAction expected = do
  actual <- actualAction
  assertEqual "IO value" expected actual

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
  if expected == actual
    then pure ()
    else fail (label <> ": expected " <> show expected <> ", got " <> show actual)

assertBool :: String -> Bool -> IO ()
assertBool label condition =
  if condition
    then pure ()
    else fail label
