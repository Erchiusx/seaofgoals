module Agent.SeaOfGoals.Scheduling.SerialScheduler
  ( SerialScheduler (..)
  , SerialSchedulerResult (..)
  , goalPredecessors
  , readyGoalNodes
  , runSerialScheduler
  )
where

import Agent.SeaOfGoals.Scheduling.Agentic
  ( AgentRunResult (..)
  , GoalGraph (..)
  , GoalNode (..)
  , GoalNodeId
  )
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

data SerialScheduler = SerialScheduler
  { serialSchedulerRunGoal :: GoalNode -> IO (Either Text AgentRunResult)
  }

data SerialSchedulerResult = SerialSchedulerResult
  { serialSchedulerCompleted :: Map GoalNodeId AgentRunResult
  , serialSchedulerRunOrder :: [GoalNodeId]
  }
  deriving stock (Eq, Show)

runSerialScheduler
  :: SerialScheduler -> GoalGraph -> IO (Either Text SerialSchedulerResult)
runSerialScheduler scheduler graph =
  case validateGraph graph of
    Just err -> pure (Left err)
    Nothing -> go Set.empty Map.empty []
 where
  allNodes = Map.keysSet (goalGraphNodes graph)

  go completed completedResults runOrder
    | completed == allNodes =
        pure
          ( Right
              SerialSchedulerResult
                { serialSchedulerCompleted = completedResults
                , serialSchedulerRunOrder = reverse runOrder
                }
          )
    | otherwise =
        case readyGoalNodes graph completed of
          [] ->
            pure (Left "serial scheduler is blocked by unsatisfied dependencies")
          node : _ -> do
            result <- serialSchedulerRunGoal scheduler node
            case result of
              Left err ->
                pure (Left err)
              Right runResult
                | agentRunResultGoal runResult /= goalNodeId node ->
                    pure (Left "agent result goal id does not match scheduled goal")
                | otherwise ->
                    go
                      (Set.insert (goalNodeId node) completed)
                      (Map.insert (goalNodeId node) runResult completedResults)
                      (goalNodeId node : runOrder)

readyGoalNodes :: GoalGraph -> Set GoalNodeId -> [GoalNode]
readyGoalNodes graph completed =
  List.sortOn
    goalNodeSerialIndex
    [ node
    | node <- Map.elems (goalGraphNodes graph)
    , let nodeId = goalNodeId node
    , Set.notMember nodeId completed
    , goalPredecessors graph nodeId `Set.isSubsetOf` completed
    ]

goalPredecessors :: GoalGraph -> GoalNodeId -> Set GoalNodeId
goalPredecessors graph nodeId =
  Set.fromList
    [ from
    | (from, to) <- Set.toList (goalGraphEdges graph)
    , to == nodeId
    ]

validateGraph :: GoalGraph -> Maybe Text
validateGraph graph =
  case unknownEdgeEndpoints graph of
    [] -> Nothing
    _ -> Just "goal graph has an edge that references an unknown node"

unknownEdgeEndpoints :: GoalGraph -> [GoalNodeId]
unknownEdgeEndpoints graph =
  [ endpoint
  | edge <- Set.toList (goalGraphEdges graph)
  , endpoint <- edgeEndpoints edge
  , Set.notMember endpoint nodeIds
  ]
 where
  nodeIds = Map.keysSet (goalGraphNodes graph)
  edgeEndpoints (from, to) = [from, to]
