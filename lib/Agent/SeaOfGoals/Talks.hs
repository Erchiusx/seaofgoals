module Agent.SeaOfGoals.Talks
where

import Agent.SeaOfGoals.LLM

class History h where
  compose :: h -> [LLMMessage]
