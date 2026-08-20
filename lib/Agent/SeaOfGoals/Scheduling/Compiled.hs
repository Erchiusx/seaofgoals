module Agent.SeaOfGoals.Scheduling.Compiled
  ( compiledGraphToGoalGraph
  )
where

import Agent.SeaOfGoals.Compile.Compiler
  ( CompiledGoal (..)
  , CompiledGoalGraph (..)
  )
import Agent.SeaOfGoals.Scheduling.Agentic
  ( GoalGraph (..)
  , GoalNode (..)
  , GoalNodeId (..)
  )
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set

compiledGraphToGoalGraph :: CompiledGoalGraph -> GoalGraph
compiledGraphToGoalGraph graph =
  GoalGraph
    { goalGraphNodes =
        Map.fromList
          [ (goalNodeId node, node)
          | node <- nodes
          ]
    , goalGraphEdges =
        Set.fromList
          [ (GoalNodeId predecessor, GoalNodeId (compiledGoalId goal))
          | goal <- compiledGoals graph
          , predecessor <- compiledGoalPredecessors goal
          ]
    }
 where
  nodes =
    [ GoalNode
        { goalNodeId = GoalNodeId (compiledGoalId goal)
        , goalNodeName = compiledGoalName goal
        , goalNodePrompt = compiledGoalEnteringPrompt goal
        , goalNodeSerialIndex = serialIndex
        }
    | (serialIndex, goal) <- zip [0 ..] (compiledGoals graph)
    ]
