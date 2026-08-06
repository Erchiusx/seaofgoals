module Agent.SeaOfGoals.LLM.Backends.GPT
  ( GPTBackend (..)
  , defaultGPTEndpoint
  )
where

import Agent.LLM.Transport
  ( TransportRequest (..)
  , TransportResponse (..)
  , sendJSON
  )
import Agent.SeaOfGoals.LLM
  ( LLM (..)
  , ArtifactRef (..)
  , AudioRef (..)
  , FileRef (..)
  , ImageDetail (..)
  , ImageRef (..)
  , LLMContentPart (..)
  , LLMError (..)
  , LLMInputItem (..)
  , LLMMessage (..)
  , LLMRequest (..)
  , LLMResponse (..)
  , LLMRole (..)
  , LLMUsage
  , ResponseFormat (..)
  , ToolCall (..)
  , ToolResult (..)
  )
import Data.Aeson
  ( FromJSON (..)
  , Value
  , decode
  , object
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.Types (Pair)
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Maybe (catMaybes)
import Data.Text (Text)

data GPTBackend = GPTBackend
  { gptApiKey :: String
  , gptEndpoint :: String
  }
  deriving stock (Eq, Show)

defaultGPTEndpoint :: String
defaultGPTEndpoint = "https://api.openai.com/v1/chat/completions"

instance LLM GPTBackend where
  runLLM backend request = do
    result <-
      sendJSON
        TransportRequest
          { transportMethod = "POST"
          , transportUrl = gptEndpoint backend
          , transportHeaders = [("Authorization", "Bearer " <> gptApiKey backend)]
          , transportBody = Just (toGPTRequest request)
          }
    pure (result >>= fromGPTResponse request)

toGPTRequest :: LLMRequest -> Value
toGPTRequest request =
  object
    ( catMaybes
        [ Just ("model" .= requestModel request)
        , Just ("messages" .= concatMap toGPTInputItem (requestInput request))
        , ("temperature" .=) <$> requestTemperature request
        , ("max_tokens" .=) <$> requestMaxTokens request
        , nonEmpty "stop" (requestStopSequences request)
        , responseFormatPair (requestResponseFormat request)
        , nonEmpty "tools" (requestTools request)
        ]
    )

toGPTInputItem :: LLMInputItem -> [Value]
toGPTInputItem (MessageInput message) = [toGPTMessage message]
toGPTInputItem (ToolCallInput toolCall) = [toGPTToolCallMessage toolCall]
toGPTInputItem (ToolResultInput toolResult) = [toGPTToolResultMessage toolResult]
toGPTInputItem (ArtifactInput artifactRef) = [toGPTArtifactMessage artifactRef]

toGPTMessage :: LLMMessage -> Value
toGPTMessage message =
  object
    [ "role" .= roleName (messageRole message)
    , "content" .= toGPTContent (messageContent message)
    ]

toGPTArtifactMessage :: ArtifactRef -> Value
toGPTArtifactMessage artifactRef =
  object
    [ "role" .= Aeson.String "user"
    , "content" .= artifactRefText artifactRef
    ]

toGPTToolCallMessage :: ToolCall -> Value
toGPTToolCallMessage toolCall =
  object
    [ "role" .= Aeson.String "assistant"
    , "content" .= Aeson.Null
    , "tool_calls"
        .= [ object
               [ "id" .= toolCallId toolCall
               , "type" .= Aeson.String "function"
               , "function"
                   .= object
                     [ "name" .= toolCallName toolCall
                     , "arguments" .= toolCallArguments toolCall
                     ]
               ]
           ]
    ]

toGPTToolResultMessage :: ToolResult -> Value
toGPTToolResultMessage toolResult =
  object
    [ "role" .= Aeson.String "tool"
    , "tool_call_id" .= toolResultCallId toolResult
    , "content" .= contentPartsText (toolResultContent toolResult)
    ]

responseFormatPair :: ResponseFormat -> Maybe Pair
responseFormatPair PlainText = Nothing
responseFormatPair JsonObject = Just ("response_format" .= object ["type" .= Aeson.String "json_object"])
responseFormatPair (JsonSchema schema) =
  Just
    ( "response_format"
        .= object ["type" .= Aeson.String "json_schema", "json_schema" .= schema]
    )

fromGPTResponse
  :: LLMRequest -> TransportResponse -> Either LLMError LLMResponse
fromGPTResponse request response =
  case decode (LazyByteString.pack (transportResponseBody response)) of
    Nothing -> Left (LLMProviderError "Could not decode GPT response")
    Just gptResponse ->
      case gptChoices gptResponse of
        [] -> Left (LLMProviderError "GPT response did not contain choices")
        choice : _ ->
          Right
            LLMResponse
              { responseModel = maybe (requestModel request) id (gptResponseModel gptResponse)
              , responseMessage =
                  LLMMessage
                    { messageRole = Assistant
                    , messageContent =
                        [TextPart (maybe "" id (gptMessageContent (gptChoiceMessage choice)))]
                    }
              , responseToolCalls =
                  fmap fromGPTToolCall (gptMessageToolCalls (gptChoiceMessage choice))
              , responseOutput =
                  responseItems
                    (maybe "" id (gptMessageContent (gptChoiceMessage choice)))
                    (fmap fromGPTToolCall (gptMessageToolCalls (gptChoiceMessage choice)))
              , responseUsage = gptResponseUsage gptResponse
              , responseFinishReason = gptChoiceFinishReason choice
              }

responseItems :: Text -> [ToolCall] -> [LLMInputItem]
responseItems content toolCalls =
  [MessageInput LLMMessage{messageRole = Assistant, messageContent = [TextPart content]}]
    <> fmap ToolCallInput toolCalls

data GPTResponse = GPTResponse
  { gptResponseModel :: Maybe Text
  , gptChoices :: [GPTChoice]
  , gptResponseUsage :: Maybe LLMUsage
  }

instance FromJSON GPTResponse where
  parseJSON =
    withObject "GPTResponse" $ \objectValue ->
      GPTResponse
        <$> objectValue .:? "model"
        <*> objectValue .: "choices"
        <*> objectValue .:? "usage"

data GPTChoice = GPTChoice
  { gptChoiceMessage :: GPTMessage
  , gptChoiceFinishReason :: Maybe Text
  }

instance FromJSON GPTChoice where
  parseJSON =
    withObject "GPTChoice" $ \objectValue ->
      GPTChoice
        <$> objectValue .: "message"
        <*> objectValue .:? "finish_reason"

data GPTMessage = GPTMessage
  { gptMessageContent :: Maybe Text
  , gptMessageToolCalls :: [GPTToolCall]
  }

instance FromJSON GPTMessage where
  parseJSON =
    withObject "GPTMessage" $ \objectValue ->
      GPTMessage
        <$> objectValue .:? "content"
        <*> objectValue .:? "tool_calls" .!= []

data GPTToolCall = GPTToolCall
  { gptToolCallId :: Text
  , gptToolCallName :: Text
  , gptToolCallArguments :: Value
  }

instance FromJSON GPTToolCall where
  parseJSON =
    withObject "GPTToolCall" $ \objectValue -> do
      functionValue <- objectValue .: "function"
      GPTToolCall
        <$> objectValue .: "id"
        <*> functionValue .: "name"
        <*> functionValue .:? "arguments" .!= Aeson.Null

fromGPTToolCall :: GPTToolCall -> ToolCall
fromGPTToolCall gptToolCall =
  ToolCall
    { toolCallId = gptToolCallId gptToolCall
    , toolCallName = gptToolCallName gptToolCall
    , toolCallArguments = gptToolCallArguments gptToolCall
    }

roleName :: LLMRole -> Text
roleName System = "system"
roleName User = "user"
roleName Assistant = "assistant"
roleName Tool = "tool"

toGPTContent :: [LLMContentPart] -> Value
toGPTContent [TextPart text] = Aeson.String text
toGPTContent parts = Aeson.toJSON (fmap toGPTContentPart parts)

toGPTContentPart :: LLMContentPart -> Value
toGPTContentPart (TextPart text) =
  object ["type" .= Aeson.String "text", "text" .= text]
toGPTContentPart (ImagePart imageRef) =
  object
    [ "type" .= Aeson.String "image_url"
    , "image_url"
        .= object
          ( catMaybes
              [ Just ("url" .= imageRefUri imageRef)
              , ("detail" .=) . imageDetailName <$> imageRefDetail imageRef
              ]
          )
    ]
toGPTContentPart (FilePart fileRef) =
  object ["type" .= Aeson.String "text", "text" .= fileRefText fileRef]
toGPTContentPart (AudioPart audioRef) =
  object ["type" .= Aeson.String "text", "text" .= audioRefText audioRef]

contentPartsText :: [LLMContentPart] -> Text
contentPartsText parts = foldMap contentPartText parts

contentPartText :: LLMContentPart -> Text
contentPartText (TextPart text) = text
contentPartText (ImagePart imageRef) = "[image: " <> imageRefUri imageRef <> "]"
contentPartText (FilePart fileRef) = fileRefText fileRef
contentPartText (AudioPart audioRef) = audioRefText audioRef

artifactRefText :: ArtifactRef -> Text
artifactRefText artifactRef =
  "[artifact: " <> maybe (artifactRefUri artifactRef) id (artifactRefName artifactRef) <> " <" <> artifactRefUri artifactRef <> ">]"

fileRefText :: FileRef -> Text
fileRefText fileRef =
  "[file: " <> maybe (fileRefUri fileRef) id (fileRefName fileRef) <> " <" <> fileRefUri fileRef <> ">]"

audioRefText :: AudioRef -> Text
audioRefText audioRef = "[audio: " <> audioRefUri audioRef <> "]"

imageDetailName :: ImageDetail -> Text
imageDetailName Auto = "auto"
imageDetailName Low = "low"
imageDetailName High = "high"

nonEmpty :: Aeson.ToJSON value => Key -> [value] -> Maybe Pair
nonEmpty _ [] = Nothing
nonEmpty key values = Just (key .= values)
