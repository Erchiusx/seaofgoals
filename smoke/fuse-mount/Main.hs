module Main (main) where

import Agent.SeaOfGoals.Workspace.Backend
  ( Backend (..)
  , Diff (..)
  , Mount (..)
  , PathChange (..)
  )
import Agent.SeaOfGoals.Workspace.Fuse.Mount
  ( mountFuseWorkspace
  , unmountFuseWorkspace
  )
import Agent.SeaOfGoals.Workspace.Fuse.Store qualified as Store
import Control.Exception
  ( SomeException
  , bracket
  , try
  )
import Data.ByteString qualified as ByteString
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getTemporaryDirectory
  , removePathForcibly
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO
  ( BufferMode (LineBuffering)
  , hSetBuffering
  , stdout
  )
import System.Process (readProcessWithExitCode)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  tempRoot <- getTemporaryDirectory
  let
    root = tempRoot </> "sog-fuse-mount-smoke"
    base = root </> "base"
    store = root </> "store"
    taskMount = store </> "mount-smoke" </> "mount"
    backend = Store.Backend store

  _ <- readProcessWithExitCode "fusermount3" ["-u", taskMount] ""
  removePathForcibly root
  createDirectoryIfMissing True (base </> "src")
  ByteString.writeFile (base </> "src" </> "Main.hs") "main = putStrLn \"old\"\n"
  ByteString.writeFile (base </> "src" </> "Obsolete.hs") "obsolete\n"
  ByteString.writeFile (base </> "src" </> "Untouched.hs") "untouched\n"

  handle <-
    prepareWorkspace
      backend
      Store.Spec
        { specTaskId = "mount-smoke"
        , specBasePath = base
        , specAgentMountPath = "/workspace"
        }
  let
    mountValue = mount backend handle
    mountPath = mountHostPath mountValue

  putStrLn ("mounting FUSE workspace at " <> mountPath)
  result <-
    try $
      bracket
        (mountFuseWorkspace handle mountValue)
        unmountFuseWorkspace
        (const (mountedAssertions backend handle base store mountPath))
  case result of
    Right () -> putStrLn "FUSE kernel mount smoke test passed."
    Left err ->
      fail ("FUSE kernel mount smoke test failed: " <> show (err :: SomeException))

mountedAssertions
  :: Store.Backend
  -> Store.Handle
  -> FilePath
  -> FilePath
  -> FilePath
  -> IO ()
mountedAssertions backend handle base store mountPath = do
  putStrLn "checking untouched mtime passthrough"
  baseUntouchedMTime <- statMTime (base </> "src" </> "Untouched.hs")
  mountedUntouchedMTime <- statMTime (mountPath </> "src" </> "Untouched.hs")
  assertEqual
    "mounted workspace preserves timestamp for untouched file"
    baseUntouchedMTime
    mountedUntouchedMTime

  putStrLn "checking read-through from base"
  assertEqual
    "mounted workspace reads base file"
    "main = putStrLn \"old\"\n"
    =<< readCommand "cat" [mountPath </> "src" </> "Main.hs"] ""

  putStrLn "checking writes and unlink through kernel mount"
  runCommand "tee" [mountPath </> "README.md"] "hello\n"
  runCommand "tee" [mountPath </> "src" </> "Main.hs"] "main = putStrLn \"new\"\n"
  runCommand "rm" [mountPath </> "src" </> "Obsolete.hs"] ""

  assertEqual
    "mounted workspace write does not mutate base"
    "main = putStrLn \"old\"\n"
    =<< ByteString.readFile (base </> "src" </> "Main.hs")

  localCreated <-
    doesFileExist (store </> "mount-smoke" </> "files" </> "README.md")
  assertBool "mounted workspace stores created file locally" localCreated

  finalized <- finalizeWorkspace backend handle
  case finalized of
    Left conflicts -> fail ("expected no workspace conflicts, got " <> show conflicts)
    Right snapshot ->
      assertEqual
        "mounted workspace diff records writes and deletion"
        [ PathCreated "README.md"
        , PathModified ("src" </> "Main.hs")
        , PathDeleted ("src" </> "Obsolete.hs")
        ]
        (diffChanges (Store.snapshotDiff snapshot))

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

statMTime :: FilePath -> IO String
statMTime path = readCommand "stat" ["-c", "%Y", path] ""

runCommand :: FilePath -> [String] -> String -> IO ()
runCommand command args input = do
  (exitCode, _stdoutText, stderrText) <-
    readProcessWithExitCode command args input
  case exitCode of
    ExitSuccess -> pure ()
    ExitFailure code -> fail (command <> " failed with exit " <> show code <> ": " <> stderrText)

readCommand :: FilePath -> [String] -> String -> IO String
readCommand command args input = do
  (exitCode, stdoutText, stderrText) <- readProcessWithExitCode command args input
  case exitCode of
    ExitSuccess -> pure stdoutText
    ExitFailure code -> fail (command <> " failed with exit " <> show code <> ": " <> stderrText)
