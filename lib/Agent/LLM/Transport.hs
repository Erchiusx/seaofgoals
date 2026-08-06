module Agent.LLM.Transport
  ( TransportRequest (..)
  , TransportResponse (..)
  , sendJSON
  )
where

import Agent.SeaOfGoals.LLM (LLMError (..))
import Control.Exception (try)
import Data.Aeson (Value, decode, encode)
import Data.ByteString.Char8 qualified as ByteString
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.CaseInsensitive qualified as CaseInsensitive
import Data.Text qualified as Text
import Network.HTTP.Client
  ( RequestBody (RequestBodyLBS)
  , httpLbs
  , method
  , newManager
  , parseRequest
  , requestBody
  , requestHeaders
  , responseBody
  , responseHeaders
  , responseStatus
  )
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header qualified as Header
import Network.HTTP.Types.Status (statusCode)

data TransportRequest = TransportRequest
  { transportMethod :: String
  , transportUrl :: String
  , transportHeaders :: [(String, String)]
  , transportBody :: Maybe Value
  }
  deriving stock (Eq, Show)

data TransportResponse = TransportResponse
  { transportStatus :: Int
  , transportResponseHeaders :: [(String, String)]
  , transportResponseBody :: String
  , transportResponseJSON :: Maybe Value
  }
  deriving stock (Eq, Show)

sendJSON :: TransportRequest -> IO (Either LLMError TransportResponse)
sendJSON transportRequest = do
  parsedRequest <- tryParseRequest (transportUrl transportRequest)
  case parsedRequest of
    Left err -> pure (Left err)
    Right baseRequest -> do
      manager <- newManager tlsManagerSettings
      rawResponse <-
        httpLbs (withTransportRequest baseRequest transportRequest) manager
      let
        responseStatusCode = statusCode (responseStatus rawResponse)
        rawBody = responseBody rawResponse
        transportResponse =
          TransportResponse
            { transportStatus = responseStatusCode
            , transportResponseHeaders = decodeHeaders (responseHeaders rawResponse)
            , transportResponseBody = LazyByteString.unpack rawBody
            , transportResponseJSON = decode rawBody
            }
      pure $
        if responseStatusCode >= 200 && responseStatusCode < 300
          then Right transportResponse
          else Left (LLMTransportError (Text.pack (transportResponseBody transportResponse)))

tryParseRequest :: String -> IO (Either LLMError HTTP.Request)
tryParseRequest url = do
  result <- try (parseRequest url)
  case result of
    Left (err :: HTTP.HttpException) -> pure (Left (LLMTransportError (Text.pack (show err))))
    Right request -> pure (Right request)

withTransportRequest
  :: HTTP.Request
  -> TransportRequest
  -> HTTP.Request
withTransportRequest baseRequest transportRequest =
  baseRequest
    { method = ByteString.pack (transportMethod transportRequest)
    , requestHeaders =
        encodeHeaders
          ( ("Content-Type", "application/json")
              : ("Accept", "application/json")
              : transportHeaders transportRequest
          )
    , requestBody =
        maybe mempty (RequestBodyLBS . encode) (transportBody transportRequest)
    }

encodeHeaders
  :: [(String, String)] -> [(Header.HeaderName, ByteString.ByteString)]
encodeHeaders =
  fmap
    ( \(name, value) ->
        (CaseInsensitive.mk (ByteString.pack name), ByteString.pack value)
    )

decodeHeaders
  :: [(Header.HeaderName, ByteString.ByteString)] -> [(String, String)]
decodeHeaders =
  fmap
    ( \(name, value) ->
        (ByteString.unpack (CaseInsensitive.original name), ByteString.unpack value)
    )
