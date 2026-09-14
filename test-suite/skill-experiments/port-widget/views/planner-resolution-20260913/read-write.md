# port-widget planner-resolution comparison

Model: `gpt-5.6`

| Mode | Wall time | Result |
| --- | ---: | --- |
| Single Pi baseline | 191.9s | checker passed |
| Concurrent SOG | 459.4s | checker passed |

## Single Pi baseline

The baseline goal mapping is post-hoc because one Pi process executes the raw
skill. Turns 6-8 write several implementation goals together.

| Goal work | Read rounds | Read time | Write rounds | Write time |
| --- | ---: | ---: | ---: | ---: |
| G000-G001: audit, exploration, validation plan | 5 | 36.6s | 0 | 0.0s |
| G002-G006: implementation and shared wiring | 0 | 0.0s | 3 | 127.5s |
| G007: validation | 2 | 18.2s | 0 | 0.0s |

G007 also has one 8.8-second model-only final response. The trace-wide read
total is 7 rounds / 54.8s.

## Concurrent SOG

| Goal | Work | Read rounds | Read time | Write rounds | Write time | Planner rounds | Planner time |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| G000 | runtime planning | 6 | 101.1s | 0 | 0.0s | 9 | 105.8s |
| G001 | validation plan | 0 | 0.0s | 0 | 0.0s | 0 | 0.0s |
| G002 | InstantSearch.js foundation | 1 | 11.9s | 2 | 34.8s | 0 | 0.0s |
| G003 | React flavor | 2 | 16.4s | 4 | 51.3s | 0 | 0.0s |
| G004 | Vue flavor | 2 | 9.7s | 2 | 38.8s | 0 | 0.0s |
| G005 | connector tests | 0 | 0.0s | 0 | 0.0s | 0 | 0.0s |
| G006 | shared widget tests | 1 | 8.8s | 1 | 15.1s | 0 | 0.0s |
| G007 | final validation and repair | 9 | 71.5s | 3 | 23.9s | 0 | 0.0s |

G001 was completed by G000 with `completed_by_planner`. G005 was resolved as
`no_action`. Neither launched Pi or entered workspace merge.

The planner rounds are G000's six `set_predicted_actions_plan` calls, two
`set_goal_resolution` calls, and one `set_preload_plan` call. They are control
traffic rather than workspace reads. G000 emitted them in nine separate model
rounds, so eliminating the two downstream agents did not compensate for the
planner protocol overhead.
