module Agent.SeaOfGoals.Scheduling.Replan
  ( ReplanInput (..)
  , ReplanResult (..)
  , replanAfterMergeConflict
  )
where

import Agent.SeaOfGoals.Scheduling.Agentic
  ( AgentRunResult
  , GoalGraph (..)
  , GoalNode (..)
  , GoalNodeId
  )
import Agent.SeaOfGoals.Scheduling.MergeScheduler
  ( MergeDependencyUpdate (..)
  , applyMergeConflict
  )
import Agent.SeaOfGoals.Scheduling.SerialScheduler
  ( readyGoalNodes
  )
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

data ReplanInput = ReplanInput
  { replanInputGraph :: GoalGraph
  , replanInputCompleted :: Map GoalNodeId AgentRunResult
  , replanInputQueued :: Set GoalNodeId
  , replanInputRunning :: Set GoalNodeId
  , replanInputConflictLeft :: GoalNodeId
  , replanInputConflictRight :: GoalNodeId
  }

data ReplanResult = ReplanResult
  { replanResultDependencyUpdate :: MergeDependencyUpdate
  , replanResultCompleted :: Map GoalNodeId AgentRunResult
  , replanResultCancelled :: Set GoalNodeId
  , replanResultQueued :: Set GoalNodeId
  , replanResultReady :: [GoalNodeId]
  }
  deriving stock (Eq, Show)

replanAfterMergeConflict :: ReplanInput -> Either Text ReplanResult
replanAfterMergeConflict input = do
  update <-
    applyMergeConflict
      (replanInputGraph input)
      (replanInputConflictLeft input)
      (replanInputConflictRight input)
  let
    updatedGraph = mergeDependencyGraph update
    invalidated = mergeDependencyInvalidated update
    completed =
      Map.withoutKeys
        (replanInputCompleted input)
        invalidated
    completedIds = Map.keysSet completed
    cancelled =
      Set.intersection invalidated $
        replanInputQueued input <> replanInputRunning input
    queued =
      Set.union
        (Set.difference (replanInputQueued input) invalidated)
        (Set.difference invalidated completedIds)
    ready =
      readyGoalIds updatedGraph completedIds queued
  pure
    ReplanResult
      { replanResultDependencyUpdate = update
      , replanResultCompleted = completed
      , replanResultCancelled = cancelled
      , replanResultQueued = queued
      , replanResultReady = ready
      }

readyGoalIds :: GoalGraph -> Set GoalNodeId -> Set GoalNodeId -> [GoalNodeId]
readyGoalIds graph completed queued =
  fmap goalNodeId $
    List.filter
      (\node -> Set.member (goalNodeId node) queued)
      (readyGoalNodes graph completed)
