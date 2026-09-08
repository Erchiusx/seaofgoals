module Agent.SeaOfGoals.LLM
  ( LLM (..)
  , LLMRequest (..)
  , LLMResponse (..)
  , LLMInputItem (..)
  , LLMMessage (..)
  , LLMContentPart (..)
  , ImageRef (..)
  , FileRef (..)
  , AudioRef (..)
  , ArtifactRef (..)
  , ReasoningItem (..)
  , ImageDetail (..)
  , LLMRole (..)
  , LLMUsage (..)
  , LLMError (..)
  , LLMConfig (..)
  , ResponseFormat (..)
  , ToolCall (..)
  , ToolResult (..)
  )
where

import Data.Aeson
  ( FromJSON (..)
  , Options (..)
  , ToJSON (..)
  , Value
  , defaultOptions
  , genericParseJSON
  , genericToJSON
  , object
  , withObject
  , withText
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson qualified as Aeson
import Data.Char (isUpper, toLower)
import Data.List (stripPrefix)
import Data.Text (Text)
import GHC.Generics (Generic)

class LLM provider where
  runLLM :: provider -> LLMRequest -> IO (Either LLMError LLMResponse)

data LLMRequest = LLMRequest
  { requestModel :: Text
  , requestInput :: [LLMInputItem]
  , requestTemperature :: Maybe Double
  , requestMaxTokens :: Maybe Int
  , requestStopSequences :: [Text]
  , requestResponseFormat :: ResponseFormat
  , requestTools :: [Value]
  , requestConfig :: Maybe LLMConfig
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON LLMRequest where
  toJSON = genericToJSON (prefixedOptions "request")

instance FromJSON LLMRequest where
  parseJSON = genericParseJSON (prefixedOptions "request")

data LLMResponse = LLMResponse
  { responseModel :: Text
  , responseMessage :: LLMMessage
  , responseToolCalls :: [ToolCall]
  , responseOutput :: [LLMInputItem]
  , responseUsage :: Maybe LLMUsage
  , responseFinishReason :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON LLMResponse where
  toJSON = genericToJSON (prefixedOptions "response")

instance FromJSON LLMResponse where
  parseJSON = genericParseJSON (prefixedOptions "response")

data LLMInputItem
  = MessageInput LLMMessage
  | ToolCallInput ToolCall
  | ToolResultInput ToolResult
  | ArtifactInput ArtifactRef
  | ReasoningInput ReasoningItem
  deriving stock (Eq, Show, Generic)

instance ToJSON LLMInputItem where
  toJSON (MessageInput message) =
    object ["type" .= Aeson.String "message", "message" .= message]
  toJSON (ToolCallInput toolCall) =
    object ["type" .= Aeson.String "tool_call", "tool_call" .= toolCall]
  toJSON (ToolResultInput toolResult) =
    object ["type" .= Aeson.String "tool_result", "tool_result" .= toolResult]
  toJSON (ArtifactInput artifactRef) =
    object ["type" .= Aeson.String "artifact", "artifact" .= artifactRef]
  toJSON (ReasoningInput reasoningItem) =
    object ["type" .= Aeson.String "reasoning", "reasoning" .= reasoningItem]

instance FromJSON LLMInputItem where
  parseJSON =
    withObject "LLMInputItem" $ \objectValue -> do
      itemType <- objectValue .: "type"
      case itemType of
        Aeson.String "message" -> MessageInput <$> objectValue .: "message"
        Aeson.String "tool_call" -> ToolCallInput <$> objectValue .: "tool_call"
        Aeson.String "tool_result" -> ToolResultInput <$> objectValue .: "tool_result"
        Aeson.String "artifact" -> ArtifactInput <$> objectValue .: "artifact"
        Aeson.String "reasoning" -> ReasoningInput <$> objectValue .: "reasoning"
        Aeson.String _ -> fail "Unknown LLM input item type"
        _ -> fail "LLM input item type must be a string"

data LLMMessage = LLMMessage
  { messageRole :: LLMRole
  , messageContent :: [LLMContentPart]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON LLMMessage where
  toJSON = genericToJSON (prefixedOptions "message")

instance FromJSON LLMMessage where
  parseJSON = genericParseJSON (prefixedOptions "message")

data LLMContentPart
  = TextPart Text
  | ImagePart ImageRef
  | FilePart FileRef
  | AudioPart AudioRef
  deriving stock (Eq, Show, Generic)

instance ToJSON LLMContentPart where
  toJSON (TextPart text) =
    object ["type" .= Aeson.String "text", "text" .= text]
  toJSON (ImagePart imageRef) =
    object ["type" .= Aeson.String "image", "image" .= imageRef]
  toJSON (FilePart fileRef) =
    object ["type" .= Aeson.String "file", "file" .= fileRef]
  toJSON (AudioPart audioRef) =
    object ["type" .= Aeson.String "audio", "audio" .= audioRef]

instance FromJSON LLMContentPart where
  parseJSON =
    withObject "LLMContentPart" $ \objectValue -> do
      partType <- objectValue .: "type"
      case partType of
        Aeson.String "text" -> TextPart <$> objectValue .: "text"
        Aeson.String "image" -> ImagePart <$> objectValue .: "image"
        Aeson.String "file" -> FilePart <$> objectValue .: "file"
        Aeson.String "audio" -> AudioPart <$> objectValue .: "audio"
        Aeson.String _ -> fail "Unknown LLM content part type"
        _ -> fail "LLM content part type must be a string"

data ImageRef = ImageRef
  { imageRefUri :: Text
  , imageRefMimeType :: Maybe Text
  , imageRefDetail :: Maybe ImageDetail
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ImageRef where
  toJSON = genericToJSON (prefixedOptions "imageRef")

instance FromJSON ImageRef where
  parseJSON = genericParseJSON (prefixedOptions "imageRef")

data FileRef = FileRef
  { fileRefUri :: Text
  , fileRefMimeType :: Maybe Text
  , fileRefName :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON FileRef where
  toJSON = genericToJSON (prefixedOptions "fileRef")

instance FromJSON FileRef where
  parseJSON = genericParseJSON (prefixedOptions "fileRef")

data AudioRef = AudioRef
  { audioRefUri :: Text
  , audioRefMimeType :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON AudioRef where
  toJSON = genericToJSON (prefixedOptions "audioRef")

instance FromJSON AudioRef where
  parseJSON = genericParseJSON (prefixedOptions "audioRef")

data ArtifactRef = ArtifactRef
  { artifactRefUri :: Text
  , artifactRefMimeType :: Maybe Text
  , artifactRefName :: Maybe Text
  , artifactRefDescription :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ArtifactRef where
  toJSON = genericToJSON (prefixedOptions "artifactRef")

instance FromJSON ArtifactRef where
  parseJSON = genericParseJSON (prefixedOptions "artifactRef")

data ReasoningItem = ReasoningItem
  { reasoningItemId :: Maybe Text
  , reasoningItemEncryptedContent :: Text
  , reasoningItemSummary :: Value
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ReasoningItem where
  toJSON = genericToJSON (prefixedOptions "reasoningItem")

instance FromJSON ReasoningItem where
  parseJSON = genericParseJSON (prefixedOptions "reasoningItem")

data ImageDetail
  = Auto
  | Low
  | High
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON ImageDetail where
  toJSON = genericToJSON enumOptions

instance FromJSON ImageDetail where
  parseJSON = genericParseJSON enumOptions

data LLMRole
  = System
  | User
  | Assistant
  | Tool
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON LLMRole where
  toJSON = genericToJSON enumOptions

instance FromJSON LLMRole where
  parseJSON = genericParseJSON enumOptions

data LLMUsage = LLMUsage
  { usagePromptTokens :: Int
  , usageCompletionTokens :: Int
  , usageTotalTokens :: Int
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON LLMUsage where
  toJSON = genericToJSON (prefixedOptions "usage")

instance FromJSON LLMUsage where
  parseJSON =
    withObject "LLMUsage" $ \objectValue ->
      LLMUsage
        <$> ( objectValue .:? "prompt_tokens"
                >>= maybe (objectValue .: "input_tokens") pure
            )
        <*> ( objectValue .:? "completion_tokens"
                >>= maybe (objectValue .: "output_tokens") pure
            )
        <*> objectValue .: "total_tokens"

data LLMError
  = LLMProviderError Text
  | LLMRateLimited Text
  | LLMInvalidRequest Text
  | LLMAuthenticationError Text
  | LLMTransportError Text
  deriving stock (Eq, Show, Generic)

instance ToJSON LLMError where
  toJSON = genericToJSON (sumOptions "LLM")

instance FromJSON LLMError where
  parseJSON = genericParseJSON (sumOptions "LLM")

data LLMConfig = LLMConfig
  { configEndpoint :: Maybe Text
  , configApiKeyEnv :: Maybe Text
  , configHeaders :: Value
  , configProviderOptions :: Value
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON LLMConfig where
  toJSON = genericToJSON (prefixedOptions "config")

instance FromJSON LLMConfig where
  parseJSON = genericParseJSON (prefixedOptions "config")

data ResponseFormat
  = PlainText
  | JsonObject
  | JsonSchema Value
  deriving stock (Eq, Show)

instance ToJSON ResponseFormat where
  toJSON PlainText = Aeson.String "plain_text"
  toJSON JsonObject = Aeson.String "json_object"
  toJSON (JsonSchema schema) =
    Aeson.object
      [ "type" .= Aeson.String "json_schema"
      , "schema" .= schema
      ]

instance FromJSON ResponseFormat where
  parseJSON value =
    case value of
      Aeson.String _ -> withText "ResponseFormat" parseText value
      Aeson.Object _ -> withObject "ResponseFormat" parseObject value
      _ -> fail "ResponseFormat must be a string or object"
   where
    parseText "plain_text" = pure PlainText
    parseText "json_object" = pure JsonObject
    parseText _ = fail "Unknown response format"

    parseObject objectValue = do
      formatType <- objectValue .: "type"
      case formatType of
        Aeson.String "json_schema" -> JsonSchema <$> objectValue .: "schema"
        Aeson.String _ -> fail "Unknown response format"
        _ -> fail "Response format type must be a string"

data ToolCall = ToolCall
  { toolCallId :: Text
  , toolCallName :: Text
  , toolCallArguments :: Value
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ToolCall where
  toJSON = genericToJSON (prefixedOptions "toolCall")

instance FromJSON ToolCall where
  parseJSON = genericParseJSON (prefixedOptions "toolCall")

data ToolResult = ToolResult
  { toolResultCallId :: Text
  , toolResultName :: Maybe Text
  , toolResultContent :: [LLMContentPart]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ToolResult where
  toJSON = genericToJSON (prefixedOptions "toolResult")

instance FromJSON ToolResult where
  parseJSON = genericParseJSON (prefixedOptions "toolResult")

prefixedOptions :: String -> Options
prefixedOptions prefix =
  defaultOptions
    { fieldLabelModifier = snakeCase . unprefix prefix
    , omitNothingFields = True
    }

enumOptions :: Options
enumOptions =
  defaultOptions
    { constructorTagModifier = snakeCase
    , allNullaryToStringTag = True
    }

sumOptions :: String -> Options
sumOptions prefix =
  defaultOptions
    { constructorTagModifier = snakeCase . unprefix prefix
    , sumEncoding = Aeson.ObjectWithSingleField
    }

unprefix :: String -> String -> String
unprefix prefix value =
  case stripPrefix prefix value of
    Just (next : rest) -> toLower next : rest
    Just [] -> []
    Nothing -> value

snakeCase :: String -> String
snakeCase = go True
 where
  go _ [] = []
  go isFirst (char : rest)
    | isUpper char =
        (if isFirst then [] else "_") <> [toLower char] <> go False rest
    | otherwise = char : go False rest
