module Main (main) where

import Agent.SeaOfGoals.Workspace.Containerd.Command
  ( Config (..)
  , Mount (..)
  , Root (..)
  )
import Agent.SeaOfGoals.Workspace.Sandbox
  ( BindMode (..)
  , ExecSpec (..)
  , ExecTimeout (..)
  , SandboxExecOutcome (..)
  , SandboxRunner (..)
  )
import Agent.SeaOfGoals.Workspace.Sandbox.Containerd
  ( ContainerdSandboxRunner (..)
  , ContainerdSandboxSpec (..)
  )
import Control.Exception
  ( SomeException
  , bracket
  , try
  )
import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import System.Directory
  ( createDirectoryIfMissing
  , getTemporaryDirectory
  , removePathForcibly
  )
import System.Environment
  ( lookupEnv
  )
import System.FilePath ((</>))
import System.IO
  ( BufferMode (LineBuffering)
  , hSetBuffering
  , stdout
  )

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  tempRoot <- getTemporaryDirectory
  let
    root = tempRoot </> "sog-containerd-smoke"
    workspace = root </> "workspace"
  removePathForcibly root
  createDirectoryIfMissing True workspace

  image <-
    maybe "docker.io/library/alpine:latest" Text.pack
      <$> lookupEnv "SOG_CONTAINERD_IMAGE"
  rootfs <- lookupEnv "SOG_CONTAINERD_ROOTFS"
  namespace <- fmap Text.pack <$> lookupEnv "SOG_CONTAINERD_NAMESPACE"
  address <- lookupEnv "CONTAINERD_ADDRESS"
  snapshotter <- fmap Text.pack <$> lookupEnv "CONTAINERD_SNAPSHOTTER"
  let
    config =
      Config
        { configBinary = "ctr"
        , configNamespace = namespace
        , configAddress = address
        , configSnapshotter = snapshotter
        }
    runner = ContainerdSandboxRunner config
    containerRoot =
      case rootfs of
        Just path -> Rootfs path
        Nothing -> Image image
    spec =
      ContainerdSandboxSpec
        { containerdSandboxId = "containerd-smoke"
        , containerdSandboxRoot = containerRoot
        , containerdSandboxMounts =
            [ Mount
                { mountHostPath = workspace
                , mountContainerPath = "/workspace"
                , mountMode = BindReadWrite
                }
            ]
        , containerdSandboxInitArgv = []
        }

  putStrLn
    ("starting containerd smoke container from " <> rootDescription containerRoot)
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
                      , "test \"$(pwd)\" = /workspace && echo smoke > /workspace/out.txt && cat /workspace/out.txt"
                      ]
                  , execCwd = "."
                  , execEnv = []
                  , execTimeout = ExecTimeoutSeconds 15
                  }
            assertSuccessful outcome
            assertEqual
              "containerd smoke writes through /workspace mount"
              "smoke\n"
              =<< ByteString.readFile (workspace </> "out.txt")
        )
  case result of
    Right () -> putStrLn "containerd smoke test passed."
    Left err -> fail ("containerd smoke test failed: " <> show (err :: SomeException))

assertSuccessful :: SandboxExecOutcome -> IO ()
assertSuccessful outcome =
  if sandboxExecExitCode outcome == 0
    then pure ()
    else
      fail
        ( "containerd exec failed with exit "
            <> show (sandboxExecExitCode outcome)
            <> "\nstdout:\n"
            <> Text.unpack (decodeUtf8 (sandboxExecStdout outcome))
            <> "\nstderr:\n"
            <> Text.unpack (decodeUtf8 (sandboxExecStderr outcome))
        )

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
  if expected == actual
    then pure ()
    else fail (label <> ": expected " <> show expected <> ", got " <> show actual)

decodeUtf8 :: ByteString.ByteString -> Text.Text
decodeUtf8 = TextEncoding.decodeUtf8

rootDescription :: Root -> String
rootDescription (Image image) = Text.unpack image
rootDescription (Rootfs path) = path
