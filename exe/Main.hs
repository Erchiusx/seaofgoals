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
import Data.Data (TypeRep)
import Data.Dynamic (Dynamic)
import Data.Map (Map)
import Data.Text qualified as Text
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

globals :: Map String (Dynamic, TypeRep)
globals = undefined
