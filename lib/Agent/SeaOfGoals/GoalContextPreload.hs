module Agent.SeaOfGoals.GoalContextPreload
  ( GoalContextPreloadConfig (..)
  , GoalContextPreloadPlan (..)
  , defaultGoalContextPreloadConfig
  , loadGoalContextPreloadConfigFromEnv
  , loadGoalContextPreloadPlanFromEnv
  , readGoalContextPreloadPlanFile
  , mergeGoalContextPreloadPlans
  , PreloadedGoalContext (..)
  , preloadGoalContext
  , preloadGoalContextDetailed
  , preloadGoalContextWithPlan
  , preloadGoalContextWithPlanDetailed
  , renderPreloadedGoalContext
  )
where

import Agent.SeaOfGoals.LLM
  ( LLMContentPart (TextPart)
  , LLMInputItem (MessageInput, ToolCallInput, ToolResultInput)
  , LLMMessage (..)
  , LLMRole (Assistant)
  , ToolCall (..)
  , ToolResult (..)
  )
import Control.Monad (forM)
import Data.Aeson
  ( FromJSON (..)
  , eitherDecode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAlphaNum)
import Data.List (isInfixOf, isSuffixOf, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Encoding.Error qualified as TextEncodingError
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , getFileSize
  , listDirectory
  )
import System.Environment (lookupEnv)
import System.FilePath
  ( normalise
  , splitDirectories
  , takeExtension
  , (</>)
  )

data GoalContextPreloadConfig = GoalContextPreloadConfig
  { goalContextPreloadEnabled :: Bool
  , goalContextPreloadMaxFiles :: Int
  , goalContextPreloadMaxBytesPerFile :: Integer
  , goalContextPreloadMaxDirectoryEntries :: Int
  }
  deriving stock (Eq, Show)

newtype GoalContextPreloadPlan = GoalContextPreloadPlan
  { goalContextPreloadPlanGoals :: Map Text [FilePath]
  }
  deriving stock (Eq, Show)

data PreloadedGoalContext = PreloadedGoalContext
  { preloadedGoalContextText :: Text
  , preloadedGoalContextHistory :: [LLMInputItem]
  , preloadedGoalContextReads :: Set FilePath
  }
  deriving stock (Eq, Show)

instance FromJSON GoalContextPreloadPlan where
  parseJSON =
    withObject "GoalContextPreloadPlan" $ \value ->
      GoalContextPreloadPlan <$> value .: "goals"

defaultGoalContextPreloadConfig :: GoalContextPreloadConfig
defaultGoalContextPreloadConfig =
  GoalContextPreloadConfig
    { goalContextPreloadEnabled = False
    , goalContextPreloadMaxFiles = 16
    , goalContextPreloadMaxBytesPerFile = 12000
    , goalContextPreloadMaxDirectoryEntries = 300
    }

loadGoalContextPreloadConfigFromEnv :: IO GoalContextPreloadConfig
loadGoalContextPreloadConfigFromEnv = do
  enabled <- boolEnv "SOG_PRELOAD_GOAL_CONTEXT"
  maxFiles <-
    intEnv
      "SOG_PRELOAD_MAX_FILES"
      (goalContextPreloadMaxFiles defaultGoalContextPreloadConfig)
  maxBytes <-
    integerEnv
      "SOG_PRELOAD_MAX_BYTES_PER_FILE"
      (goalContextPreloadMaxBytesPerFile defaultGoalContextPreloadConfig)
  maxDirectoryEntries <-
    intEnv
      "SOG_PRELOAD_MAX_DIRECTORY_ENTRIES"
      (goalContextPreloadMaxDirectoryEntries defaultGoalContextPreloadConfig)
  pure
    defaultGoalContextPreloadConfig
      { goalContextPreloadEnabled = enabled
      , goalContextPreloadMaxFiles = maxFiles
      , goalContextPreloadMaxBytesPerFile = maxBytes
      , goalContextPreloadMaxDirectoryEntries = maxDirectoryEntries
      }

loadGoalContextPreloadPlanFromEnv :: IO GoalContextPreloadPlan
loadGoalContextPreloadPlanFromEnv = do
  maybePath <- lookupEnv "SOG_PRELOAD_GOAL_CONTEXT_PLAN"
  case maybePath of
    Just path | not (null path) -> do
      either fail pure =<< readGoalContextPreloadPlanFile path
    _ -> pure (GoalContextPreloadPlan Map.empty)

readGoalContextPreloadPlanFile
  :: FilePath -> IO (Either String GoalContextPreloadPlan)
readGoalContextPreloadPlanFile path =
  eitherDecode <$> LazyByteString.readFile path

mergeGoalContextPreloadPlans
  :: GoalContextPreloadPlan -> GoalContextPreloadPlan -> GoalContextPreloadPlan
mergeGoalContextPreloadPlans
  (GoalContextPreloadPlan left)
  (GoalContextPreloadPlan right) =
    GoalContextPreloadPlan (Map.unionWith mergeFiles left right)
   where
    mergeFiles existing incoming =
      Set.toList (Set.fromList existing <> Set.fromList incoming)

preloadGoalContext :: GoalContextPreloadConfig -> FilePath -> Text -> IO Text
preloadGoalContext config workspaceRoot prompt =
  preloadedGoalContextText
    <$> preloadGoalContextDetailed config workspaceRoot prompt

preloadGoalContextDetailed
  :: GoalContextPreloadConfig -> FilePath -> Text -> IO PreloadedGoalContext
preloadGoalContextDetailed config =
  preloadGoalContextWithPlanDetailed config Nothing

preloadGoalContextWithPlan
  :: GoalContextPreloadConfig -> Maybe [FilePath] -> FilePath -> Text -> IO Text
preloadGoalContextWithPlan config maybePlannedFiles workspaceRoot prompt =
  preloadedGoalContextText
    <$> preloadGoalContextWithPlanDetailed config maybePlannedFiles workspaceRoot prompt

preloadGoalContextWithPlanDetailed
  :: GoalContextPreloadConfig
  -> Maybe [FilePath]
  -> FilePath
  -> Text
  -> IO PreloadedGoalContext
preloadGoalContextWithPlanDetailed config maybePlannedFiles workspaceRoot prompt
  | not (goalContextPreloadEnabled config) =
      pure
        PreloadedGoalContext
          { preloadedGoalContextText = ""
          , preloadedGoalContextHistory = []
          , preloadedGoalContextReads = Set.empty
          }
  | otherwise = do
      files <- listWorkspaceFiles workspaceRoot
      let selected =
            take
              (goalContextPreloadMaxFiles config)
              (selectGoalFiles maybePlannedFiles prompt files)
      renderedFiles <- mapM (renderFile workspaceRoot config) selected
      pure
        PreloadedGoalContext
          { preloadedGoalContextText =
              renderPreloadedGoalContext config files selected renderedFiles
          , preloadedGoalContextHistory =
              renderPreloadedGoalContextHistory config files selected renderedFiles
          , preloadedGoalContextReads = Set.fromList selected
          }

renderPreloadedGoalContext
  :: GoalContextPreloadConfig
  -> [FilePath]
  -> [FilePath]
  -> [(FilePath, Text)]
  -> Text
renderPreloadedGoalContext config files selected renderedFiles =
  Text.unlines
    [ "<preloaded_workspace_context>"
    , "The harness already performed the initial workspace exploration for this goal."
    , "Prefer this context over re-reading the same files. Read additional files only if required to make or verify the change."
    , ""
    , "Workspace file listing, truncated:"
    , Text.unlines
        ( fmap
            (("- " <>) . Text.pack)
            (take (goalContextPreloadMaxDirectoryEntries config) (sort files))
        )
    , ""
    , "Selected files preloaded for this goal:"
    , Text.unlines (fmap (("- " <>) . Text.pack) selected)
    , ""
    , "Preloaded file contents:"
    , Text.intercalate "\n" (fmap renderPreloadedFile renderedFiles)
    , "</preloaded_workspace_context>"
    ]

renderPreloadedFile :: (FilePath, Text) -> Text
renderPreloadedFile (relativePath, content) =
  Text.unlines
    [ "BEGIN FILE " <> Text.pack relativePath
    , content
    , "END FILE " <> Text.pack relativePath
    ]

renderPreloadedGoalContextHistory
  :: GoalContextPreloadConfig
  -> [FilePath]
  -> [FilePath]
  -> [(FilePath, Text)]
  -> [LLMInputItem]
renderPreloadedGoalContextHistory config files selected renderedFiles
  | null selected =
      [ MessageInput
          LLMMessage
            { messageRole = Assistant
            , messageContent =
                [ TextPart
                    "I have completed the initial workspace exploration for this goal. The workspace has no selected preloaded files, so I will continue from the file listing already observed."
                ]
            }
      ]
  | otherwise =
      [ ToolCallInput listingCall
      , ToolResultInput listingResult
      , ToolCallInput filesCall
      , ToolResultInput filesResult
      , MessageInput
          LLMMessage
            { messageRole = Assistant
            , messageContent =
                [ TextPart
                    "I have completed the initial workspace exploration for this goal. I will use the observed file listing and preloaded file contents before deciding whether any extra reads are necessary."
                ]
            }
      ]
 where
  listingCall =
    ToolCall
      { toolCallId = "sog_preload_listing"
      , toolCallName = "shell"
      , toolCallArguments =
          object
            [ "command"
                .= ( "find . -type f | sed 's#^./##' | sort | head -n "
                       <> show (goalContextPreloadMaxDirectoryEntries config)
                   )
            ]
      }
  listingResult =
    ToolResult
      { toolResultCallId = toolCallId listingCall
      , toolResultName = Just (toolCallName listingCall)
      , toolResultContent =
          [ TextPart
              ( Text.unlines
                  [ "exit_code: 0"
                  , "timed_out: false"
                  , "stdout:"
                  , Text.unlines
                      ( fmap
                          Text.pack
                          (take (goalContextPreloadMaxDirectoryEntries config) (sort files))
                      )
                  , "stderr:"
                  ]
              )
          ]
      }
  filesCall =
    ToolCall
      { toolCallId = "sog_preload_files"
      , toolCallName = "shell"
      , toolCallArguments =
          object
            [ "command"
                .= Text.intercalate
                  " && "
                  (fmap catCommand selected)
            ]
      }
  filesResult =
    ToolResult
      { toolResultCallId = toolCallId filesCall
      , toolResultName = Just (toolCallName filesCall)
      , toolResultContent =
          [ TextPart
              ( Text.unlines
                  [ "exit_code: 0"
                  , "timed_out: false"
                  , "stdout:"
                  , Text.intercalate "\n" (fmap renderPreloadedFile renderedFiles)
                  , "stderr:"
                  ]
              )
          ]
      }
  catCommand relativePath =
    "printf '%s\\n' "
      <> shellSingleQuote ("BEGIN FILE " <> Text.pack relativePath)
      <> " && cat "
      <> shellSingleQuote (Text.pack relativePath)
      <> " && printf '%s\\n' "
      <> shellSingleQuote ("END FILE " <> Text.pack relativePath)

shellSingleQuote :: Text -> Text
shellSingleQuote text =
  "'" <> Text.replace "'" "'\"'\"'" text <> "'"

selectGoalFiles :: Maybe [FilePath] -> Text -> [FilePath] -> [FilePath]
selectGoalFiles maybePlannedFiles prompt files =
  sort
    [ file
    | file <- files
    , isLikelyTextSource file
    , maybe (fileMatchesPrompt prompt file) (Set.member file) planned
    ]
 where
  planned = Set.fromList . fmap normalise <$> maybePlannedFiles

fileMatchesPrompt :: Text -> FilePath -> Bool
fileMatchesPrompt prompt file =
  any (`Text.isInfixOf` promptLower) candidates
    || any (`isInfixOf` fileLower) promptTokens
 where
  promptLower = Text.toLower prompt
  fileLower = fmap lowerAscii file
  parts = splitDirectories (normalise file)
  base = case reverse parts of
    name : _ -> name
    [] -> file
  candidates =
    fmap
      (Text.toLower . Text.pack)
      (filter (not . null) [file, base, dropExtensionLike base])
  promptTokens =
    filter
      (\token -> length token >= 4)
      (Text.unpack <$> Text.words (Text.map tokenChar promptLower))

renderFile
  :: FilePath -> GoalContextPreloadConfig -> FilePath -> IO (FilePath, Text)
renderFile workspaceRoot config relativePath = do
  let path = workspaceRoot </> relativePath
  size <- getFileSize path
  if size > goalContextPreloadMaxBytesPerFile config
    then
      pure
        ( relativePath
        , Text.pack
            ( "[omitted: file is "
                <> show size
                <> " bytes, above SOG_PRELOAD_MAX_BYTES_PER_FILE]"
            )
        )
    else do
      bytes <- ByteString.readFile path
      pure
        ( relativePath
        , TextEncoding.decodeUtf8With TextEncodingError.lenientDecode bytes
        )

listWorkspaceFiles :: FilePath -> IO [FilePath]
listWorkspaceFiles root = go ""
 where
  go relativeDir = do
    let absoluteDir = root </> relativeDir
    exists <- doesDirectoryExist absoluteDir
    if not exists
      then pure []
      else do
        names <- listDirectory absoluteDir
        fmap concat $
          forM (filter (not . isIgnoredEntry relativeDir) names) $ \name -> do
            let
              relativePath =
                if null relativeDir
                  then name
                  else relativeDir </> name
              absolutePath = root </> relativePath
            isDirectory <- doesDirectoryExist absolutePath
            if isDirectory
              then go relativePath
              else do
                isFile <- doesFileExist absolutePath
                pure [normalise relativePath | isFile]

isIgnoredEntry :: FilePath -> FilePath -> Bool
isIgnoredEntry relativeDir name =
  any (`Set.member` ignoredPathParts) (splitDirectories (relativeDir </> name))
    || name == "sog-trace.jsonl"
 where
  ignoredPathParts =
    Set.fromList
      [ ".git"
      , ".sog"
      , ".sog-control"
      , "node_modules"
      , "dist"
      , "build"
      , ".next"
      ]

isLikelyTextSource :: FilePath -> Bool
isLikelyTextSource path =
  takeExtension path
    `elem` [ ".cabal"
           , ".css"
           , ".go"
           , ".hs"
           , ".html"
           , ".java"
           , ".js"
           , ".json"
           , ".jsx"
           , ".md"
           , ".py"
           , ".rs"
           , ".sql"
           , ".toml"
           , ".ts"
           , ".tsx"
           , ".txt"
           , ".vue"
           , ".xml"
           , ".yaml"
           , ".yml"
           ]
    || any (`isSuffixOf` path) ["Dockerfile", "Makefile"]

dropExtensionLike :: FilePath -> FilePath
dropExtensionLike name =
  case break (== '.') name of
    (stem, _ : _) -> stem
    _ -> name

tokenChar :: Char -> Char
tokenChar c
  | isAlphaNum c = c
  | otherwise = ' '

lowerAscii :: Char -> Char
lowerAscii c
  | 'A' <= c && c <= 'Z' = toEnum (fromEnum c + 32)
  | otherwise = c

boolEnv :: String -> IO Bool
boolEnv name = do
  value <- lookupEnv name
  pure $
    case Text.toLower . Text.pack <$> value of
      Just "1" -> True
      Just "true" -> True
      Just "yes" -> True
      Just "on" -> True
      _ -> False

intEnv :: String -> Int -> IO Int
intEnv name fallback = do
  value <- lookupEnv name
  pure (maybe fallback id (value >>= readMaybe))

integerEnv :: String -> Integer -> IO Integer
integerEnv name fallback = do
  value <- lookupEnv name
  pure (maybe fallback id (value >>= readMaybe))

readMaybe :: Read value => String -> Maybe value
readMaybe text =
  case reads text of
    [(value, "")] -> Just value
    _ -> Nothing
