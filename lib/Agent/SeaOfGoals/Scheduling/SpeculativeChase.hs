module Agent.SeaOfGoals.Scheduling.SpeculativeChase
  ( EffectSet (..)
  , GoalEpoch (..)
  , SpeculativeGoalStatus (..)
  , SpeculativeState (..)
  , initialSpeculativeState
  , recordEffects
  , finishGoal
  , restartGoal
  )
where

import Agent.SeaOfGoals.Scheduling.Agentic (GoalNode (..), GoalNodeId)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set

-- | Accesses observed in one speculative workspace epoch.
data EffectSet = EffectSet
  { effectReads :: Set FilePath
  , effectWrites :: Set FilePath
  }
  deriving stock (Eq, Show)

newtype GoalEpoch = GoalEpoch {unGoalEpoch :: Int}
  deriving stock (Eq, Ord, Show)

data SpeculativeGoalStatus
  = SpeculativeRunning GoalEpoch
  | SpeculativeFinished GoalEpoch
  | SpeculativeAborted GoalEpoch
  | SpeculativeCommitted GoalEpoch
  deriving stock (Eq, Show)

data SpeculativeState = SpeculativeState
  { speculativeGoalOrder :: [GoalNodeId]
  , speculativeGoalStatus :: Map GoalNodeId SpeculativeGoalStatus
  , speculativeGoalEffects :: Map GoalNodeId EffectSet
  , speculativeGoalBase :: Map GoalNodeId Int
  , speculativeNextCommit :: Int
  }
  deriving stock (Eq, Show)

initialSpeculativeState :: [GoalNode] -> SpeculativeState
initialSpeculativeState nodes =
  SpeculativeState
    { speculativeGoalOrder = goalNodeId <$> ordered
    , speculativeGoalStatus = Map.fromList [(goalNodeId node, SpeculativeRunning (GoalEpoch 0)) | node <- ordered]
    , speculativeGoalEffects = Map.empty
    , speculativeGoalBase = Map.fromList [(goalNodeId node, 0) | node <- ordered]
    , speculativeNextCommit = 0
    }
 where
  ordered = sortOn goalNodeSerialIndex nodes

-- | Add an effect batch. Any later live goal whose reads or writes overlap an
-- earlier goal's writes is marked aborted. The caller kills its process and
-- later calls 'restartGoal' after the committed prefix advances.
recordEffects :: GoalNodeId -> EffectSet -> SpeculativeState -> (SpeculativeState, [GoalNodeId])
recordEffects goalId batch state =
  ( state {speculativeGoalStatus = nextStatuses, speculativeGoalEffects = nextEffects}
  , aborted
  )
 where
  nextEffects = Map.insertWith appendEffects goalId batch (speculativeGoalEffects state)
  aborted =
    [ later
    | (earlier, later) <- orderedPairs (speculativeGoalOrder state)
    , conflicts state earlier later nextEffects
    , isLive later (speculativeGoalStatus state)
    ]
  nextStatuses = foldr abortGoal (speculativeGoalStatus state) aborted

  abortGoal later = Map.adjust abort later
  abort (SpeculativeRunning epoch) = SpeculativeAborted epoch
  abort (SpeculativeFinished epoch) = SpeculativeAborted epoch
  abort status = status

finishGoal :: GoalNodeId -> SpeculativeState -> (SpeculativeState, [GoalNodeId])
finishGoal goalId state =
  advanceCommitted
    state
      { speculativeGoalStatus = Map.adjust finish goalId (speculativeGoalStatus state)
      }
 where
  finish (SpeculativeRunning epoch) = SpeculativeFinished epoch
  finish status = status

restartGoal :: GoalNodeId -> SpeculativeState -> SpeculativeState
restartGoal goalId state =
  state
    { speculativeGoalStatus = Map.adjust restart goalId (speculativeGoalStatus state)
    , speculativeGoalEffects = Map.delete goalId (speculativeGoalEffects state)
    , speculativeGoalBase = Map.insert goalId (speculativeNextCommit state) (speculativeGoalBase state)
    }
 where
  restart (SpeculativeAborted (GoalEpoch epoch)) = SpeculativeRunning (GoalEpoch (epoch + 1))
  restart status = status

advanceCommitted :: SpeculativeState -> (SpeculativeState, [GoalNodeId])
advanceCommitted state =
  case drop (speculativeNextCommit state) (speculativeGoalOrder state) of
    goalId : _
      | Just (SpeculativeFinished epoch) <- Map.lookup goalId (speculativeGoalStatus state) ->
          let
            committedState =
              state
                { speculativeGoalStatus = Map.insert goalId (SpeculativeCommitted epoch) (speculativeGoalStatus state)
                , speculativeNextCommit = speculativeNextCommit state + 1
                }
            (nextState, laterCommitted) = advanceCommitted committedState
           in (nextState, goalId : laterCommitted)
    _ -> (state, [])

orderedPairs :: [a] -> [(a, a)]
orderedPairs [] = []
orderedPairs (earlier : rest) = [(earlier, later) | later <- rest] <> orderedPairs rest

conflicts :: SpeculativeState -> GoalNodeId -> GoalNodeId -> Map GoalNodeId EffectSet -> Bool
conflicts state earlier later effects =
  case (Map.lookup earlier effects, Map.lookup later effects) of
    (Just earlierEffects, Just laterEffects)
      | goalIndex earlier (speculativeGoalOrder state) >= baseIndex later state ->
      not $
        Set.null
          ( effectWrites earlierEffects
              `Set.intersection` (effectReads laterEffects <> effectWrites laterEffects)
          )
    _ -> False

baseIndex :: GoalNodeId -> SpeculativeState -> Int
baseIndex goalId state = Map.findWithDefault 0 goalId (speculativeGoalBase state)

goalIndex :: GoalNodeId -> [GoalNodeId] -> Int
goalIndex goalId = go 0
 where
  go _ [] = maxBound
  go index (candidate : remaining)
    | candidate == goalId = index
    | otherwise = go (index + 1) remaining

isLive :: GoalNodeId -> Map GoalNodeId SpeculativeGoalStatus -> Bool
isLive goalId statuses =
  case Map.lookup goalId statuses of
    Just SpeculativeRunning{} -> True
    Just SpeculativeFinished{} -> True
    _ -> False

appendEffects :: EffectSet -> EffectSet -> EffectSet
appendEffects newer older =
  EffectSet
    { effectReads = effectReads newer <> effectReads older
    , effectWrites = effectWrites newer <> effectWrites older
    }
