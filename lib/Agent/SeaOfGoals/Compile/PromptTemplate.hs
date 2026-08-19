module Agent.SeaOfGoals.Compile.PromptTemplate
  ( embedTextFile
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Language.Haskell.TH
  ( Exp
  , Q
  )
import Language.Haskell.TH.Syntax
  ( lift
  , qAddDependentFile
  , runIO
  )

embedTextFile :: FilePath -> Q Exp
embedTextFile path = do
  qAddDependentFile path
  content <- runIO (readFile path)
  lift (Text.pack content :: Text)
