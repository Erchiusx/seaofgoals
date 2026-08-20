module Agent.SeaOfGoals.Config
  ( ConcurrentChaseConfig (..)
  , Config (..)
  , defaultConcurrentChaseConfig
  , defaultConfig
  , loadConfigFile
  , loadConfigFromEnv
  )
where

import Data.Aeson
  ( FromJSON (..)
  , eitherDecode
  , withObject
  , (.!=)
  , (.:?)
  )
import Data.ByteString.Lazy qualified as LazyByteString
import System.Directory
  ( doesFileExist
  )
import System.Environment
  ( lookupEnv
  )

data ConcurrentChaseConfig = ConcurrentChaseConfig
  { concurrentChaseConfigMaxParallelism :: Int
  , concurrentChaseConfigMaxReplans :: Int
  }
  deriving stock (Eq, Show)

data Config = Config
  { configConcurrentChase :: ConcurrentChaseConfig
  }
  deriving stock (Eq, Show)

defaultConcurrentChaseConfig :: ConcurrentChaseConfig
defaultConcurrentChaseConfig =
  ConcurrentChaseConfig
    { concurrentChaseConfigMaxParallelism = 4
    , concurrentChaseConfigMaxReplans = 4
    }

defaultConfig :: Config
defaultConfig =
  Config
    { configConcurrentChase = defaultConcurrentChaseConfig
    }

instance FromJSON ConcurrentChaseConfig where
  parseJSON =
    withObject "ConcurrentChaseConfig" $ \value ->
      ConcurrentChaseConfig
        <$> value
          .:? "maxParallelism"
          .!= concurrentChaseConfigMaxParallelism defaultConcurrentChaseConfig
        <*> value
          .:? "maxReplans"
          .!= concurrentChaseConfigMaxReplans defaultConcurrentChaseConfig

instance FromJSON Config where
  parseJSON =
    withObject "Config" $ \value ->
      Config
        <$> value .:? "concurrentChase" .!= configConcurrentChase defaultConfig

loadConfigFromEnv :: IO Config
loadConfigFromEnv = do
  maybePath <- lookupEnv "SOG_CONFIG"
  case maybePath of
    Just path | not (null path) -> loadConfigFile path
    _ -> do
      defaultPathExists <- doesFileExist defaultConfigPath
      if defaultPathExists
        then loadConfigFile defaultConfigPath
        else pure defaultConfig

loadConfigFile :: FilePath -> IO Config
loadConfigFile path = do
  decoded <- eitherDecode <$> LazyByteString.readFile path
  case decoded of
    Left err -> fail ("could not parse SeaOfGoals config: " <> err)
    Right config -> pure config

defaultConfigPath :: FilePath
defaultConfigPath = "seaofgoals.config.json"
