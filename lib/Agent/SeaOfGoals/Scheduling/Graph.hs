module Agent.SeaOfGoals.Scheduling.Graph
  ( reduceGoalGraph
  )
where

import Agent.SeaOfGoals.Scheduling.Agentic
  ( GoalGraph (..)
  )
import Data.Set qualified as Set

reduceGoalGraph :: GoalGraph -> GoalGraph
reduceGoalGraph graph =
  graph
    { goalGraphEdges =
        Set.filter isMinimalEdge (goalGraphEdges graph)
    }
 where
  isMinimalEdge (from, to) =
    not (reachableWithoutEdge from to (from, to))

  reachableWithoutEdge start target removedEdge =
    go Set.empty [start]
   where
    go _ [] = False
    go visited (current : rest)
      | current == target = True
      | current `Set.member` visited = go visited rest
      | otherwise =
          go
            (Set.insert current visited)
            (Set.toList (directChildrenWithout removedEdge current) <> rest)

  directChildrenWithout removedEdge node =
    Set.fromList
      [ child
      | edge@(from, child) <- Set.toList (goalGraphEdges graph)
      , edge /= removedEdge
      , from == node
      ]
