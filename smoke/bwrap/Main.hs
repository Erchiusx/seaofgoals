module Main (main) where

import Agent.SeaOfGoals.Workspace.Bwrap.Command
  ( Config (..)
  )
import Agent.SeaOfGoals.Workspace.Bwrap.Profile
  ( DemoPaths (..)
  , demoWorkspaceOnlyView
  )
import Agent.SeaOfGoals.Workspace.Sandbox
  ( ExecSpec (..)
  , ExecTimeout (..)
  , SandboxExecOutcome (..)
  , SandboxRunner (..)
  )
import Agent.SeaOfGoals.Workspace.Sandbox.Bwrap
  ( BwrapSandboxRunner (..)
  , BwrapSandboxSpec (..)
  )
import Control.Exception
  ( SomeException
  , bracket
  , try
  )
import Data.ByteString qualified as ByteString
import Data.Foldable
  ( traverse_
  )
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getTemporaryDirectory
  , removePathForcibly
  )
import System.Environment
  ( lookupEnv
  )
import System.FilePath
  ( (</>)
  )
import System.IO
  ( BufferMode (LineBuffering)
  , hSetBuffering
  , stdout
  )

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  tempRoot <- getTemporaryDirectory
  bwrap <- maybe "bwrap" id <$> lookupEnv "SOG_BWRAP"
  let
    root = tempRoot </> "sog-bwrap-smoke"
    workspace = root </> "workspace"
    cache = root </> "cache"
    home = root </> "home"
    tmp = root </> "tmp"
  removePathForcibly root
  traverse_ (createDirectoryIfMissing True) [workspace, cache, home, tmp]

  let
    runner = BwrapSandboxRunner (Config bwrap)
    view =
      demoWorkspaceOnlyView
        DemoPaths
          { demoWorkspaceHostPath = workspace
          , demoCacheHostPath = cache
          , demoHomeHostPath = home
          , demoTmpHostPath = tmp
          }
    spec =
      BwrapSandboxSpec
        { bwrapSandboxId = "bwrap-smoke"
        , bwrapSandboxView = view
        }

  putStrLn ("starting bwrap smoke with " <> bwrap)
  result <-
    try $
      bracket
        (createSandbox runner spec)
        (destroySandbox runner)
        ( \handle -> do
            outcome <-
              execInSandbox
                runner
                handle
                ExecSpec
                  { execArgv =
                      [ "sh"
                      , "-c"
                      , Text.unlines
                          [ "set -eu"
                          , "test \"$(pwd)\" = /workspace"
                          , "test \"$HOME\" = /home/sog"
                          , "test \"$XDG_CACHE_HOME\" = /cache/xdg"
                          , "test \"$CABAL_STORE_DIR\" = /workspace/.sog/cabal-store"
                          , "mkdir -p /workspace/.sog/cabal-store /cache/probe \"$HOME\""
                          , "echo workspace > /workspace/out.txt"
                          , "echo cache > /cache/out.txt"
                          , "echo home > \"$HOME/out.txt\""
                          , "if sh -c 'echo denied > /usr/sog-bwrap-denied' 2>/tmp/deny.err; then exit 42; fi"
                          , "cat /workspace/out.txt /cache/out.txt \"$HOME/out.txt\""
                          ]
                      ]
                  , execCwd = "."
                  , execEnv = [("FOO", "bar")]
                  , execTimeout = ExecTimeoutSeconds 15
                  }
            assertSuccessful outcome
            assertEqual
              "bwrap smoke writes through /workspace mount"
              "workspace\n"
              =<< ByteString.readFile (workspace </> "out.txt")
            assertEqual
              "bwrap smoke writes through /cache mount"
              "cache\n"
              =<< ByteString.readFile (cache </> "out.txt")
            assertEqual
              "bwrap smoke writes through synthetic home"
              "home\n"
              =<< ByteString.readFile (home </> "out.txt")
            deniedLeak <- doesFileExist "/usr/sog-bwrap-denied"
            assertBool "bwrap smoke did not write to host /usr" (not deniedLeak)
        )
  case result of
    Right () -> putStrLn "bwrap smoke test passed."
    Left err -> fail ("bwrap smoke test failed: " <> show (err :: SomeException))

assertSuccessful :: SandboxExecOutcome -> IO ()
assertSuccessful outcome =
  if sandboxExecExitCode outcome == 0
    then pure ()
    else
      fail
        ( "bwrap exec failed with exit "
            <> show (sandboxExecExitCode outcome)
            <> "\nstdout:\n"
            <> Text.unpack (decodeUtf8 (sandboxExecStdout outcome))
            <> "\nstderr:\n"
            <> Text.unpack (decodeUtf8 (sandboxExecStderr outcome))
        )

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  if expected == actual
    then pure ()
    else fail (label <> ": expected " <> show expected <> ", got " <> show actual)

assertBool :: String -> Bool -> IO ()
assertBool label condition =
  if condition
    then pure ()
    else fail label

decodeUtf8 :: ByteString.ByteString -> Text.Text
decodeUtf8 = TextEncoding.decodeUtf8
