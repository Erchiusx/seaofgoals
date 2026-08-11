module Main where

import Agent.SeaOfGoals.LLM
  ( LLM (runLLM)
  , LLMContentPart (..)
  , LLMInputItem (MessageInput)
  , LLMMessage (..)
  , LLMRequest (..)
  , LLMResponse (..)
  , LLMRole (..)
  , ResponseFormat (..)
  )
import Agent.SeaOfGoals.LLM.Backends.GPT
  ( GPTBackend (..)
  , defaultGPTEndpoint
  )
import Control.Monad (forM_)
import Data.Char (toUpper)
import Data.Dynamic (Dynamic, toDyn)
import Data.IORef (modifyIORef')
import Data.Map (Map, empty, insert)
import Data.Text qualified as Text
import GHC.IO (unsafePerformIO)
import GHC.IORef (IORef, newIORef)
import System.Environment (lookupEnv)

main :: IO ()
main = do
  apiKey <- lookupEnv "OPENAI_API_KEY"
  case apiKey of
    Nothing ->
      putStrLn "OPENAI_API_KEY is not set."
    Just key -> do
      let backend =
            GPTBackend
              { gptApiKey = key
              , gptEndpoint = defaultGPTEndpoint
              }
      let requestTemplate =
            LLMRequest
              { requestModel = "gpt-4o-mini"
              , requestInput = []
              , requestTemperature = Just 0.2
              , requestMaxTokens = Just 64
              , requestStopSequences = []
              , requestResponseFormat = PlainText
              , requestTools = []
              , requestConfig = Nothing
              }
      result <-
        runLLM
          backend
          requestTemplate
            { requestInput =
                [ MessageInput
                    LLMMessage
                      { messageRole = User
                      , messageContent = [TextPart "Say hello from SeaOfGoals in one short sentence."]
                      }
                ]
            }
      case result of
        Left err -> print err
        Right response ->
          putStrLn (Text.unpack (messageText (responseMessage response)))

messageText :: LLMMessage -> Text.Text
messageText message =
  foldMap contentPartText (messageContent message)

contentPartText :: LLMContentPart -> Text.Text
contentPartText (TextPart text) = text
contentPartText (ImagePart _) = "[image]"
contentPartText (FilePart _) = "[file]"
contentPartText (AudioPart _) = "[audio]"

{-# NOINLINE globals #-}
globals :: IORef (Map String Dynamic)
globals = unsafePerformIO $ newIORef empty

initConfig :: IO ()
initConfig =
  forM_ ["Key", "Type", "EndPoint"] $ \arg -> do
    modifyIORef' globals
      . insert ("api" <> arg)
      . toDyn
      =<< lookupEnv ("SOG_API_" <> map toUpper arg)

