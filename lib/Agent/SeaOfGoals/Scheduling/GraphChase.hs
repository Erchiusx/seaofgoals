module Agent.SeaOfGoals.Scheduling.GraphChase
  ( ChaseEvent (..)
  , ChaseState (..)
  , GoalLaunch (..)
  , completeGoal
  , initialChaseState
  , nextReadyGoals
  , replanForMergeConflict
  , startReadyGoals
  )
where

import Agent.SeaOfGoals.Scheduling.Agentic
  ( AgentRunResult (..)
  , GoalGraph (..)
  , GoalNode (..)
  , GoalNodeId
  )
import Agent.SeaOfGoals.Scheduling.MergeScheduler
  ( mergeDependencyGraph
  )
import Agent.SeaOfGoals.Scheduling.Replan
  ( ReplanInput (..)
  , ReplanResult (..)
  , replanAfterMergeConflict
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

data GoalLaunch = GoalLaunch
  { goalLaunchNode :: GoalNode
  }
  deriving stock (Eq, Show)

data ChaseEvent
  = ChaseGoalsStarted [GoalNodeId]
  | ChaseGoalCompleted GoalNodeId
  | ChaseConflictReplanned ReplanResult
  deriving stock (Eq, Show)

data ChaseState = ChaseState
  { chaseGraph :: GoalGraph
  , chaseCompleted :: Map GoalNodeId AgentRunResult
  , chaseQueued :: Set GoalNodeId
  , chaseRunning :: Set GoalNodeId
  , chaseEvents :: [ChaseEvent]
  }
  deriving stock (Eq, Show)

initialChaseState :: GoalGraph -> ChaseState
initialChaseState graph =
  ChaseState
    { chaseGraph = graph
    , chaseCompleted = Map.empty
    , chaseQueued = Map.keysSet (goalGraphNodes graph)
    , chaseRunning = Set.empty
    , chaseEvents = []
    }

nextReadyGoals :: ChaseState -> [GoalNode]
nextReadyGoals state =
  List.filter
    (\node -> Set.member (goalNodeId node) (chaseQueued state))
    (readyGoalNodes (chaseGraph state) (Map.keysSet (chaseCompleted state)))

startReadyGoals :: Int -> ChaseState -> (ChaseState, [GoalLaunch])
startReadyGoals maxCount state =
  (updatedState, fmap GoalLaunch selected)
 where
  selected =
    if maxCount <= 0
      then []
      else take maxCount (nextReadyGoals state)
  selectedIds = Set.fromList (fmap goalNodeId selected)
  updatedState
    | Set.null selectedIds = state
    | otherwise =
        appendChaseEvent (ChaseGoalsStarted (fmap goalNodeId selected)) $
          state
            { chaseQueued = Set.difference (chaseQueued state) selectedIds
            , chaseRunning = Set.union (chaseRunning state) selectedIds
            }

completeGoal :: AgentRunResult -> ChaseState -> Either Text ChaseState
completeGoal result state
  | goalId `Set.notMember` chaseRunning state =
      Left "completed goal was not running"
  | goalId `Map.notMember` goalGraphNodes (chaseGraph state) =
      Left "completed goal is unknown"
  | otherwise =
      Right $
        appendChaseEvent (ChaseGoalCompleted goalId) $
          state
            { chaseRunning = Set.delete goalId (chaseRunning state)
            , chaseCompleted = Map.insert goalId result (chaseCompleted state)
            }
 where
  goalId = agentRunResultGoal result

replanForMergeConflict
  :: GoalNodeId -> GoalNodeId -> ChaseState -> Either Text ChaseState
replanForMergeConflict left right state = do
  result <-
    replanAfterMergeConflict
      ReplanInput
        { replanInputGraph = chaseGraph state
        , replanInputCompleted = chaseCompleted state
        , replanInputQueued = chaseQueued state
        , replanInputRunning = chaseRunning state
        , replanInputConflictLeft = left
        , replanInputConflictRight = right
        }
  pure $
    appendChaseEvent (ChaseConflictReplanned result) $
      state
        { chaseGraph =
            mergeDependencyGraph (replanResultDependencyUpdate result)
        , chaseCompleted = replanResultCompleted result
        , chaseQueued = replanResultQueued result
        , chaseRunning =
            Set.difference
              (chaseRunning state)
              (replanResultCancelled result)
        }

appendChaseEvent :: ChaseEvent -> ChaseState -> ChaseState
appendChaseEvent event state =
  state{chaseEvents = chaseEvents state <> [event]}
