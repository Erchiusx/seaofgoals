module Agent.SeaOfGoals.Scheduling.MergeScheduler
  ( MergeDependencyUpdate (..)
  , applyMergeConflict
  , goalGraphAddEdge
  , goalGraphDescendants
  )
where

import Agent.SeaOfGoals.Scheduling.Agentic
  ( GoalGraph (..)
  , GoalNode (..)
  , GoalNodeId
  )
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

data MergeDependencyUpdate = MergeDependencyUpdate
  { mergeDependencyFormer :: GoalNodeId
  , mergeDependencyLatter :: GoalNodeId
  , mergeDependencyGraph :: GoalGraph
  , mergeDependencyInvalidated :: Set GoalNodeId
  }
  deriving stock (Eq, Show)

applyMergeConflict
  :: GoalGraph -> GoalNodeId -> GoalNodeId -> Either Text MergeDependencyUpdate
applyMergeConflict graph left right = do
  leftNode <- lookupGoalNode graph left
  rightNode <- lookupGoalNode graph right
  let
    (former, latter) =
      orderBySerialIndex leftNode rightNode
    updatedGraph = goalGraphAddEdge former latter graph
  pure
    MergeDependencyUpdate
      { mergeDependencyFormer = former
      , mergeDependencyLatter = latter
      , mergeDependencyGraph = updatedGraph
      , mergeDependencyInvalidated =
          Set.insert latter (goalGraphDescendants updatedGraph latter)
      }

goalGraphAddEdge :: GoalNodeId -> GoalNodeId -> GoalGraph -> GoalGraph
goalGraphAddEdge former latter graph =
  graph{goalGraphEdges = Set.insert (former, latter) (goalGraphEdges graph)}

goalGraphDescendants :: GoalGraph -> GoalNodeId -> Set GoalNodeId
goalGraphDescendants graph start =
  go Set.empty [start]
 where
  go visited [] = Set.delete start visited
  go visited (node : rest)
    | Set.member node visited = go visited rest
    | otherwise =
        let children = directChildren graph node
         in go (Set.insert node visited) (Set.toList children <> rest)

directChildren :: GoalGraph -> GoalNodeId -> Set GoalNodeId
directChildren graph node =
  Set.fromList
    [ to
    | (from, to) <- Set.toList (goalGraphEdges graph)
    , from == node
    ]

lookupGoalNode :: GoalGraph -> GoalNodeId -> Either Text GoalNode
lookupGoalNode graph nodeId =
  case Map.lookup nodeId (goalGraphNodes graph) of
    Just node -> Right node
    Nothing -> Left "merge conflict references an unknown goal node"

orderBySerialIndex :: GoalNode -> GoalNode -> (GoalNodeId, GoalNodeId)
orderBySerialIndex left right
  | goalNodeSerialIndex left <= goalNodeSerialIndex right =
      (goalNodeId left, goalNodeId right)
  | otherwise =
      (goalNodeId right, goalNodeId left)
