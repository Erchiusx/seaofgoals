module Agent.SeaOfGoals.Scheduling.ConcurrentChase
  ( ConcurrentChaseConflict (..)
  , ConcurrentChaseResult (..)
  , ConcurrentChaseRunner (..)
  , runConcurrentChase
  , runConcurrentChaseWithPlanner
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
  , startReadyGoalsWith
  )
import Control.Concurrent
  ( forkIO
  , newEmptyMVar
  , putMVar
  , takeMVar
  , threadDelay
  )
import Control.Concurrent.Async
  ( async
  , cancel
  , poll
  )
import Control.Exception
  ( SomeException
  , displayException
  , try
  )
import Control.Monad
  ( filterM
  , foldM
  , forM
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

{- | Run a graph while a planner goal publishes independent plan artifacts.
The planner itself is started immediately; other goals additionally require
their own plan to be visible before they are launched.
-}
runConcurrentChaseWithPlanner
  :: ConcurrentChaseRunner
  -> GoalGraph
  -> GoalNodeId
  -> (GoalNodeId -> IO Bool)
  -> IO (Either Text ConcurrentChaseResult)
runConcurrentChaseWithPlanner runner graph plannerId planReady =
  loop (initialChaseState graph) [] [] 0 Map.empty
 where
  allGoals = Map.keysSet (goalGraphNodes graph)

  loop state runOrder mergeOrder replanCount running
    | Map.keysSet (chaseCompleted state) == allGoals =
        pure
          ( Right
              ConcurrentChaseResult
                { concurrentChaseCompleted = chaseCompleted state
                , concurrentChaseRunOrder = runOrder
                , concurrentChaseMergeOrder = mergeOrder
                , concurrentChaseReplans = replanCount
                , concurrentChaseFinalState = state
                }
          )
    | otherwise = do
        readyIds <-
          Set.fromList . fmap fst
            <$> filterM (fmap snd . planStatus) (Map.toList (goalGraphNodes graph))
        let (started, launches) =
              startReadyGoalsWith
                (`Set.member` readyIds)
                (concurrentChaseMaxParallelism runner - Map.size running)
                state
        newRunning <-
          foldM
            ( \acc launch -> do
                task <- async (concurrentChaseRunGoal runner (goalLaunchNode launch))
                pure
                  ( Map.insert
                      (goalNodeId (goalLaunchNode launch))
                      (goalLaunchNode launch, task)
                      acc
                  )
            )
            running
            launches
        if Map.null newRunning
          then
            pure
              (Left "planner chase is blocked by unsatisfied dependencies or missing plans")
          else do
            finished <- firstFinished newRunning
            case finished of
              Nothing -> do
                threadDelay 10000
                loop started runOrder mergeOrder replanCount newRunning
              Just (node, task, outcome) ->
                let remaining = Map.delete (goalNodeId node) newRunning
                 in processCompleted started runOrder mergeOrder replanCount remaining node outcome
   where
    planStatus (goalId, _node)
      | goalId == plannerId = pure (goalId, True)
      | otherwise = (goalId,) <$> planReady goalId

    firstFinished runningGoals =
      firstJust
        <$> mapM
          ( \(node, task) -> do
              outcome <- poll task
              pure ((node,task,) <$> outcome)
          )
          (Map.elems runningGoals)

    firstJust [] = Nothing
    firstJust (item : rest) = case item of
      Just value -> Just value
      Nothing -> firstJust rest

    processCompleted state runOrder mergeOrder replanCount running node outcome =
      case outcome of
        Left err -> pure (Left (Text.pack (displayException err)))
        Right (Left err) -> pure (Left err)
        Right (Right result)
          | agentRunResultGoal result /= goalNodeId node ->
              pure (Left "agent result goal id does not match scheduled goal")
          | otherwise -> do
              merged <- concurrentChaseMergeGoal runner result
              case merged of
                Left conflict
                  | replanCount >= concurrentChaseMaxReplans runner ->
                      pure (Left "planner chase exceeded max replans")
                  | otherwise ->
                      case replanForMergeConflict
                        (concurrentChaseConflictLeft conflict)
                        (concurrentChaseConflictRight conflict)
                        state of
                        Left err -> pure (Left err)
                        Right replanned -> do
                          let cancelled =
                                Set.difference
                                  (chaseRunning state)
                                  (chaseRunning replanned)
                          mapM_
                            (\goalId -> maybe (pure ()) (cancel . snd) (Map.lookup goalId running))
                            (Set.toList cancelled)
                          loop
                            replanned
                            (runOrder <> [goalNodeId node])
                            mergeOrder
                            (replanCount + 1)
                            (Map.withoutKeys running cancelled)
                Right () ->
                  case completeGoal result state of
                    Left err -> pure (Left err)
                    Right completed ->
                      loop
                        completed
                        (runOrder <> [goalNodeId node])
                        (mergeOrder <> [goalNodeId node])
                        replanCount
                        running

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
