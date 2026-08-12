module Agent.SeaOfGoals.Tools
  ( ToolHandler
  , ToolSpec (..)
  , objectToolSpec
  , runToolHandler
  , toolSpecToOpenAITool
  )
where

import Agent.SeaOfGoals.LLM
  ( ToolCall (..)
  , ToolResult (..)
  )
import Agent.SeaOfGoals.Trace (HarnessEvent)
import Data.Aeson
  ( Value
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as AesonKey
import Data.Text (Text)

data ToolSpec = ToolSpec
  { toolName :: Text
  , toolDescription :: Text
  , toolParameters :: Value
  , toolHandler :: ToolCall -> IO (ToolResult, [HarnessEvent])
  }

type ToolHandler = ToolCall -> IO (ToolResult, [HarnessEvent])

runToolHandler :: ToolSpec -> ToolHandler
runToolHandler = toolHandler

objectToolSpec
  :: Text -> Text -> [(Text, Value)] -> [Text] -> ToolHandler -> ToolSpec
objectToolSpec name description properties required handler =
  ToolSpec
    { toolName = name
    , toolDescription = description
    , toolParameters =
        object
          [ "type" .= ("object" :: Text)
          , "properties" .= object (fmap firstKey properties)
          , "required" .= required
          ]
    , toolHandler = handler
    }

toolSpecToOpenAITool :: ToolSpec -> Value
toolSpecToOpenAITool spec =
  object
    [ "type" .= ("function" :: Text)
    , "function"
        .= object
          [ "name" .= toolName spec
          , "description" .= toolDescription spec
          , "parameters" .= toolParameters spec
          ]
    ]

firstKey :: (Text, Value) -> (AesonKey.Key, Value)
firstKey (key, value) = (AesonKey.fromText key, value)
