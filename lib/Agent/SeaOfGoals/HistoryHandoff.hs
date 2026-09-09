module Agent.SeaOfGoals.HistoryHandoff
  ( GoalHistories
  , historiesForGoal
  , newGoalHistories
  , rememberGoalHistory
  , ownHistoryAfterInitialItems
  )
where

import Agent.SeaOfGoals.LLM (LLMInputItem)
import Agent.SeaOfGoals.Scheduling.Agentic
  ( GoalGraph (..)
  , GoalNode (..)
  , GoalNodeId
  )
import Agent.SeaOfGoals.Scheduling.SerialScheduler (goalPredecessors)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set

type GoalHistories = IORef (Map.Map GoalNodeId [LLMInputItem])

newGoalHistories :: IO GoalHistories
newGoalHistories = newIORef Map.empty

rememberGoalHistory :: GoalHistories -> GoalNodeId -> [LLMInputItem] -> IO ()
rememberGoalHistory histories goalId history =
  modifyIORef' histories (Map.insert goalId history)

historiesForGoal
  :: GoalGraph -> GoalHistories -> GoalNodeId -> IO [LLMInputItem]
historiesForGoal graph histories goalId = do
  historyMap <- readIORef histories
  pure
    ( concat
        [ history
        | predecessor <- transitivePredecessorsInSerialOrder graph goalId
        , Just history <- [Map.lookup predecessor historyMap]
        ]
    )

ownHistoryAfterInitialItems :: Int -> [LLMInputItem] -> [LLMInputItem]
ownHistoryAfterInitialItems initialItemCount = drop initialItemCount

transitivePredecessorsInSerialOrder :: GoalGraph -> GoalNodeId -> [GoalNodeId]
transitivePredecessorsInSerialOrder graph goalId =
  sortOn goalOrder (Set.toList (go Set.empty (goalPredecessors graph goalId)))
 where
  goalOrder predecessor =
    maybe
      maxBound
      goalNodeSerialIndex
      (Map.lookup predecessor (goalGraphNodes graph))

  go seen frontier =
    case Set.minView frontier of
      Nothing -> seen
      Just (current, rest)
        | current `Set.member` seen -> go seen rest
        | otherwise ->
            go
              (Set.insert current seen)
              (rest <> goalPredecessors graph current)
