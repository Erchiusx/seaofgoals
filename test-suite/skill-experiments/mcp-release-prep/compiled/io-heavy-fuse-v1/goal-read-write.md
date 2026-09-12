# Goal Read/Write timing

## Concurrent FUSE

```text
Wall time: 208.3s
Goal | Read rounds | Read time | Write rounds | Write time | Goal time
-----|--------------|-----------|---------------|------------|----------
G000 | 9 | 100.0s | 0 | 0.0s | 100.0s
G001 | 2 | 22.6s | 0 | 0.0s | 22.6s
G002 | 0 | 0.0s | 1 | 9.4s | 9.4s
G003 | 1 | 9.5s | 5 | 38.4s | 47.9s
G004 | 1 | 8.5s | 1 | 10.4s | 18.9s
G005 | 0 | 0.0s | 1 | 33.5s | 33.5s
G006 | 0 | 0.0s | 1 | 31.6s | 31.6s
G007 | 0 | 0.0s | 1 | 7.7s | 7.7s
G008 | 1 | 5.2s | 0 | 0.0s | 5.2s
```

## Single Pi baseline mapped to workflow work

```text
Wall time: 131.2s
Goal | Read rounds | Read time | Write rounds | Write time | Goal time
-----|--------------|-----------|---------------|------------|----------
G001 | 5 | 48.5s | 0 | 0.0s | 48.5s
G002-G004 | 1 | 8.2s | 2 | 25.8s | 34.1s
G005 | 0 | 0.0s | 1 | 14.1s | 14.1s
G006 | 0 | 0.0s | 1 | 11.6s | 11.6s
G007 | 0 | 0.0s | 1 | 6.9s | 6.9s
G008 | 1 | 6.8s | 0 | 0.0s | 6.8s
```
