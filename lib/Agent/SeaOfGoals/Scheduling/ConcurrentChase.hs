module Agent.SeaOfGoals.Scheduling.ConcurrentChase
  ( ConcurrentChaseConflict (..)
  , ConcurrentChaseResult (..)
  , ConcurrentChaseRunner (..)
  , runConcurrentChase
  )
where

import Agent.SeaOfGoals.Scheduling.Agentic
  ( AgentRunResult (..)
  , GoalGraph (..)
  , GoalNode (..)
  , GoalNodeId
  )
import Agent.SeaOfGoals.Scheduling.GraphChase
  ( ChaseState (..)
  , GoalLaunch (..)
  , completeGoal
  , initialChaseState
  , replanForMergeConflict
  , startReadyGoals
  )
import Control.Concurrent
  ( forkIO
  , newEmptyMVar
  , putMVar
  , takeMVar
  )
import Control.Exception
  ( SomeException
  , displayException
  , try
  )
import Control.Monad
  ( forM
  )
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

data ConcurrentChaseConflict = ConcurrentChaseConflict
  { concurrentChaseConflictLeft :: GoalNodeId
  , concurrentChaseConflictRight :: GoalNodeId
  , concurrentChaseConflictReason :: Text
  }
  deriving stock (Eq, Show)

data ConcurrentChaseRunner = ConcurrentChaseRunner
  { concurrentChaseMaxParallelism :: Int
  , concurrentChaseMaxReplans :: Int
  , concurrentChaseRunGoal :: GoalNode -> IO (Either Text AgentRunResult)
  , concurrentChaseMergeGoal
      :: AgentRunResult -> IO (Either ConcurrentChaseConflict ())
  }

data ConcurrentChaseResult = ConcurrentChaseResult
  { concurrentChaseCompleted :: Map GoalNodeId AgentRunResult
  , concurrentChaseRunOrder :: [GoalNodeId]
  , concurrentChaseMergeOrder :: [GoalNodeId]
  , concurrentChaseReplans :: Int
  , concurrentChaseFinalState :: ChaseState
  }
  deriving stock (Eq, Show)

runConcurrentChase
  :: ConcurrentChaseRunner
  -> GoalGraph
  -> IO (Either Text ConcurrentChaseResult)
runConcurrentChase runner graph
  | concurrentChaseMaxParallelism runner <= 0 =
      pure (Left "concurrent chase max parallelism must be positive")
  | concurrentChaseMaxReplans runner < 0 =
      pure (Left "concurrent chase max replans must be non-negative")
  | otherwise =
      go (initialChaseState graph) [] [] 0
 where
  allGoals = Map.keysSet (goalGraphNodes graph)

  go state runOrder mergeOrder replanCount
    | Map.keysSet (chaseCompleted state) == allGoals =
        pure $
          Right
            ConcurrentChaseResult
              { concurrentChaseCompleted = chaseCompleted state
              , concurrentChaseRunOrder = runOrder
              , concurrentChaseMergeOrder = mergeOrder
              , concurrentChaseReplans = replanCount
              , concurrentChaseFinalState = state
              }
    | Set.null (chaseQueued state) && Set.null (chaseRunning state) =
        pure (Left "concurrent chase is blocked by unsatisfied dependencies")
    | otherwise = do
        let (runningState, launches) =
              startReadyGoals (concurrentChaseMaxParallelism runner) state
        if null launches
          then pure (Left "concurrent chase has no ready goals to run")
          else do
            batch <- runLaunches runner launches
            case firstRunFailure batch of
              Just err -> pure (Left err)
              Nothing ->
                processBatch runningState runOrder mergeOrder replanCount $
                  sortBatchBySerial batch

  processBatch state runOrder mergeOrder replanCount [] =
    go state runOrder mergeOrder replanCount
  processBatch state runOrder mergeOrder replanCount ((node, Right result) : rest)
    | goalNodeId node `Set.notMember` chaseRunning state =
        processBatch state runOrder mergeOrder replanCount rest
    | agentRunResultGoal result /= goalNodeId node =
        pure (Left "agent result goal id does not match launched goal")
    | otherwise = do
        mergeResult <- concurrentChaseMergeGoal runner result
        case mergeResult of
          Right () ->
            case completeGoal result state of
              Left err -> pure (Left err)
              Right completedState ->
                processBatch
                  completedState
                  (runOrder <> [goalNodeId node])
                  (mergeOrder <> [goalNodeId node])
                  replanCount
                  rest
          Left conflict
            | replanCount >= concurrentChaseMaxReplans runner ->
                pure (Left "concurrent chase exceeded max replans")
            | otherwise ->
                case replanForMergeConflict
                  (concurrentChaseConflictLeft conflict)
                  (concurrentChaseConflictRight conflict)
                  state of
                  Left err -> pure (Left err)
                  Right replannedState ->
                    processBatch
                      replannedState
                      (runOrder <> [goalNodeId node])
                      mergeOrder
                      (replanCount + 1)
                      rest
  processBatch _ _ _ _ ((_, Left err) : _) =
    pure (Left err)

runLaunches
  :: ConcurrentChaseRunner
  -> [GoalLaunch]
  -> IO [(GoalNode, Either Text AgentRunResult)]
runLaunches runner launches = do
  vars <-
    forM launches $ \launch -> do
      var <- newEmptyMVar
      _ <- forkIO (runOne launch var)
      pure var
  forM vars takeMVar
 where
  runOne launch var = do
    outcome <- try (concurrentChaseRunGoal runner (goalLaunchNode launch))
    putMVar var $
      case outcome of
        Right result -> (goalLaunchNode launch, result)
        Left err ->
          ( goalLaunchNode launch
          , Left (Text.pack (displayException (err :: SomeException)))
          )

firstRunFailure :: [(GoalNode, Either Text AgentRunResult)] -> Maybe Text
firstRunFailure results =
  case [err | (_, Left err) <- results] of
    err : _ -> Just err
    [] -> Nothing

sortBatchBySerial
  :: [(GoalNode, Either Text AgentRunResult)]
  -> [(GoalNode, Either Text AgentRunResult)]
sortBatchBySerial =
  List.sortOn (goalNodeSerialIndex . fst)
