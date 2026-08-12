module Agent.SeaOfGoals.LLM.Backends.Gemini
  ( GeminiBackend (..)
  , defaultGeminiEndpoint
  )
where

import Agent.LLM.Transport
  ( TransportRequest (..)
  , TransportResponse (..)
  , sendJSON
  )
import Agent.SeaOfGoals.LLM
  ( ArtifactRef (..)
  , AudioRef (..)
  , FileRef (..)
  , ImageRef (..)
  , LLM (..)
  , LLMContentPart (..)
  , LLMError (..)
  , LLMInputItem (..)
  , LLMMessage (..)
  , LLMRequest (..)
  , LLMResponse (..)
  , LLMRole (..)
  , LLMUsage (..)
  , ResponseFormat (..)
  , ToolCall (..)
  , ToolResult (..)
  )
import Data.Aeson
  ( FromJSON (..)
  , Value
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
import Data.Functor ((<&>))
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text

data GeminiBackend = GeminiBackend
  { geminiApiKey :: String
  , geminiEndpoint :: String
  }
  deriving stock (Eq, Show)

defaultGeminiEndpoint :: String
defaultGeminiEndpoint = "https://generativelanguage.googleapis.com/v1beta/models"

instance LLM GeminiBackend where
  runLLM backend request = do
    result <-
      sendJSON
        TransportRequest
          { transportMethod = "POST"
          , transportUrl = geminiUrl backend request
          , transportHeaders = []
          , transportBody = Just (toGeminiRequest request)
          }
    pure (result >>= fromGeminiResponse request)

geminiUrl :: GeminiBackend -> LLMRequest -> String
geminiUrl backend request =
  geminiEndpoint backend
    <> "/"
    <> Text.unpack (requestModel request)
    <> ":generateContent?key="
    <> geminiApiKey backend

toGeminiRequest :: LLMRequest -> Value
toGeminiRequest request =
  object
    ( catMaybes
        [ Just
            ( "contents"
                .= concatMap toGeminiInputItem (filter nonSystemInputItem (requestInput request))
            )
        , systemInstructionPair (requestInput request)
        , generationConfigPair request
        , nonEmpty "tools" (requestTools request)
        ]
    )

toGeminiInputItem :: LLMInputItem -> [Value]
toGeminiInputItem (MessageInput message) = [toGeminiContent message]
toGeminiInputItem (ToolCallInput toolCall) = [toGeminiToolCallContent toolCall]
toGeminiInputItem (ToolResultInput toolResult) = [toGeminiToolResultContent toolResult]
toGeminiInputItem (ArtifactInput artifactRef) = [toGeminiArtifactContent artifactRef]

toGeminiContent :: LLMMessage -> Value
toGeminiContent message =
  object
    [ "role" .= geminiRoleName (messageRole message)
    , "parts" .= concatMap toGeminiContentPart (messageContent message)
    ]

toGeminiArtifactContent :: ArtifactRef -> Value
toGeminiArtifactContent artifactRef =
  object
    [ "role" .= Aeson.String "user"
    , "parts" .= [object ["text" .= artifactRefText artifactRef]]
    ]

toGeminiToolCallContent :: ToolCall -> Value
toGeminiToolCallContent toolCall =
  object
    [ "role" .= Aeson.String "model"
    , "parts"
        .= [ object
               [ "functionCall"
                   .= object
                     [ "name" .= toolCallName toolCall
                     , "args" .= toolCallArguments toolCall
                     ]
               ]
           ]
    ]

toGeminiToolResultContent :: ToolResult -> Value
toGeminiToolResultContent toolResult =
  object
    [ "role" .= Aeson.String "user"
    , "parts"
        .= [ object
               [ "functionResponse"
                   .= object
                     [ "name" .= maybe (toolResultCallId toolResult) id (toolResultName toolResult)
                     , "response"
                         .= object ["content" .= contentPartsText (toolResultContent toolResult)]
                     ]
               ]
           ]
    ]

systemInstructionPair :: [LLMInputItem] -> Maybe Pair
systemInstructionPair inputItems =
  case [ contentPartsText (messageContent message)
       | MessageInput message <- inputItems
       , messageRole message == System
       ] of
    [] -> Nothing
    instructions ->
      Just
        ( "system_instruction"
            .= object ["parts" .= fmap (\content -> object ["text" .= content]) instructions]
        )

generationConfigPair :: LLMRequest -> Maybe Pair
generationConfigPair request =
  case catMaybes [temperaturePair, maxTokensPair] <> responseFormatPairs of
    [] -> Nothing
    pairs -> Just ("generationConfig" .= object pairs)
 where
  temperaturePair = ("temperature" .=) <$> requestTemperature request
  maxTokensPair = ("maxOutputTokens" .=) <$> requestMaxTokens request
  responseFormatPairs =
    case requestResponseFormat request of
      PlainText -> []
      JsonObject -> ["responseMimeType" .= Aeson.String "application/json"]
      JsonSchema schema ->
        [ "responseMimeType" .= Aeson.String "application/json"
        , "responseSchema" .= schema
        ]

fromGeminiResponse
  :: LLMRequest -> TransportResponse -> Either LLMError LLMResponse
fromGeminiResponse request response =
  case Aeson.decode (transportResponseBody response) of
    Nothing -> Left (LLMProviderError "Could not decode Gemini response")
    Just geminiResponse ->
      case geminiCandidates geminiResponse of
        [] -> Left (LLMProviderError "Gemini response did not contain candidates")
        candidate : _ ->
          Right
            LLMResponse
              { responseModel = requestModel request
              , responseMessage =
                  LLMMessage
                    { messageRole = Assistant
                    , messageContent = [TextPart (geminiCandidateText candidate)]
                    }
              , responseToolCalls = geminiCandidateToolCalls candidate
              , responseOutput =
                  responseItems
                    (geminiCandidateText candidate)
                    (geminiCandidateToolCalls candidate)
              , responseUsage = fmap fromGeminiUsage (geminiUsageMetadata geminiResponse)
              , responseFinishReason = geminiCandidateFinishReason candidate
              }

responseItems :: Text -> [ToolCall] -> [LLMInputItem]
responseItems content toolCalls =
  [ MessageInput
      LLMMessage{messageRole = Assistant, messageContent = [TextPart content]}
  ]
    <> fmap ToolCallInput toolCalls

data GeminiResponse = GeminiResponse
  { geminiCandidates :: [GeminiCandidate]
  , geminiUsageMetadata :: Maybe GeminiUsage
  }

instance FromJSON GeminiResponse where
  parseJSON =
    withObject "GeminiResponse" $ \objectValue ->
      GeminiResponse
        <$> objectValue .: "candidates"
        <*> objectValue .:? "usageMetadata"

data GeminiCandidate = GeminiCandidate
  { geminiCandidateText :: Text
  , geminiCandidateToolCalls :: [ToolCall]
  , geminiCandidateFinishReason :: Maybe Text
  }

instance FromJSON GeminiCandidate where
  parseJSON =
    withObject "GeminiCandidate" $ \objectValue -> do
      content <- objectValue .: "content"
      let
        text = foldMap geminiPartText (geminiContentParts content)
        toolCalls =
          zipWith
            geminiFunctionCallToToolCall
            [(0 :: Int) ..]
            (foldMap geminiPartFunctionCalls (geminiContentParts content))
      GeminiCandidate text toolCalls <$> objectValue .:? "finishReason"

newtype GeminiContent = GeminiContent
  { geminiContentParts :: [GeminiPart]
  }

instance FromJSON GeminiContent where
  parseJSON =
    withObject "GeminiContent" $ \objectValue ->
      GeminiContent <$> objectValue .: "parts"

data GeminiPart = GeminiPart
  { geminiPartText :: Text
  , geminiPartFunctionCalls :: [GeminiFunctionCall]
  }

instance FromJSON GeminiPart where
  parseJSON =
    withObject "GeminiPart" $ \objectValue -> do
      text <- objectValue .:? "text" .!= ""
      functionCall <- objectValue .:? "functionCall"
      pure (GeminiPart text (maybe [] pure functionCall))

data GeminiFunctionCall = GeminiFunctionCall
  { geminiFunctionCallName :: Text
  , geminiFunctionCallArgs :: Value
  }

instance FromJSON GeminiFunctionCall where
  parseJSON =
    withObject "GeminiFunctionCall" $ \objectValue ->
      GeminiFunctionCall
        <$> objectValue .: "name"
        <*> objectValue .:? "args" .!= Aeson.Null

geminiFunctionCallToToolCall :: Int -> GeminiFunctionCall -> ToolCall
geminiFunctionCallToToolCall index functionCall =
  ToolCall
    { toolCallId = "gemini:" <> Text.pack (show index)
    , toolCallName = geminiFunctionCallName functionCall
    , toolCallArguments = geminiFunctionCallArgs functionCall
    }

newtype GeminiUsage = GeminiUsage
  { fromGeminiUsage :: LLMUsage
  }

instance FromJSON GeminiUsage where
  parseJSON =
    withObject "GeminiUsage" $ \objectValue ->
      fmap
        GeminiUsage
        ( LLMUsage
            <$> objectValue .:? "promptTokenCount" .!= 0
            <*> objectValue .:? "candidatesTokenCount" .!= 0
            <*> objectValue .:? "totalTokenCount" .!= 0
        )

nonSystemInputItem :: LLMInputItem -> Bool
nonSystemInputItem (MessageInput message) = messageRole message /= System
nonSystemInputItem (ToolCallInput _) = True
nonSystemInputItem (ToolResultInput _) = True
nonSystemInputItem (ArtifactInput _) = True

geminiRoleName :: LLMRole -> Text
geminiRoleName System = "user"
geminiRoleName User = "user"
geminiRoleName Assistant = "model"
geminiRoleName Tool = "user"

toGeminiContentPart :: LLMContentPart -> [Value]
toGeminiContentPart (TextPart text) = [object ["text" .= text]]
toGeminiContentPart (ImagePart imageRef) =
  [ object
      [ "fileData"
          .= object
            ( catMaybes
                [ imageRefMimeType imageRef <&> ("mimeType" .=)
                , Just ("fileUri" .= imageRefUri imageRef)
                ]
            )
      ]
  ]
toGeminiContentPart (FilePart fileRef) =
  [ object
      [ "fileData"
          .= object
            ( catMaybes
                [ fileRefMimeType fileRef <&> ("mimeType" .=)
                , Just ("fileUri" .= fileRefUri fileRef)
                ]
            )
      ]
  ]
toGeminiContentPart (AudioPart audioRef) =
  [ object
      [ "fileData"
          .= object
            ( catMaybes
                [ audioRefMimeType audioRef <&> ("mimeType" .=)
                , Just ("fileUri" .= audioRefUri audioRef)
                ]
            )
      ]
  ]

contentPartsText :: [LLMContentPart] -> Text
contentPartsText parts = foldMap contentPartText parts

contentPartText :: LLMContentPart -> Text
contentPartText (TextPart text) = text
contentPartText (ImagePart imageRef) = "[image: " <> imageRefUri imageRef <> "]"
contentPartText (FilePart fileRef) = fileRefText fileRef
contentPartText (AudioPart audioRef) = audioRefText audioRef

artifactRefText :: ArtifactRef -> Text
artifactRefText artifactRef =
  "[artifact: "
    <> maybe (artifactRefUri artifactRef) id (artifactRefName artifactRef)
    <> " <"
    <> artifactRefUri artifactRef
    <> ">]"

fileRefText :: FileRef -> Text
fileRefText fileRef =
  "[file: "
    <> maybe (fileRefUri fileRef) id (fileRefName fileRef)
    <> " <"
    <> fileRefUri fileRef
    <> ">]"

audioRefText :: AudioRef -> Text
audioRefText audioRef = "[audio: " <> audioRefUri audioRef <> "]"

nonEmpty :: Aeson.ToJSON value => Key -> [value] -> Maybe Pair
nonEmpty _ [] = Nothing
nonEmpty key values = Just (key .= values)
