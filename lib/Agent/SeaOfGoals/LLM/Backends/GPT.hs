module Agent.SeaOfGoals.LLM.Backends.GPT
  ( GPTBackend (..)
  , compactGPTHistory
  , defaultGPTEndpoint
  , fromResponsesCompactionResponse
  , fromResponsesV2CompactionResponse
  , fromGPTResponseForEndpoint
  , loadGPTEndpointFromEnv
  , toResponsesCompactionRequest
  , toResponsesRequest
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
  , CompactionItem (..)
  , FileRef (..)
  , ImageDetail (..)
  , ImageRef (..)
  , LLM (..)
  , LLMContentPart (..)
  , LLMError (..)
  , LLMInputItem (..)
  , LLMMessage (..)
  , LLMRequest (..)
  , LLMResponse (..)
  , LLMRole (..)
  , LLMUsage
  , ReasoningItem (..)
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
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Aeson.Types
  ( Pair
  , Parser
  , parseEither
  )
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyByteStringChar8
import Data.Foldable (toList)
import Data.List (isSuffixOf)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import System.Environment (lookupEnv)

data GPTBackend = GPTBackend
  { gptApiKey :: String
  , gptEndpoint :: String
  }
  deriving stock (Eq, Show)

defaultGPTEndpoint :: String
defaultGPTEndpoint = "https://api.openai.com/v1/responses"

loadGPTEndpointFromEnv :: IO String
loadGPTEndpointFromEnv = do
  maybeResponsesUrl <- lookupEnv "OPENAI_RESPONSES_URL"
  maybeChatCompletionsUrl <- lookupEnv "OPENAI_CHAT_COMPLETIONS_URL"
  maybeBaseUrl <- lookupEnv "OPENAI_BASE_URL"
  pure $
    firstNonEmpty
      defaultGPTEndpoint
      [ maybeResponsesUrl
      , maybeChatCompletionsUrl
      , fmap responsesUrl maybeBaseUrl
      ]

responsesUrl :: String -> String
responsesUrl baseUrl =
  stripTrailingSlash baseUrl <> "/responses"

stripTrailingSlash :: String -> String
stripTrailingSlash =
  reverse . dropWhile (== '/') . reverse

firstNonEmpty :: String -> [Maybe String] -> String
firstNonEmpty fallback [] = fallback
firstNonEmpty fallback (Nothing : rest) = firstNonEmpty fallback rest
firstNonEmpty fallback (Just value : rest)
  | null value = firstNonEmpty fallback rest
  | otherwise = value

instance LLM GPTBackend where
  runLLM backend request = do
    result <-
      sendJSON
        TransportRequest
          { transportMethod = "POST"
          , transportUrl = gptEndpoint backend
          , transportHeaders = [("Authorization", "Bearer " <> gptApiKey backend)]
          , transportBody = Just (toGPTRequestForEndpoint (gptEndpoint backend) request)
          }
    pure (result >>= fromGPTResponseForEndpoint (gptEndpoint backend) request)

{- | Compact already-produced Responses protocol items through the current
streaming Responses V2 contract.  The client retains user messages and appends
the single opaque continuation item returned by the server.
-}
compactGPTHistory
  :: GPTBackend
  -> LLMRequest
  -> [LLMInputItem]
  -> IO (Either LLMError [LLMInputItem])
compactGPTHistory backend request history
  | not (isResponsesEndpoint (gptEndpoint backend)) =
      pure
        (Left (LLMInvalidRequest "history compaction requires a Responses endpoint"))
  | otherwise = do
      result <-
        sendJSON
          TransportRequest
            { transportMethod = "POST"
            , transportUrl = gptEndpoint backend
            , transportHeaders =
                [ ("Authorization", "Bearer " <> gptApiKey backend)
                , ("Accept", "text/event-stream")
                ]
            , transportBody = Just (toResponsesCompactionRequest request history)
            }
      pure (result >>= fromResponsesV2CompactionResponse history)

toGPTRequestForEndpoint :: String -> LLMRequest -> Value
toGPTRequestForEndpoint endpoint request
  | isResponsesEndpoint endpoint = toResponsesRequest request
  | otherwise = toChatCompletionsRequest request

toChatCompletionsRequest :: LLMRequest -> Value
toChatCompletionsRequest request =
  object
    ( catMaybes
        [ Just ("model" .= requestModel request)
        , Just ("messages" .= concatMap toGPTInputItem (requestInput request))
        , ("temperature" .=) <$> requestTemperature request
        , tokenLimitPair (requestModel request) <$> requestMaxTokens request
        , nonEmpty "stop" (requestStopSequences request)
        , responseFormatPair (requestResponseFormat request)
        , nonEmpty "tools" (requestTools request)
        ]
    )

toResponsesRequest :: LLMRequest -> Value
toResponsesRequest request =
  object
    ( catMaybes
        [ Just ("model" .= requestModel request)
        , Just ("input" .= concatMap toResponsesInputItem (nonSystemInputItems request))
        , nonEmptyText "instructions" (systemInstructions request)
        , ("temperature" .=) <$> requestTemperature request
        , ("max_output_tokens" .=) <$> requestMaxTokens request
        , responseTextPair (requestResponseFormat request)
        , Just ("include" .= ["reasoning.encrypted_content" :: Text])
        , nonEmpty "tools" (fmap chatToolToResponsesTool (requestTools request))
        , Just ("parallel_tool_calls" .= True)
        , Just ("store" .= False)
        , ("prompt_cache_key" .=) <$> requestPromptCacheKey request
        , ("prompt_cache_retention" .=) <$> requestPromptCacheRetention request
        ]
    )

toResponsesCompactionRequest :: LLMRequest -> [LLMInputItem] -> Value
toResponsesCompactionRequest request history =
  object
    ( catMaybes
        [ Just ("model" .= requestModel request)
        , Just
            ( "input"
                .= ( concatMap toResponsesInputItem history
                       <> [object ["type" .= Aeson.String "compaction_trigger"]]
                   )
            )
        , nonEmptyText "instructions" (systemInstructions request)
        , Just ("tools" .= fmap chatToolToResponsesTool (requestTools request))
        , Just ("tool_choice" .= Aeson.String "auto")
        , Just ("parallel_tool_calls" .= True)
        , Just ("reasoning" .= object [])
        , Just ("store" .= False)
        , Just ("stream" .= True)
        , Just ("include" .= ["reasoning.encrypted_content" :: Text])
        , ("prompt_cache_key" .=) <$> requestPromptCacheKey request
        , ("prompt_cache_retention" .=) <$> requestPromptCacheRetention request
        ]
    )

systemInstructions :: LLMRequest -> Text
systemInstructions request =
  Text.intercalate
    "\n\n"
    [ contentPartsText content
    | MessageInput LLMMessage{messageRole = System, messageContent = content} <-
        requestInput request
    ]

nonSystemInputItems :: LLMRequest -> [LLMInputItem]
nonSystemInputItems request =
  [ item
  | item <- requestInput request
  , case item of
      MessageInput LLMMessage{messageRole = System} -> False
      _ -> True
  ]

toResponsesInputItem :: LLMInputItem -> [Value]
toResponsesInputItem (MessageInput message) = [toResponsesMessage message]
toResponsesInputItem (ToolCallInput toolCall) = [toResponsesToolCallItem toolCall]
toResponsesInputItem (ToolResultInput toolResult) = [toResponsesToolResultItem toolResult]
toResponsesInputItem (ArtifactInput artifactRef) =
  [ object
      [ "role" .= Aeson.String "user"
      , "content" .= artifactRefText artifactRef
      ]
  ]
toResponsesInputItem (ReasoningInput reasoningItem) =
  [toResponsesReasoningItem reasoningItem]
toResponsesInputItem (CompactionInput compactionItem) =
  [ toResponsesCompactionItem compactionItem
  ]

toResponsesMessage :: LLMMessage -> Value
toResponsesMessage message =
  object
    [ "role" .= roleName (messageRole message)
    , "content" .= contentPartsText (messageContent message)
    ]

toResponsesToolCallItem :: ToolCall -> Value
toResponsesToolCallItem toolCall =
  object
    [ "type" .= Aeson.String "function_call"
    , "call_id" .= toolCallId toolCall
    , "name" .= toolCallName toolCall
    , "arguments" .= encodeToolArguments (toolCallArguments toolCall)
    ]

toResponsesToolResultItem :: ToolResult -> Value
toResponsesToolResultItem toolResult =
  object
    [ "type" .= Aeson.String "function_call_output"
    , "call_id" .= toolResultCallId toolResult
    , "output" .= contentPartsText (toolResultContent toolResult)
    ]

toResponsesReasoningItem :: ReasoningItem -> Value
toResponsesReasoningItem reasoningItem =
  object
    ( catMaybes
        [ Just ("type" .= Aeson.String "reasoning")
        , ("id" .=) <$> reasoningItemId reasoningItem
        , Just ("encrypted_content" .= reasoningItemEncryptedContent reasoningItem)
        , Just ("summary" .= reasoningItemSummary reasoningItem)
        ]
    )

toResponsesCompactionItem :: CompactionItem -> Value
toResponsesCompactionItem compactionItem =
  object
    [ "type" .= Aeson.String "compaction"
    , "encrypted_content" .= compactionItemEncryptedContent compactionItem
    ]

chatToolToResponsesTool :: Value -> Value
chatToolToResponsesTool (Aeson.Object toolObject)
  | Just (Aeson.Object functionObject) <- AesonKeyMap.lookup "function" toolObject =
      Aeson.Object
        (AesonKeyMap.insert "type" (Aeson.String "function") functionObject)
chatToolToResponsesTool value = value

tokenLimitPair :: Text -> Int -> Pair
tokenLimitPair model maxTokens
  | "gpt-5" `Text.isPrefixOf` model = "max_completion_tokens" .= maxTokens
  | otherwise = "max_tokens" .= maxTokens

toGPTInputItem :: LLMInputItem -> [Value]
toGPTInputItem (MessageInput message) = [toGPTMessage message]
toGPTInputItem (ToolCallInput toolCall) = [toGPTToolCallMessage toolCall]
toGPTInputItem (ToolResultInput toolResult) = [toGPTToolResultMessage toolResult]
toGPTInputItem (ArtifactInput artifactRef) = [toGPTArtifactMessage artifactRef]
toGPTInputItem (ReasoningInput _) = []
toGPTInputItem (CompactionInput _) = []

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
                     , "arguments" .= encodeToolArguments (toolCallArguments toolCall)
                     ]
               ]
           ]
    ]

encodeToolArguments :: Value -> Text
encodeToolArguments =
  Text.pack . LazyByteStringChar8.unpack . Aeson.encode

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

responseTextPair :: ResponseFormat -> Maybe Pair
responseTextPair PlainText = Nothing
responseTextPair JsonObject =
  Just
    ("text" .= object ["format" .= object ["type" .= Aeson.String "json_object"]])
responseTextPair (JsonSchema schema) =
  Just
    ( "text"
        .= object
          [ "format"
              .= object
                [ "type" .= Aeson.String "json_schema"
                , "json_schema" .= schema
                ]
          ]
    )

fromGPTResponseForEndpoint
  :: String -> LLMRequest -> TransportResponse -> Either LLMError LLMResponse
fromGPTResponseForEndpoint endpoint request response
  | isResponsesEndpoint endpoint = fromResponsesResponse request response
  | otherwise = fromChatCompletionsResponse request response

fromChatCompletionsResponse
  :: LLMRequest -> TransportResponse -> Either LLMError LLMResponse
fromChatCompletionsResponse request response =
  case decode (transportResponseBody response) of
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

fromResponsesResponse
  :: LLMRequest -> TransportResponse -> Either LLMError LLMResponse
fromResponsesResponse request response =
  case decode (transportResponseBody response) of
    Nothing -> Left (LLMProviderError "Could not decode Responses API response")
    Just responsesResponse ->
      let
        content =
          Text.intercalate "\n" (responsesOutputText (responsesOutput responsesResponse))
        toolCalls = concatMap responsesOutputToolCalls (responsesOutput responsesResponse)
       in
        Right
          LLMResponse
            { responseModel =
                maybe (requestModel request) id (responsesModel responsesResponse)
            , responseMessage =
                LLMMessage
                  { messageRole = Assistant
                  , messageContent = [TextPart content]
                  }
            , responseToolCalls = toolCalls
            , responseOutput =
                responseItemsWithReasoning content (responsesOutput responsesResponse)
            , responseUsage = responsesUsage responsesResponse
            , responseFinishReason = responsesStatus responsesResponse
            }

fromResponsesCompactionResponse
  :: TransportResponse -> Either LLMError [LLMInputItem]
fromResponsesCompactionResponse response =
  case decode (transportResponseBody response) of
    Nothing -> Left (LLMProviderError "Could not decode Responses compaction response")
    Just ResponsesCompactionResponse{responsesCompactionOutput = output} -> do
      items <-
        either
          (Left . LLMProviderError . Text.pack)
          Right
          (traverse (parseEither fromResponsesCompactionOutputItem) output)
      if any isCompactionInput items
        then Right items
        else
          Left
            ( LLMProviderError
                "Responses compaction response did not contain a compaction item"
            )

fromResponsesV2CompactionResponse
  :: [LLMInputItem] -> TransportResponse -> Either LLMError [LLMInputItem]
fromResponsesV2CompactionResponse history response = do
  events <-
    traverse decodeSseEvent (sseDataLines (transportResponseBody response))
  let
    compactionItems = catMaybes (fmap outputCompactionItem events)
    completed = any isResponseCompleted events
  if not completed
    then
      Left
        ( LLMProviderError
            "Responses V2 compaction stream ended before response.completed"
        )
    else case compactionItems of
      [compactionValue] -> do
        compaction <-
          either
            (Left . LLMProviderError . Text.pack)
            Right
            (parseEither fromResponsesCompactionOutputItem compactionValue)
        case compaction of
          CompactionInput _ -> Right (retainedUserMessages history <> [compaction])
          _ ->
            Left
              (LLMProviderError "Responses V2 compaction output was not a compaction item")
      _ ->
        Left
          ( LLMProviderError
              ( "Responses V2 compaction expected exactly one compaction output item, got "
                  <> Text.pack (show (length compactionItems))
              )
          )

sseDataLines :: LazyByteString.ByteString -> [Text]
sseDataLines body =
  [ Text.drop (Text.length "data: ") line
  | line <- Text.lines (TextEncoding.decodeUtf8 (LazyByteString.toStrict body))
  , "data: " `Text.isPrefixOf` line
  , Text.drop (Text.length "data: ") line /= "[DONE]"
  ]

decodeSseEvent :: Text -> Either LLMError Value
decodeSseEvent line =
  case Aeson.eitherDecodeStrict' (TextEncoding.encodeUtf8 line) of
    Left err ->
      Left
        (LLMProviderError ("Could not decode Responses SSE event: " <> Text.pack err))
    Right value -> Right value

outputCompactionItem :: Value -> Maybe Value
outputCompactionItem (Aeson.Object event)
  | Just (Aeson.String "response.output_item.done") <-
      AesonKeyMap.lookup "type" event
  , Just item@(Aeson.Object itemObject) <- AesonKeyMap.lookup "item" event
  , Just (Aeson.String "compaction") <- AesonKeyMap.lookup "type" itemObject =
      Just item
outputCompactionItem _ = Nothing

isResponseCompleted :: Value -> Bool
isResponseCompleted (Aeson.Object event) =
  AesonKeyMap.lookup "type" event == Just (Aeson.String "response.completed")
isResponseCompleted _ = False

retainedUserMessages :: [LLMInputItem] -> [LLMInputItem]
retainedUserMessages = filter isUserMessage
 where
  isUserMessage (MessageInput LLMMessage{messageRole = User}) = True
  isUserMessage _ = False

isCompactionInput :: LLMInputItem -> Bool
isCompactionInput CompactionInput{} = True
isCompactionInput _ = False

responseItems :: Text -> [ToolCall] -> [LLMInputItem]
responseItems content toolCalls
  | Text.null content && not (null toolCalls) = []
  | otherwise =
      [ MessageInput
          LLMMessage{messageRole = Assistant, messageContent = [TextPart content]}
      ]

responseItemsWithReasoning :: Text -> [ResponsesOutputItem] -> [LLMInputItem]
responseItemsWithReasoning _content = concatMap responseOutputItem

responseOutputItem :: ResponsesOutputItem -> [LLMInputItem]
responseOutputItem (ResponsesReasoningItem reasoningItem) = [ReasoningInput reasoningItem]
responseOutputItem (ResponsesFunctionCallItem toolCall) = [ToolCallInput toolCall]
responseOutputItem (ResponsesMessageItem content)
  | Text.null content = []
  | otherwise = [MessageInput (LLMMessage Assistant [TextPart content])]
responseOutputItem ResponsesIgnoredItem = []

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

data ResponsesResponse = ResponsesResponse
  { responsesModel :: Maybe Text
  , responsesStatus :: Maybe Text
  , responsesOutput :: [ResponsesOutputItem]
  , responsesUsage :: Maybe LLMUsage
  }

instance FromJSON ResponsesResponse where
  parseJSON =
    withObject "ResponsesResponse" $ \objectValue ->
      ResponsesResponse
        <$> objectValue .:? "model"
        <*> objectValue .:? "status"
        <*> objectValue .:? "output" .!= []
        <*> objectValue .:? "usage"

newtype ResponsesCompactionResponse = ResponsesCompactionResponse
  { responsesCompactionOutput :: [Value]
  }

instance FromJSON ResponsesCompactionResponse where
  parseJSON =
    withObject "ResponsesCompactionResponse" $ \objectValue ->
      ResponsesCompactionResponse <$> objectValue .:? "output" .!= []

fromResponsesCompactionOutputItem :: Value -> Parser LLMInputItem
fromResponsesCompactionOutputItem =
  withObject "ResponsesCompactionOutputItem" $ \objectValue -> do
    itemType <- objectValue .: "type"
    case itemType of
      Aeson.String "compaction" ->
        CompactionInput . CompactionItem <$> objectValue .: "encrypted_content"
      Aeson.String "message" -> do
        role <- parseResponsesRole =<< objectValue .: "role"
        if role /= User
          then fail "Responses compaction response may only retain user message items"
          else pure ()
        content <- parseResponsesMessageContent objectValue
        pure (MessageInput (LLMMessage role [TextPart content]))
      Aeson.String _ -> fail "unsupported item in Responses compaction response"
      _ -> fail "Responses compaction output item type must be a string"

parseResponsesRole :: Text -> Parser LLMRole
parseResponsesRole "system" = pure System
parseResponsesRole "user" = pure User
parseResponsesRole "assistant" = pure Assistant
parseResponsesRole "tool" = pure Tool
parseResponsesRole _ = fail "unknown Responses message role"

parseResponsesMessageContent :: Aeson.Object -> Parser Text
parseResponsesMessageContent objectValue = do
  contentValue <- objectValue .:? "content" .!= Aeson.Null
  case contentValue of
    Aeson.String text -> pure text
    Aeson.Array items ->
      Text.intercalate "\n" <$> traverse parseResponsesContentPartText (toList items)
    Aeson.Null -> pure ""
    _ -> fail "Responses compaction message content must be a string or array"

data ResponsesOutputItem
  = ResponsesMessageItem Text
  | ResponsesFunctionCallItem ToolCall
  | ResponsesReasoningItem ReasoningItem
  | ResponsesIgnoredItem

instance FromJSON ResponsesOutputItem where
  parseJSON =
    withObject "ResponsesOutputItem" $ \objectValue -> do
      itemType <- objectValue .: "type"
      case itemType of
        Aeson.String "message" ->
          ResponsesMessageItem <$> parseResponsesMessageText objectValue
        Aeson.String "function_call" ->
          ResponsesFunctionCallItem
            <$> ( ToolCall
                    <$> objectValue .: "call_id"
                    <*> objectValue .: "name"
                    <*> (normalizeToolArguments <$> objectValue .: "arguments")
                )
        Aeson.String "reasoning" ->
          ResponsesReasoningItem
            <$> ( ReasoningItem
                    <$> objectValue .:? "id"
                    <*> objectValue .: "encrypted_content"
                    <*> objectValue .:? "summary" .!= Aeson.Array mempty
                )
        Aeson.String _ -> pure ResponsesIgnoredItem
        _ -> fail "Responses output item type must be a string"

parseResponsesMessageText :: Aeson.Object -> Parser Text
parseResponsesMessageText objectValue = do
  contentValue <- objectValue .:? "content" .!= Aeson.Null
  case contentValue of
    Aeson.String text -> pure text
    Aeson.Array items ->
      Text.intercalate "\n" <$> traverse parseResponsesContentPartText (toList items)
    Aeson.Null -> pure ""
    _ -> fail "Responses message content must be a string or array"

parseResponsesContentPartText :: Value -> Parser Text
parseResponsesContentPartText =
  withObject "ResponsesMessageContentPart" $ \objectValue -> do
    partType <- objectValue .:? "type" .!= Aeson.String "output_text"
    case partType of
      Aeson.String "output_text" -> objectValue .: "text"
      Aeson.String "input_text" -> objectValue .: "text"
      Aeson.String "text" -> objectValue .: "text"
      Aeson.String "refusal" -> objectValue .:? "refusal" .!= ""
      Aeson.String _ -> pure ""
      _ -> fail "Responses message content part type must be a string"

responsesOutputText :: [ResponsesOutputItem] -> [Text]
responsesOutputText items =
  [text | ResponsesMessageItem text <- items, not (Text.null text)]

responsesOutputToolCalls :: ResponsesOutputItem -> [ToolCall]
responsesOutputToolCalls (ResponsesFunctionCallItem toolCall) = [toolCall]
responsesOutputToolCalls _ = []

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
      rawArguments <- functionValue .:? "arguments" .!= Aeson.Null
      GPTToolCall
        <$> objectValue .: "id"
        <*> functionValue .: "name"
        <*> pure (normalizeToolArguments rawArguments)

normalizeToolArguments :: Value -> Value
normalizeToolArguments (Aeson.String text) =
  case decode (LazyByteString.fromStrict (TextEncoding.encodeUtf8 text)) of
    Just value -> value
    Nothing -> Aeson.String text
normalizeToolArguments value = value

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

imageDetailName :: ImageDetail -> Text
imageDetailName Auto = "auto"
imageDetailName Low = "low"
imageDetailName High = "high"

nonEmpty :: Aeson.ToJSON value => Key -> [value] -> Maybe Pair
nonEmpty _ [] = Nothing
nonEmpty key values = Just (key .= values)

nonEmptyText :: Key -> Text -> Maybe Pair
nonEmptyText _ "" = Nothing
nonEmptyText key value = Just (key .= value)

isResponsesEndpoint :: String -> Bool
isResponsesEndpoint endpoint =
  "/responses" `isSuffixOf` stripTrailingSlash endpoint
